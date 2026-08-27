#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIM 自博弈强化学习（REINFORCE + 价值基线）
- 以最新行为克隆权重（train_weights.json）为基础 warm start，策略头复用，价值头新初始化
- 自博弈：当前策略 vs 延迟快照对手（每 SNAP_EVERY 局快照一次），REINFORCE 更新
- 周期产出：train_weights_rl.json（RL 权重，含 wv/bv 价值头）+ rl_status.json（心跳）
- 停止：touch train/rl_stop（优雅保存退出）
用法：nohup python3 rl_selfplay.py > rl.log 2>&1 &
"""
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, '/root/aim/pc')
sys.path.insert(0, '/root/aim/train')
from rules import AimGame, AimCell
from ai import AimAi

BASE_DIR = '/root/aim'
BC_WEIGHTS = os.path.join(BASE_DIR, 'server/public/downloads/train_weights.json')
RL_WEIGHTS = os.path.join(BASE_DIR, 'server/public/downloads/train_weights_rl.json')
STATUS_FILE = os.path.join(BASE_DIR, 'train_data', 'rl_status.json')
HISTORY_FILE = os.path.join(BASE_DIR, 'train_data', 'rl_history.jsonl')  # RL 评估历史（波形图用）
STOP_FILE = os.path.join(BASE_DIR, 'train', 'rl_stop')
EVAL_FILE = os.path.join(BASE_DIR, 'train_data', 'eval_result.json')

IN_DIM, HIDDEN, OUT = 53, 64, 97
MAX_CELLS = 8
GAMMA = 0.99
LR = 1e-3              # 手写 SGD（2e-3 配强奖励震荡过拟合，1e-3 平衡）
BATCH_GAMES = 16       # 每攒 N 局更新一次（≈950 步样本/更新，PPO 多 epoch 复用）
PPO_EPOCHS = 4         # 每 batch 内循环更新次数（PPO 核心：样本复用）
PPO_CLIP = 0.2         # 重要性采样比率裁剪
SNAP_EVERY = 20       # 每 N 局快照一次对手
EVAL_EVERY = 50       # 每 N 局评估一次 vs hard
SAVE_EVERY = 20       # 每 N 局保存权重 + 心跳
MAX_GUARD = 600       # 单局步数上限

# ── 奖励塑形（针对 AIM 特殊性设计，非通用 RL 奖励）──
# 胜负判据是 sum_of（双方所有单位数值总和，谁先归零谁输），所以核心信号用
# 「战力差 Δ = 我方sum - 敌方sum」的每步变化：吞噬/击杀/造兵/产9/滚木碾人
# 全部直接反映在 Δ 里，信号与胜负目标严格对齐。
# 超9吞噬「变拉」（15→1+5=6）导致 sum 缩水，Δ 自动惩罚，无需硬编码禁招。
# 校准原则：终局 ±R_WIN 绝对主导，每步奖励只做方向引导——
# 否则策略会「刷奖励」（无脑吞敌 0.94/局）反而掉分（reward hacking）。
R_DELTA = 0.15        # 战力差每变化 1 点（方向引导，弱化）
R_KILL = 0.4          # 击杀敌方单位（Δ 之外的事件奖励）
R_LOSS = -0.3         # 己方单位被灭
R_DEVOUR_ENEMY = 0.8  # 吞噬敌方（Δ 已算 2v，这里只给引导量——2.0 会让策略无脑吞）
R_DEVOUR_SELF = -0.1  # 吞噬己方（合成 8/9 是运营核心，几乎不惩罚）
R_REPEAT_WARN = -0.6  # 第二次重复操作警告（第三次直接判负）
R_WIN = 5.0           # 终局胜利（主导信号）
R_LOSE = -5.0         # 终局失败
DEVOUR_PRIOR = 1.5    # 吞敌槽探索先验（logit 偏置，仅训练期引导，参与更新可被拉回）
EPS = 0.05            # ε 均匀探索：稀有合法动作（吞敌）也有公平机会被尝试


def xavier(fan_in, fan_out, rng):
    return rng.uniform(-1, 1, (fan_in, fan_out)) * np.sqrt(6.0 / (fan_in + fan_out))




class RlPolicy:
    """RL 策略：共享骨干 + 策略头(49) + 价值头(1)。权重布局与 BC/dart 一致 + wv/bv。"""

    def __init__(self, weights_path=None, seed=0):
        self.rng = np.random.default_rng(seed)
        if weights_path and os.path.exists(weights_path):
            w = json.load(open(weights_path, encoding='utf-8'))
            self.w1 = np.array(w['w1'], dtype=np.float64).reshape(HIDDEN, IN_DIM)
            self.b1 = np.array(w['b1'], dtype=np.float64)
            self.w2 = np.array(w['w2'], dtype=np.float64).reshape(HIDDEN, HIDDEN)
            self.b2 = np.array(w['b2'], dtype=np.float64)
            self.wo = np.array(w['wo'], dtype=np.float64).reshape(OUT, HIDDEN)
            self.bo = np.array(w['bo'], dtype=np.float64)
            # 吞敌先验：BC 权重里吞敌槽 logit 天生偏低（人类数据吞敌少），
            # 给 8 个格子的「devour 敌」槽（i*12+8）加探索偏置，让 AI 敢于尝试吞敌。
            # 这只是探索引导，不是硬编码——学成什么样完全由奖励塑形决定，
            # 若吞敌真不好，梯度会把这个偏置拉回去（bo 参与更新）。
            for i in range(MAX_CELLS):
                self.bo[i * 12 + 8] += DEVOUR_PRIOR
            # 价值头：BC 权重没有 → 新初始化
            if 'wv' in w:
                self.wv = np.array(w['wv'], dtype=np.float64).reshape(1, HIDDEN)
                self.bv = np.array(w['bv'], dtype=np.float64)
            else:
                self.wv = xavier(HIDDEN, 1, self.rng).T
                self.bv = np.zeros(1)
        else:
            self.w1 = xavier(IN_DIM, HIDDEN, self.rng)
            self.b1 = np.zeros(HIDDEN)
            self.w2 = xavier(HIDDEN, HIDDEN, self.rng)
            self.b2 = np.zeros(HIDDEN)
            self.wo = xavier(HIDDEN, OUT, self.rng)
            self.bo = np.zeros(OUT)
            self.wv = xavier(HIDDEN, 1, self.rng).T
            self.bv = np.zeros(1)

    def clone(self):
        p = RlPolicy.__new__(RlPolicy)
        p.rng = np.random.default_rng(0)
        for k in ('w1', 'b1', 'w2', 'b2', 'wo', 'bo', 'wv', 'bv'):
            setattr(p, k, getattr(self, k).copy())
        return p

    def forward(self, x):
        h1 = np.maximum(0, x @ self.w1.T + self.b1)
        h2 = np.maximum(0, h1 @ self.w2.T + self.b2)
        logits = h2 @ self.wo.T + self.bo
        value = float((h2 @ self.wv.T + self.bv)[0])
        return h2, logits, value

    # ── 视角归一化编码（与 eval_ai/train_bc 一致：我方恒为左）──
    def encode(self, game):
        me = game.turn
        flip = me == 1
        cells = list(reversed(game.cells))[:MAX_CELLS] if flip else game.cells[:MAX_CELLS]
        x = []
        for c in cells:
            x += [c.v / 9.0,
                  1.0 if c.o == me else 0.0,
                  1.0 if (c.o is not None and c.o != me) else 0.0,
                  1.0 if c.bridge else 0.0,
                  1.0 if c.onBridge else 0.0,
                  1.0 if c.auto else 0.0]
        while len(x) < MAX_CELLS * 6:
            x += [0.0] * 6
        x += [0.0,
              1.0 if game.phase == 'action' else 0.0,
              1.0 if game.phase == 'produce' else 0.0,
              game.points / 10.0, game.produce_left / 8.0]
        return np.array(x, dtype=np.float64)

    def slot_of(self, action, flip, game=None):
        t = action.get('type')
        i = int(action.get('i', -1))
        if i < 0 or i >= MAX_CELLS:
            return None
        if flip:
            i = MAX_CELLS - 1 - i
        if t == 'move':
            return i * 12 + (1 if int(action.get('steps', 1)) >= 2 else 0)
        if t == 'attack':
            k = abs(int(action.get('j', -1)) - int(action.get('i', -1)))
            if k < 1 or k > 3:
                return None
            j = int(action.get('j', -1))
            is_enemy = 0 <= j < len(game.cells) and game.cells[j].o is not None and game.cells[j].o != game.turn
            return i * 12 + (2 + (k - 1) if is_enemy else 5 + (k - 1))
        if t == 'devour':
            j = int(action.get('j', -1))
            is_enemy = 0 <= j < len(game.cells) and game.cells[j].o is not None and game.cells[j].o != game.turn
            return i * 12 + (8 if is_enemy else 9)
        if t == 'split':
            return i * 12 + 10
        if t == 'produce':
            return i * 12 + 11
        if t == 'endTurn':
            return 96
        return None

    def can_produce(self, game, owner):
        d = 1 if owner == 0 else -1
        for i, c in enumerate(game.cells):
            if c.o == owner and c.v == 8:
                j = i + d
                if 0 <= j < len(game.cells) and not game.cells[j].bridge:
                    return True
        return False

    def act(self, game, sample=True, temp=1.0, fallback_seed=0):
        """返回 (action, logprob) ；阶段选择用启发式兜底（与 BC 推理一致）"""
        owner = game.turn
        if game.phase is None:
            if not self.can_produce(game, owner):
                return {'type': 'choosePhase', 'phase': 'action'}, 0.0
            a = AimAi('hard', seed=fallback_seed).decide(game)
            return a, 0.0
        acts = game.get_legal_actions(owner)
        playable = [a for a in acts if a['type'] != 'endTurn']
        if not playable:
            return {'type': 'endTurn'}, 0.0
        flip = owner == 1
        x = self.encode(game)
        _, logits, _ = self.forward(x)
        slots = []
        cands = []
        for a in playable:
            s = self.slot_of(a, flip, game)
            if s is not None and s < OUT:
                slots.append(s)
                cands.append(a)
        if not cands:
            return playable[0], 0.0
        logits = logits[slots]
        if sample:
            e = np.exp((logits - logits.max()) / temp)
            p = e / e.sum()
            n = len(cands)
            if self.rng.random() < EPS:
                # ε 均匀探索：给稀有合法动作（如吞敌）公平的探索机会
                # 探索步是 off-policy 的，不记录（lp=None → play_game 跳过）
                idx = int(self.rng.integers(n))
                return cands[idx], None
            idx = int(self.rng.choice(n, p=p))
            # logprob 用「全 97 槽 unmasked softmax」定义，与 update() 完全一致！
            # （候选内 softmax 与全槽 softmax 对同一状态差常数因子，概率比相同，
            #   但数值上必须统一，否则 PPO importance ratio 系统性错误——之前学不动的根因）
            _, logits_all, _ = self.forward(x)
            lmax = logits_all.max()
            e_all = np.exp(logits_all - lmax)
            p_all = e_all / e_all.sum()
            lp = float(np.log(p_all[slots[idx]] + 1e-12))
        else:
            idx = int(np.argmax(logits))
            lp = 0.0
        return cands[idx], lp

    def value_of(self, game):
        _, _, v = self.forward(self.encode(game))
        return v

    def save(self, path, version=None, base_version=0, extra=None):
        data = {
            'version': version if version is not None else 1,
            'updatedAt': time.strftime('%Y-%m-%d %H:%M:%S'),
            'in': IN_DIM, 'hidden': HIDDEN, 'out': OUT,
            'w1': [float(x) for x in self.w1.flatten()],
            'b1': [float(x) for x in self.b1],
            'w2': [float(x) for x in self.w2.flatten()],
            'b2': [float(x) for x in self.b2],
            'wo': [float(x) for x in self.wo.flatten()],
            'bo': [float(x) for x in self.bo],
            'wv': [float(x) for x in self.wv.flatten()],
            'bv': [float(x) for x in self.bv],
            'rl': True,
            'baseVersion': base_version,
        }
        if extra:
            data.update(extra)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f)


class RuleOpp:
    """规则 AI 包装：统一 act 接口（与策略共用 play_game）。
    混合对手用——纯自博弈会过拟合「自我风格」，评估打的是规则 AI，
    让策略 1/3 时间对阵规则 AI，直接对齐评估目标。"""
    def __init__(self, level, seed=0):
        self.ai = AimAi(level, seed=seed)
        self.level = level

    def act(self, game, sample=True):
        return self.ai.decide(game), 0.0


# ── 自博弈一局：返回 (winner, traj, devour_stat) ──
# traj: [(x, slot, lp, r, owner)] 每步即时奖励（终局 ±R_WIN/R_LOSE 已并入最后一步）
# devour_stat: {'enemy': n, 'self': n} 本局吞噬敌/己次数（验证修正效果）
# 奖励设计：
#   1. 战力差 Δ 变化（动作阶段，滚木前结算）
#   2. 事件奖励：击杀/损失/吞噬敌/吞噬己/重复警告
#   3. 滚木是回合间自动结算：效果记给滚木主人，挂在其下一次行动上（pending）
#   4. 终局 ±R_WIN/R_LOSE
def play_game(policy_a, policy_b, seed=0, record_for='a'):
    g = AimGame(limit=16)
    ai_a, ai_b = policy_a, policy_b  # 玩家0=policy_a，玩家1=policy_b
    traj = []
    pending = [0.0, 0.0]   # 滚木结算奖励，等滚木主人下一次行动时并入
    devour_stat = {'enemy': 0, 'self': 0}
    guard = 0
    while g.winner is None and guard < MAX_GUARD:
        guard += 1
        owner = g.turn
        p = ai_a if owner == 0 else ai_b
        a, lp = p.act(g, sample=True)
        if a is None:
            break
        # 是否需要记录本步（ε 探索步 / 非模型侧不记录；规则 AI 无 encode 接口）
        need_record = lp is not None and (
            record_for == 'both' or (record_for == 'a' and owner == 0) or (record_for == 'b' and owner == 1))
        # 动作前快照：状态编码 + 槽位判定必须在动作执行前（与 BC 数据/评估推理一致；
        # 且 devour 动作后目标格被吃掉，再判定敌我就会失效——吞敌会被记成吞己槽！）
        flip = owner == 1
        x_before = p.encode(g) if need_record else None
        slot = p.slot_of(a, flip, g) if need_record else None
        # 吞噬敌/己预判（devour 只吃正前方 1 格）
        devour_enemy = devour_self = False
        if a.get('type') == 'devour':
            j = int(a.get('j', -1))
            if 0 <= j < len(g.cells):
                o = g.cells[j].o
                devour_enemy = o is not None and o != owner
                devour_self = o == owner
        # 战力差快照（owner 视角）
        delta0 = g.sum_of(owner) - g.sum_of(1 - owner)
        k0, l0 = g.stats['kills'][owner], g.stats['losses'][owner]
        r = g.apply_action(owner, a, defer_roll=True)
        if not r['ok']:
            acts = g.get_legal_actions(owner)
            if not acts:
                break
            r = g.apply_action(owner, acts[0], defer_roll=True)
            if not r['ok']:
                break
            a, lp = acts[0], 0.0
            slot = p.slot_of(a, flip, g)  # fallback 动作重新判定（仍在动作后，罕见）
        # ── 动作阶段奖励（滚木前，owner 视角）──
        delta1 = g.sum_of(owner) - g.sum_of(1 - owner)
        step_r = R_DELTA * (delta1 - delta0)
        k1, l1 = g.stats['kills'][owner], g.stats['losses'][owner]
        kd, ld = k1 - k0, l1 - l0
        if devour_enemy:
            step_r += R_DEVOUR_ENEMY
            devour_stat['enemy'] += 1
        elif devour_self:
            step_r += R_DEVOUR_SELF
            devour_stat['self'] += 1
        else:
            step_r += R_KILL * kd + R_LOSS * ld
        if r.get('repeatWarn'):
            step_r += R_REPEAT_WARN
        # ── 滚木阶段：自动结算，效果记给滚木主人（= 当前 g.turn）──
        if g.has_pending_roll:
            roller = g.turn
            rd0 = g.sum_of(roller) - g.sum_of(1 - roller)
            rk0, rl0 = g.stats['kills'][roller], g.stats['losses'][roller]
            while g.has_pending_roll:
                if g.roll_step_once(g.turn) is None:
                    g.clear_pending_roll()
                    break
            rd1 = g.sum_of(roller) - g.sum_of(1 - roller)
            roll_r = R_DELTA * (rd1 - rd0)
            rk1, rl1 = g.stats['kills'][roller], g.stats['losses'][roller]
            roll_r += R_KILL * (rk1 - rk0) + R_LOSS * (rl1 - rl0)
            pending[roller] += roll_r
        # 记录模型侧轨迹（动作前状态 x_before + 动作前槽位，与 BC 数据/评估一致）
        # lp=None = ε 探索步（off-policy），不参与学习
        if need_record:
            if slot is not None:
                traj.append((x_before, slot, lp, step_r + pending[owner], owner))
                pending[owner] = 0.0
    # ── 终局奖励（并入最后一步，含未结算的滚木奖励）──
    if g.winner is not None and traj:
        x, slot, lp, rr, own = traj[-1]
        traj[-1] = (x, slot, lp, rr + pending[own] + (R_WIN if own == g.winner else R_LOSE), own)
    return g.winner, traj, devour_stat


# ── return-to-go 折现 ──
def discount(rewards, gamma=GAMMA):
    """计算每步的折现回报（未来即时奖励之和）"""
    returns = np.zeros(len(rewards), dtype=np.float64)
    acc = 0.0
    for t in range(len(rewards) - 1, -1, -1):
        acc = rewards[t] + gamma * acc
        returns[t] = acc
    return returns


# ── PPO 风格更新（多 epoch + clip + advantage 标准化）──
def update(policy, batch, lr=LR, epochs=PPO_EPOCHS, clip=PPO_CLIP):
    """batch: [(x, slot, lp_old, return)] 每步样本
    - advantage = return - V(s)（价值基线），batch 内标准化降方差
    - ratio = π_new/π_old，clip 目标防止一步更新过猛
    - 多 epoch 让每个 batch 利用更充分（REINFORCE 每 batch 只更新一次的效率瓶颈）"""
    if not batch:
        return 0.0
    X = np.array([b[0] for b in batch], dtype=np.float64)
    slots = np.array([b[1] for b in batch], dtype=np.int64)
    lp_old = np.array([b[2] for b in batch], dtype=np.float64)
    R = np.array([b[3] for b in batch], dtype=np.float64)
    row = np.arange(len(batch))
    total_loss = 0.0
    for _ in range(epochs):
        # 前向
        h1 = np.maximum(0, X @ policy.w1.T + policy.b1)
        h2 = np.maximum(0, h1 @ policy.w2.T + policy.b2)
        logits = h2 @ policy.wo.T + policy.bo
        values = h2 @ policy.wv.T + policy.bv
        # 策略概率 + logprob（按 slot 索引）
        lmax = logits.max(axis=1, keepdims=True)
        e = np.exp(logits - lmax)
        probs = e / e.sum(axis=1, keepdims=True)
        lp_cur = np.log(probs[row, slots] + 1e-12)
        # advantage（价值基线 + 标准化）
        adv = R - values[:, 0]
        adv = (adv - adv.mean()) / (adv.std() + 1e-8)
        # PPO clip 目标
        ratio = np.exp(lp_cur - lp_old)
        surr1 = ratio * adv
        surr2 = np.clip(ratio, 1.0 - clip, 1.0 + clip) * adv
        loss_p = -(np.minimum(surr1, surr2)).mean()
        loss_v = ((R - values[:, 0]) ** 2).mean()
        total_loss += loss_p + loss_v
        # 反向（策略梯度 + 价值梯度）
        dlogits = probs.copy()
        dlogits[row, slots] -= 1
        # clip 掩码：被截断（surr2 < surr1）的样本梯度归零
        mask = (surr1 <= surr2).astype(np.float64)
        dlogits *= (ratio * adv * mask / len(batch))[:, None]  # PPO 目标对 logits 的梯度
        dv = 2 * (values - R[:, None]) / len(batch)
    # h2 梯度
    dh2 = dlogits @ policy.wo + dv @ policy.wv
    dh2[h2 <= 0] = 0
    dh1 = dh2 @ policy.w2
    dh1[h1 <= 0] = 0
    # 参数梯度（注意方向：grad = 输出.T @ 输入）
    grads = {
        'wo': dlogits.T @ h2, 'bo': dlogits.sum(axis=0),
        'wv': dv.T @ h2, 'bv': dv.sum(axis=0),
        'w2': dh2.T @ h1, 'b2': dh2.sum(axis=0),
        'w1': dh1.T @ X, 'b1': dh1.sum(axis=0),
    }
    for k, gr in grads.items():
        g = getattr(policy, k)
        g -= lr * gr
    return float(loss_p + loss_v)


# ── 评估：完整测试（对局 + 能力考试 + 综合评分 0-100）──
def eval_model_score(policy, tmp_path='/root/aim/train_data/rl_eval_tmp.json'):
    """保存策略到临时权重，跑完整评估，返回 (score_total, grade)"""
    policy.save(tmp_path, version=0)
    from eval_model import run_eval
    data = run_eval(tmp_path, 'easy=2,normal=2,hard=4')
    if not data:
        return None, None
    sc = data['score']
    return sc['total'], sc['grade']


def write_status(data):
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    with open(STATUS_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f)


def append_history(games, score, grade, avg):
    """RL 评估历史（波形图数据源）：记录综合测试得分"""
    os.makedirs(os.path.dirname(HISTORY_FILE), exist_ok=True)
    with open(HISTORY_FILE, 'a', encoding='utf-8') as f:
        f.write(json.dumps({'games': games, 'score': score, 'grade': grade,
                            'avgReward': round(avg, 3),
                            'ts': time.strftime('%Y-%m-%d %H:%M:%S')}) + '\n')


def base_win_rate():
    """原模型（BC 基础）能力：eval_result.json 的 vs hard 胜率"""
    try:
        if os.path.exists(EVAL_FILE):
            ev = json.load(open(EVAL_FILE, encoding='utf-8'))
            return ev.get('summary', {}).get('vsHard')
    except Exception:
        pass
    return None


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--games', type=int, default=0,
                    help='目标训练局数（0=无限跑；跑满自动停止并保存）')
    args = ap.parse_args()
    target_games = args.games
    base_version = 0
    try:
        if os.path.exists(BC_WEIGHTS):
            base_version = int(json.load(open(BC_WEIGHTS, encoding='utf-8')).get('version', 0))
    except Exception:
        pass
    print(f'=== 自博弈强化学习启动 base=BC v{base_version} 目标局数={target_games or "无限"} ===', flush=True)
    if os.path.exists(STOP_FILE):
        os.remove(STOP_FILE)
    policy = RlPolicy(BC_WEIGHTS, seed=42)
    opponent = policy.clone()  # 延迟快照对手
    rl_version = 1
    try:
        if os.path.exists(RL_WEIGHTS):
            rl_version = int(json.load(open(RL_WEIGHTS, encoding='utf-8')).get('version', 0)) + 1
    except Exception:
        pass
    optimizer_lr = LR
    total_games = 0
    rewards = []
    batch = []
    devour_total = [0, 0]   # [吞敌, 吞己] 累计（验证吞噬修正效果）
    sp_wins = 0             # 策略 vs 延迟快照胜局数（学习信号）
    t0 = time.time()
    base_wr = base_win_rate()  # 原模型（BC 基础）vs hard 胜率（保留参考）
    base_score = None
    try:
        if os.path.exists(EVAL_FILE):
            base_score = json.load(open(EVAL_FILE, encoding='utf-8')).get('score', {}).get('total')
    except Exception:
        pass
    print(f'原模型 vs hard 基准胜率: {base_wr}  综合评分: {base_score}', flush=True)

    while True:
        if os.path.exists(STOP_FILE):
            print('检测到停止信号，保存退出', flush=True)
            policy.save(RL_WEIGHTS, version=rl_version, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(float(np.mean(rewards[-50:])) if rewards else 0, 3)})
            write_status({'state': 'stopped', 'games': total_games, 'baseWinRate': base_wr,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
            return
        # 对手：1/3 局打规则 AI（轮换 easy/normal/hard，对齐评估目标），
        # 其余打延迟快照（自博弈）。
        if total_games % 3 == 0:
            level = ('easy', 'normal', 'hard')[(total_games // 3) % 3]
            opponent = RuleOpp(level, seed=total_games)
        elif total_games % SNAP_EVERY == 0 or opponent is None:
            opponent = policy.clone()
        # 自博弈一局（只记录 policy 侧轨迹——对手侧样本会污染梯度）
        winner, traj, dev = play_game(policy, opponent, seed=total_games, record_for='a')
        total_games += 1
        devour_total[0] += dev['enemy']
        devour_total[1] += dev['self']
        if winner == 0:
            sp_wins += 1   # 策略赢延迟快照（旧自己）→ 学习信号
        # 达到目标局数 → 自动停止（优雅保存）
        if target_games > 0 and total_games >= target_games:
            score, grade = eval_model_score(policy)
            avg = float(np.mean(rewards[-50:])) if rewards else 0
            append_history(total_games, score, grade, avg)
            policy.save(RL_WEIGHTS, version=rl_version, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(avg, 3),
                               'score': score, 'grade': grade, 'targetGames': target_games})
            write_status({'state': 'stopped', 'games': total_games, 'avgReward': round(avg, 3),
                          'score': score, 'grade': grade, 'baseWinRate': base_wr, 'baseScore': base_score,
                          'targetGames': target_games,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
            print(f'目标局数 {target_games} 达成，自动停止。综合分 {score}（{grade}）', flush=True)
            return
        # 每步即时奖励 → 折现 return-to-go（按局），入 batch
        if traj:
            rs = np.array([t[3] for t in traj], dtype=np.float64)
            rewards.append(float(rs.mean()))   # 均奖 = 本局平均每步即时奖励
            rets = discount(rs, GAMMA)
            for (x, slot, lp, _r, _own), ret in zip(traj, rets):
                batch.append((x, slot, lp, ret))
        # 更新（每 BATCH_GAMES 局一次）
        if total_games % BATCH_GAMES == 0 and batch:
            loss = update(policy, batch, lr=optimizer_lr)
            batch = []
        # 延迟快照对手
        if total_games % SNAP_EVERY == 0:
            opponent = policy.clone()
        # 定期评估 + 保存
        if total_games % EVAL_EVERY == 0:
            score, grade = eval_model_score(policy)
            avg = float(np.mean(rewards[-EVAL_EVERY:])) if rewards else 0
            print(f'[{total_games}局] 均奖 {avg:.2f} 综合分 {score}（{grade}） 吞敌{devour_total[0]} 吞己{devour_total[1]} 自博弈胜率{sp_wins/total_games*100:.0f}% 耗时{(time.time()-t0)/60:.1f}m', flush=True)
            append_history(total_games, score, grade, avg)  # 波形图历史（综合得分）
            policy.save(RL_WEIGHTS, version=rl_version, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(avg, 3),
                               'score': score, 'grade': grade})
            write_status({'state': 'running', 'games': total_games, 'avgReward': round(avg, 3),
                          'score': score, 'grade': grade, 'rlVersion': rl_version,
                          'baseVersion': base_version, 'baseWinRate': base_wr, 'baseScore': base_score,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
        elif total_games % SAVE_EVERY == 0:
            write_status({'state': 'running', 'games': total_games,
                          'avgReward': round(float(np.mean(rewards[-SAVE_EVERY:])) if rewards else 0, 3),
                          'rlVersion': rl_version, 'baseVersion': base_version,
                          'baseWinRate': base_wr, 'baseScore': base_score,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})


if __name__ == '__main__':
    main()
