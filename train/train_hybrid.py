#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIM 行为克隆 + 强化学习联合训练（hybrid：模仿的同时打分）
- 模仿（BC）：从人类对局（games.jsonl）学动作分布，交叉熵损失持续约束策略不跑偏
- 打分（RL）：自博弈 vs 延迟快照/规则 AI，PPO 用奖励塑形优化策略
- 联合 loss：L = L_ppo + β·L_bc，每次更新同时吃 RL 轨迹和人类样本
- 网络：101 → 128 → 128 → 193（16 格棋盘，与 train_bc.py 同构）+ 价值头
- 产出：直接部署 train_weights.json（训练场/游戏拉取即生效）+ rl_status.json（心跳）
- 停止：touch train/rl_stop（优雅保存退出）
用法：nohup python3 train_hybrid.py > train_hybrid.log 2>&1 &
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
STATUS_FILE = os.path.join(BASE_DIR, 'train_data', 'rl_status.json')
HISTORY_FILE = os.path.join(BASE_DIR, 'train_data', 'rl_history.jsonl')  # RL 评估历史（波形图用）
STOP_FILE = os.path.join(BASE_DIR, 'train', 'rl_stop')
EVAL_FILE = os.path.join(BASE_DIR, 'train_data', 'eval_result.json')
HUMAN_DATA = os.path.join(BASE_DIR, 'train_data', 'games.jsonl')

IN_DIM, HIDDEN, OUT = 16 * 6 + 5, 128, 16 * 12 + 1   # 101 → 128 → 128 → 193（16 格）
MAX_CELLS = 16
BC_BETA = 0.3          # BC 损失权重（模仿约束强度：太高学不出新东西，太低 RL 跑偏）
BC_RELOAD_EVERY = 10   # 每 N 局重新读人类数据（增量吸收新对局）
GAMMA = 0.99
LR = 1e-3              # 手写 SGD（2e-3 配强奖励震荡过拟合，1e-3 平衡）
BATCH_GAMES = 16       # 每攒 N 局更新一次（≈950 步样本/更新，PPO 多 epoch 复用）
PPO_EPOCHS = 4         # 每 batch 内循环更新次数（PPO 核心：样本复用）
PPO_CLIP = 0.2         # 重要性采样比率裁剪
SNAP_EVERY = 20       # 每 N 局快照一次对手
EVAL_EVERY = 25       # 每 N 局评估一次（牢大定：25 局，波形图更密）
SAVE_EVERY = 20       # 每 N 局保存权重 + 心跳
MAX_GUARD = 600       # 单局步数上限
HISTORY_WINDOW_GAMES = 1000  # rl_history 只保留最近 1000 局（RL 一局=一次训练，牢大定）

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
EPS = 0.05            # ε 均匀探索基础值（固定：稀有合法动作也有公平机会被尝试）
# ── 自适应探索（牢大定）：分数长时间无突破 → 提高噪点激发新行为 ──
# 噪点用 temperature（softmax 温度）：概率变平但保持相对偏好，比 ε 均匀随机平滑——
# ε 提到 0.30 会让 30% 的步完全随机，训练数据被污染，自博弈胜率反而掉（实测 50%→44%）。
PLATEAU_WINDOW = 5    # 用最近 N 次评估判定平台期
PLATEAU_DELTA = 2.5   # 窗口内分数波动 < 此值 → 平台期（16 局评估噪声约 ±2，留余量）
TEMP_BASE = 1.0       # 采样温度基础值
TEMP_STEP = 0.3       # 每持续一个平台档，温度 +0.3
TEMP_MAX = 2.5        # 温度封顶
ENTROPY_BETA = 0.02   # 熵正则系数：强制策略保持随机性，argmax 不早熟固化——
                      # 否则 PPO 只强化当前最优动作，argmax 永不翻转（实测 15000 局只变 1%）
# ── 速战速决奖励（牢大定）：对齐评估「速战速决」指标 ──
# 20 回合内赢 → 全额 R_WIN；之后每拖 10 回合扣 1（下限 0.5）；输仍 R_LOSE
WIN_TURNS_OK = 20
WIN_TURN_PENALTY = 1.0   # 每 10 回合扣分（WIN_TURN_PENALTY * 10 回合）


def xavier(fan_in, fan_out, rng):
    return rng.uniform(-1, 1, (fan_in, fan_out)) * np.sqrt(6.0 / (fan_in + fan_out))




class RlPolicy:
    """RL 策略：共享骨干 + 策略头(49) + 价值头(1)。权重布局与 BC/dart 一致 + wv/bv。"""

    def __init__(self, weights_path=None, seed=0):
        self.rng = np.random.default_rng(seed)
        self.eps = EPS       # ε 均匀探索（固定基础值）
        self.temp = TEMP_BASE  # 采样温度（平台期自适应提高）
        if weights_path and os.path.exists(weights_path):
            w = json.load(open(weights_path, encoding='utf-8'))
            # 维度从权重文件读取（64/128 单元都兼容）
            self.in_dim = int(w.get('in', IN_DIM))
            self.hidden = int(w.get('hidden', HIDDEN))
            self.out = int(w.get('out', OUT))
            self.w1 = np.array(w['w1'], dtype=np.float64).reshape(self.hidden, self.in_dim)
            self.b1 = np.array(w['b1'], dtype=np.float64)
            self.w2 = np.array(w['w2'], dtype=np.float64).reshape(self.hidden, self.hidden)
            self.b2 = np.array(w['b2'], dtype=np.float64)
            self.wo = np.array(w['wo'], dtype=np.float64).reshape(self.out, self.hidden)
            self.bo = np.array(w['bo'], dtype=np.float64)
            # 吞敌先验：BC 权重里吞敌槽 logit 天生偏低（人类数据吞敌少），
            # 给 8 个格子的「devour 敌」槽（i*12+8）加探索偏置，让 AI 敢于尝试吞敌。
            # 这只是探索引导，不是硬编码——学成什么样完全由奖励塑形决定，
            # 若吞敌真不好，梯度会把这个偏置拉回去（bo 参与更新）。
            # 注意：RL 存档（rl: True）的 bo 已含先验（训练期加过且参与更新），
            # 重新加载（从存档继续训练）时再加会双倍，必须跳过。
            if not w.get('rl'):
                for i in range(MAX_CELLS):
                    self.bo[i * 12 + 8] += DEVOUR_PRIOR
            # 价值头：BC 权重没有 → 新初始化
            if 'wv' in w:
                self.wv = np.array(w['wv'], dtype=np.float64).reshape(1, self.hidden)
                self.bv = np.array(w['bv'], dtype=np.float64)
            else:
                self.wv = xavier(self.hidden, 1, self.rng).T
                self.bv = np.zeros(1)
        else:
            self.in_dim, self.hidden, self.out = IN_DIM, HIDDEN, OUT
            # 从零初始化：forward 用 x @ w1.T / h2 @ wo.T → w1 (hidden,in)、wo (out,hidden)
            self.w1 = xavier(HIDDEN, IN_DIM, self.rng)
            self.b1 = np.zeros(HIDDEN)
            self.w2 = xavier(HIDDEN, HIDDEN, self.rng)
            self.b2 = np.zeros(HIDDEN)
            self.wo = xavier(OUT, HIDDEN, self.rng)
            self.bo = np.zeros(OUT)
            self.wv = xavier(HIDDEN, 1, self.rng).T
            self.bv = np.zeros(1)

    def clone(self):
        p = RlPolicy.__new__(RlPolicy)
        p.rng = np.random.default_rng(0)
        p.eps = self.eps
        p.temp = self.temp
        p.in_dim = self.in_dim
        p.hidden = self.hidden
        p.out = self.out
        for k in ('w1', 'b1', 'w2', 'b2', 'wo', 'bo', 'wv', 'bv'):
            setattr(p, k, getattr(self, k).copy())
        return p

    def forward(self, x):
        h1 = np.maximum(0, x @ self.w1.T + self.b1)
        h2 = np.maximum(0, h1 @ self.w2.T + self.b2)
        logits = h2 @ self.wo.T + self.bo
        value = float((h2 @ self.wv.T + self.bv)[0])
        return h2, logits, value

    # ── 视角归一化编码（与 eval_ai/train_bc 一致：我方恒为左，先补零 16 再逆序）──
    def encode(self, game):
        me = game.turn
        flip = me == 1
        cells = list(game.cells)
        while len(cells) < MAX_CELLS:
            cells.append(AimCell(0))
        if flip:
            cells = list(reversed(cells))
        cells = cells[:MAX_CELLS]
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
            return 16 * 12
        return None

    def can_produce(self, game, owner):
        d = 1 if owner == 0 else -1
        for i, c in enumerate(game.cells):
            if c.o == owner and c.v == 8:
                j = i + d
                if 0 <= j < len(game.cells) and not game.cells[j].bridge:
                    return True
        return False

    def act(self, game, sample=True, fallback_seed=0):
        """返回 (action, logprob) ；阶段选择也交给网络（与训练端/推理端一致）"""
        owner = game.turn
        if game.phase is None:
            if not self.can_produce(game, owner):
                return {'type': 'choosePhase', 'phase': 'action'}, 0.0
            # 候选 = 行动类 + 造兵类并集（与 train_bc build_samples / train_ai.dart 一致）
            acts = [a for a in game.get_legal_actions(owner)
                    if a['type'] not in ('choosePhase', 'endTurn')]
            d = 1 if owner == 0 else -1
            for i, c in enumerate(game.cells):
                if c.o == owner and c.v == 8:
                    j = i + d
                    if 0 <= j < len(game.cells) and not game.cells[j].bridge:
                        acts.append({'type': 'produce', 'i': i, 'j': j})
            if not acts:
                return {'type': 'choosePhase', 'phase': 'action'}, 0.0
            return self._sample_cands(game, owner, acts, sample)
        acts = game.get_legal_actions(owner)
        playable = [a for a in acts if a['type'] != 'endTurn']
        if not playable:
            return {'type': 'endTurn'}, 0.0
        return self._sample_cands(game, owner, playable, sample)

    def _sample_cands(self, game, owner, cands, sample):
        flip = owner == 1
        x = self.encode(game)
        _, logits, _ = self.forward(x)
        slots = []
        kept = []
        for a in cands:
            s = self.slot_of(a, flip, game)
            if s is not None and s < self.out:
                slots.append(s)
                kept.append(a)
        if not kept:
            return cands[0], 0.0
        logits = logits[slots]
        if sample:
            e = np.exp((logits - logits.max()) / self.temp)
            p = e / e.sum()
            n = len(kept)
            if self.rng.random() < self.eps:
                # ε 均匀探索：给稀有合法动作（如吞敌）公平的探索机会
                # 探索步是 off-policy 的，不记录（lp=None → play_game 跳过）
                idx = int(self.rng.integers(n))
                return kept[idx], None
            idx = int(self.rng.choice(n, p=p))
            # logprob 用「全 OUT 槽 unmasked softmax」定义，与 update() 完全一致！
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
        return kept[idx], lp

    def value_of(self, game):
        _, _, v = self.forward(self.encode(game))
        return v

    def save(self, path, version=None, base_version=0, extra=None):
        data = {
            'version': version if version is not None else 1,
            'updatedAt': time.strftime('%Y-%m-%d %H:%M:%S'),
            'in': self.in_dim, 'hidden': self.hidden, 'out': self.out,
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
    # 速战速决：WIN_TURNS_OK 回合内赢 → 全额 R_WIN，之后每拖 10 回合扣 1（下限 0.5）
    if g.winner is not None and traj:
        x, slot, lp, rr, own = traj[-1]
        if own == g.winner:
            win_r = max(0.5, R_WIN - max(0, g.turn_count - WIN_TURNS_OK) / 10.0 * WIN_TURN_PENALTY)
        else:
            win_r = R_LOSE
        traj[-1] = (x, slot, lp, rr + pending[own] + win_r, own)
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


# ── PPO 风格更新（多 epoch + clip + advantage 标准化 + BC 模仿约束）──
def update(policy, batch, bc=None, lr=LR, epochs=PPO_EPOCHS, clip=PPO_CLIP, bc_beta=BC_BETA):
    """batch: [(x, slot, lp_old, return)] 每步样本（RL 轨迹）
    bc: (X_bc, slots_bc) 人类样本——联合训练：每 epoch 采样等量 BC 样本，
    交叉熵梯度叠加到策略梯度（模仿约束：RL 打分不把策略带离人类打法太远）
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
    has_bc = bc is not None and len(bc[0]) > 0
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
        # 熵正则（打破 argmax 惯性：∂(-βH)/∂z = β·p·(log p + H_row)）
        logp = np.log(probs + 1e-12)
        H_row = -(probs * logp).sum(axis=1, keepdims=True)
        entropy = H_row[:, 0]
        loss_e = -ENTROPY_BETA * entropy.mean()
        total_loss += loss_p + loss_v + loss_e
        # 反向（策略梯度 + 价值梯度 + 熵梯度）
        dlogits = probs.copy()
        dlogits[row, slots] -= 1
        # clip 掩码：被截断（surr2 < surr1）的样本梯度归零
        mask = (surr1 <= surr2).astype(np.float64)
        dlogits *= (ratio * adv * mask / len(batch))[:, None]  # PPO 目标对 logits 的梯度
        dlogits += (ENTROPY_BETA * probs * (logp + H_row)) / len(batch)  # 熵正则梯度
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
    # ── BC 模仿梯度：从人类样本采样，交叉熵叠加（β 加权）──
    if has_bc:
        Xb, sb = bc
        nbc = min(len(Xb), len(batch))
        idx = policy.rng.integers(0, len(Xb), nbc)
        Xbc = Xb[idx]
        sbc = sb[idx]
        h1b = np.maximum(0, Xbc @ policy.w1.T + policy.b1)
        h2b = np.maximum(0, h1b @ policy.w2.T + policy.b2)
        logits_b = h2b @ policy.wo.T + policy.bo
        lmax_b = logits_b.max(axis=1, keepdims=True)
        e_b = np.exp(logits_b - lmax_b)
        pb = e_b / e_b.sum(axis=1, keepdims=True)
        # CE 梯度 wrt logits：(p - onehot) * β / nbc
        dlogits_b = pb.copy()
        dlogits_b[np.arange(nbc), sbc] -= 1
        dlogits_b *= bc_beta / nbc
        dbc_h2 = dlogits_b @ policy.wo
        dbc_h2[h2b <= 0] = 0
        dbc_h1 = dbc_h2 @ policy.w2
        dbc_h1[h1b <= 0] = 0
        grads['wo'] += dlogits_b.T @ h2b
        grads['bo'] += dlogits_b.sum(axis=0)
        grads['w2'] += dbc_h2.T @ h1b
        grads['b2'] += dbc_h2.sum(axis=0)
        grads['w1'] += dbc_h1.T @ Xbc
        grads['b1'] += dbc_h1.sum(axis=0)
        total_loss += (np.log(pb[np.arange(nbc), sbc] + 1e-12) * -bc_beta).mean()
    for k, gr in grads.items():
        g = getattr(policy, k)
        g -= lr * gr
    return float(loss_p + loss_v)


# ── 评估：完整测试（对局 + 能力考试 + 综合评分 0-100）──
# 规格与 triggerEval/monitor 统一（easy=4,normal=4,hard=8 = 16 局）：
# 8 局评估噪声太大（vsHard 4 局赢 1 局=12% 与赢 3 局=38% 同权重可复现），
# 之前 RL 训练内 58 分 vs 部署评估 48 分的 10 分差就是规格不一致导致的。
EVAL_SPEC = 'easy=4,normal=4,hard=8'

def eval_model_score(policy, tmp_path='/root/aim/train_data/rl_eval_tmp.json'):
    """保存策略到临时权重，跑完整评估，返回 (score_total, grade)"""
    policy.save(tmp_path, version=0)
    from eval_model import run_eval
    data = run_eval(tmp_path, EVAL_SPEC)
    if not data:
        return None, None
    sc = data['score']
    return sc['total'], sc['grade']


def write_status(data):
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    with open(STATUS_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f)


def append_history(games, score, grade, avg):
    """RL 评估历史（波形图数据源）：记录综合测试得分。
    只保留最近 HISTORY_WINDOW_GAMES 局（一局=一次训练）：从尾部累计覆盖局数，
    跨训练 games 重置时按 EVAL_EVERY 近似。"""
    os.makedirs(os.path.dirname(HISTORY_FILE), exist_ok=True)
    rec = {'games': games, 'score': score, 'grade': grade,
           'avgReward': round(avg, 3), 'ts': time.strftime('%Y-%m-%d %H:%M:%S')}
    lines = []
    if os.path.exists(HISTORY_FILE):
        with open(HISTORY_FILE, encoding='utf-8') as f:
            lines = [json.loads(l) for l in f if l.strip()]
    lines.append(rec)
    keep = []
    covered = 0
    for i in range(len(lines) - 1, -1, -1):
        keep.append(lines[i])
        if i == len(lines) - 1:
            covered = EVAL_EVERY
        else:
            step = lines[i + 1]['games'] - lines[i]['games']
            covered += step if 0 < step <= 500 else EVAL_EVERY
        if covered >= HISTORY_WINDOW_GAMES:
            break
    keep.reverse()
    with open(HISTORY_FILE, 'w', encoding='utf-8') as f:
        for d in keep:
            f.write(json.dumps(d) + '\n')


def base_win_rate():
    """原模型（BC 基础）能力：eval_result.json 的 vs hard 胜率"""
    try:
        if os.path.exists(EVAL_FILE):
            ev = json.load(open(EVAL_FILE, encoding='utf-8'))
            return ev.get('summary', {}).get('vsHard')
    except Exception:
        pass
    return None


def load_human_data(path=HUMAN_DATA):
    """读人类对局 → BC 样本 (X, slots)。数据不足返回 None（纯 RL 阶段）。"""
    try:
        from train_bc import load_games, build_samples
    except Exception:
        return None
    try:
        games = load_games(path)
        if not games:
            return None
        X, Y, stats = build_samples(games)
        if X is None or len(X) < 10:
            return None
        return X, np.argmax(Y, axis=1)
    except Exception:
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
    print(f'=== BC+RL 混合训练启动（base=BC v{base_version}）目标局数={target_games or "无限"} ===', flush=True)
    if os.path.exists(STOP_FILE):
        os.remove(STOP_FILE)
    # 起点：BC 权重（train_weights.json，16 格 101→193）；无权重 → 从零初始化
    start_weights = BC_WEIGHTS
    policy = RlPolicy(BC_WEIGHTS, seed=42)
    print('从 BC 权重起步（无权重则从零随机初始化）', flush=True)
    base_ref = RlPolicy(BC_WEIGHTS, seed=0)  # 行为诊断参照（对比外部基线）
    opponent = policy.clone()  # 延迟快照对手
    optimizer_lr = LR
    total_games = 0
    try:
        # 从上次心跳续接局数（波形图连续）
        if os.path.exists(STATUS_FILE):
            total_games = int(json.load(open(STATUS_FILE, encoding='utf-8')).get('games', 0))
    except Exception:
        pass
    start_games = total_games  # 本轮起点；target 按本轮局数判定
    rewards = []
    batch = []
    bc_pool = load_human_data()   # 人类样本池（模仿约束），数据不足时 None
    last_bc_loaded = 0
    devour_total = [0, 0]   # [吞敌, 吞己] 累计（验证吞噬修正效果）
    sp_wins = 0             # 策略 vs 延迟快照胜局数（学习信号）
    score_window = []       # 最近 N 次评估分数（平台期检测）
    plateau_count = 0       # 平台期持续档位（探索率据此提升）
    t0 = time.time()
    base_wr = base_win_rate()  # 原模型（BC 基础）vs hard 胜率（保留参考）
    base_score = None
    try:
        if os.path.exists(EVAL_FILE):
            base_score = json.load(open(EVAL_FILE, encoding='utf-8')).get('score', {}).get('total')
    except Exception:
        pass
    # 用起点权重实时评估一次——基准线与实际 warm start 权重一致
    try:
        from eval_model import run_eval
        data = run_eval(start_weights, EVAL_SPEC)
        if data:
            base_score = data['score']['total']
            base_wr = data['summary'].get('vsHard')
            print(f'实时基准评估: 起点综合分 {base_score}（{data["score"]["grade"]}） vsHard {base_wr}', flush=True)
    except Exception as e:
        print(f'实时基准评估失败（用缓存值）: {e}', flush=True)
    print(f'原模型 vs hard 基准胜率: {base_wr}  综合评分: {base_score}', flush=True)
    if bc_pool is not None:
        print(f'人类模仿样本: {len(bc_pool[0])} 条（β={BC_BETA}，每 {BC_RELOAD_EVERY} 局刷新）', flush=True)
    else:
        print('暂无人像模仿样本（纯 RL 阶段，人类数据到位后自动混合）', flush=True)

    while True:
        round_games = total_games - start_games  # 本轮局数（周期判定用，从存档继续不错乱）
        if os.path.exists(STOP_FILE):
            print('检测到停止信号，保存退出', flush=True)
            try:
                v = int(json.load(open(BC_WEIGHTS, encoding='utf-8')).get('version', 0)) + 1
            except Exception:
                v = 1
            policy.save(BC_WEIGHTS, version=v, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(float(np.mean(rewards[-50:])) if rewards else 0, 3),
                               'temp': policy.temp})
            write_status({'state': 'stopped', 'games': total_games, 'baseWinRate': base_wr,
                          'temp': policy.temp,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
            return
        # 对手：1/3 局打规则 AI（轮换 easy/normal/hard，对齐评估目标），
        # 其余打延迟快照（自博弈）。
        if round_games > 0 and round_games % 3 == 0:
            level = ('easy', 'normal', 'hard')[(total_games // 3) % 3]
            opponent = RuleOpp(level, seed=total_games)
        elif (round_games > 0 and round_games % SNAP_EVERY == 0) or opponent is None:
            opponent = policy.clone()
        # 自博弈一局（只记录 policy 侧轨迹——对手侧样本会污染梯度）
        winner, traj, dev = play_game(policy, opponent, seed=total_games, record_for='a')
        total_games += 1
        devour_total[0] += dev['enemy']
        devour_total[1] += dev['self']
        if winner == 0:
            sp_wins += 1   # 策略赢延迟快照（旧自己）→ 学习信号
        # 达到目标局数 → 自动停止（优雅保存）；目标按「本轮局数」判定（从存档继续时累计不误触）
        if target_games > 0 and (total_games - start_games) >= target_games:
            score, grade = eval_model_score(policy)
            avg = float(np.mean(rewards[-50:])) if rewards else 0
            append_history(total_games, score, grade, avg)
            try:
                v = int(json.load(open(BC_WEIGHTS, encoding='utf-8')).get('version', 0)) + 1
            except Exception:
                v = 1
            policy.save(BC_WEIGHTS, version=v, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(avg, 3),
                               'score': score, 'grade': grade, 'targetGames': target_games,
                               'temp': policy.temp})
            write_status({'state': 'stopped', 'games': total_games, 'avgReward': round(avg, 3),
                          'score': score, 'grade': grade, 'baseWinRate': base_wr, 'baseScore': base_score,
                          'targetGames': target_games, 'temp': policy.temp,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
            print(f'目标局数 {target_games} 达成，自动停止。综合分 {score}（{grade}） 温度{policy.temp:.2f}', flush=True)
            return
        # 每步即时奖励 → 折现 return-to-go（按局），入 batch
        if traj:
            rs = np.array([t[3] for t in traj], dtype=np.float64)
            rewards.append(float(rs.mean()))   # 均奖 = 本局平均每步即时奖励
            rets = discount(rs, GAMMA)
            for (x, slot, lp, _r, _own), ret in zip(traj, rets):
                batch.append((x, slot, lp, ret))
        # 定期刷新人类模仿样本（增量吸收新对局）
        if bc_pool is not None or (round_games > 0 and round_games % BC_RELOAD_EVERY == 0):
            if round_games > 0 and round_games % BC_RELOAD_EVERY == 0:
                new_pool = load_human_data()
                if new_pool is not None:
                    bc_pool = new_pool
                    print(f'  人类模仿样本刷新: {len(bc_pool[0])} 条', flush=True)
        # 更新（每 BATCH_GAMES 局一次；RL+BC 联合，模仿的同时打分）
        if round_games > 0 and round_games % BATCH_GAMES == 0 and batch:
            loss = update(policy, batch, bc=bc_pool, lr=optimizer_lr)
            batch = []
        # 延迟快照对手
        if round_games > 0 and round_games % SNAP_EVERY == 0:
            opponent = policy.clone()
        # 定期评估 + 保存
        if round_games > 0 and round_games % EVAL_EVERY == 0:
            score, grade = eval_model_score(policy)
            avg = float(np.mean(rewards[-EVAL_EVERY:])) if rewards else 0
            # ── 行为变化诊断（每 200 局）：argmax 决策 vs base 的差异率 ──
            # 分数由 argmax 评估决定；权重在动 ≠ 行为在变，这个指标直接显示决策层变化
            if round_games > 0 and round_games % 200 == 0:
                from rules import AimGame
                same = diff = 0
                for _ in range(12):
                    g = AimGame(limit=16); guard = 0
                    while g.winner is None and guard < 300:
                        guard += 1
                        a1, _ = base_ref.act(g, sample=False)
                        a2, _ = policy.act(g, sample=False)
                        if a1 == a2: same += 1
                        else: diff += 1
                        r = g.apply_action(g.turn, a1, defer_roll=True)
                        if not r['ok']: break
                        while g.has_pending_roll:
                            if g.roll_step_once(g.turn) is None: g.clear_pending_roll(); break
                div = diff / (same + diff) * 100 if (same + diff) else 0
                print(f'  行为诊断: argmax 决策差异率 {div:.1f}%（vs base）', flush=True)
            print(f'[{total_games}局] 均奖 {avg:.2f} 综合分 {score}（{grade}） 温度{policy.temp:.2f} 吞敌{devour_total[0]} 吞己{devour_total[1]} 自博弈胜率{sp_wins/max(1, round_games)*100:.0f}% 耗时{(time.time()-t0)/60:.1f}m', flush=True)
            append_history(total_games, score, grade, avg)  # 波形图历史（综合得分）
            # ── 自适应探索：分数平台期 → 提高采样温度激发新行为（牢大定）──
            if score is not None:
                score_window.append(score)
                if len(score_window) > PLATEAU_WINDOW:
                    score_window.pop(0)
                if len(score_window) >= PLATEAU_WINDOW:
                    spread = max(score_window) - min(score_window)
                    if spread < PLATEAU_DELTA:
                        plateau_count += 1   # 平台期：温度档位 +1
                    else:
                        plateau_count = 0    # 分数在动，恢复正常温度
                new_temp = min(TEMP_BASE + TEMP_STEP * plateau_count, TEMP_MAX)
                if new_temp != policy.temp:
                    print(f'  自适应探索：温度 {policy.temp:.2f} → {new_temp:.2f}（平台档 {plateau_count}）', flush=True)
                    policy.temp = new_temp
            try:
                v = int(json.load(open(BC_WEIGHTS, encoding='utf-8')).get('version', 0)) + 1
            except Exception:
                v = 1
            policy.save(BC_WEIGHTS, version=v, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(avg, 3),
                               'score': score, 'grade': grade, 'temp': policy.temp})
            write_status({'state': 'running', 'games': total_games, 'avgReward': round(avg, 3),
                          'score': score, 'grade': grade, 'rlVersion': v,
                          'baseVersion': base_version, 'baseWinRate': base_wr, 'baseScore': base_score,
                          'temp': policy.temp,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
        elif round_games > 0 and round_games % SAVE_EVERY == 0:
            try:
                v = int(json.load(open(BC_WEIGHTS, encoding='utf-8')).get('version', 0)) + 1
            except Exception:
                v = 1
            write_status({'state': 'running', 'games': total_games,
                          'avgReward': round(float(np.mean(rewards[-SAVE_EVERY:])) if rewards else 0, 3),
                          'rlVersion': v, 'baseVersion': base_version,
                          'baseWinRate': base_wr, 'baseScore': base_score,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})


if __name__ == '__main__':
    main()
