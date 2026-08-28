#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIM 行为克隆 + 强化学习联合训练（hybrid：模仿的同时打分）—— 左右分离双策略版
- 左右 AI 权重不同（train_weights_left.json / train_weights_right.json），各自独立进化：
  左策略只从「左方（owner=0）」轨迹/人类样本学习，右策略只从「右方（owner=1）」学习
- 模仿（BC）：人类对局（games.jsonl）按 owner 分流进两侧，交叉熵约束各自不跑偏
- 打分（RL）：全部左右互搏自博弈（牢大定：规则 AI 没参考价值，不打不学），
  指标 = 纯各项测试（能力考试）+ 双方对决成功率（互搏）
- 联合 loss：L = L_ppo + β·L_bc，每次更新同时吃 RL 轨迹和人类样本（每侧独立）
- 网络：101 → 128 → 128 → 193（16 格棋盘，与 train_bc.py 同构）+ 价值头
- 产出：直接部署两份权重（训练场按人类所在侧加载对面权重）+ rl_status.json（心跳）
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

BASE_DIR = '/root/aim'
BC_WEIGHTS_LEFT = os.path.join(BASE_DIR, 'server/public/downloads/train_weights_left.json')
BC_WEIGHTS_RIGHT = os.path.join(BASE_DIR, 'server/public/downloads/train_weights_right.json')
STATUS_FILE = os.path.join(BASE_DIR, 'train_data', 'rl_status.json')
HISTORY_FILE = os.path.join(BASE_DIR, 'train_data', 'rl_history.jsonl')  # RL 评估历史（波形图用）
STOP_FILE = os.path.join(BASE_DIR, 'train', 'rl_stop')
EVAL_FILE = os.path.join(BASE_DIR, 'train_data', 'eval_result.json')
HUMAN_DATA = os.path.join(BASE_DIR, 'train_data', 'games.jsonl')
EVAL_TMP_L = os.path.join(BASE_DIR, 'train_data', 'rl_eval_tmp_left.json')
EVAL_TMP_R = os.path.join(BASE_DIR, 'train_data', 'rl_eval_tmp_right.json')

IN_DIM, HIDDEN, OUT = 16 * 6 + 5, 128, 16 * 12 + 1   # 101 → 128 → 128 → 193（16 格）
MAX_CELLS = 16
BC_BETA = 0.3          # BC 损失权重（模仿约束强度：太高学不出新东西，太低 RL 跑偏）
BC_RELOAD_EVERY = 10   # 每 N 局重新读人类数据（增量吸收新对局）
GAMMA = 0.99
LR = 1e-3              # 手写 SGD（2e-3 配强奖励震荡过拟合，1e-3 平衡）
BATCH_GAMES = 16       # 每攒 N 局更新一次（≈950 步样本/更新，PPO 多 epoch 复用）
PPO_EPOCHS = 4         # 每 batch 内循环更新次数（PPO 核心：样本复用）
PPO_CLIP = 0.2         # 重要性采样比率裁剪
SNAP_EVERY = 20        # 保留（与旧版兼容；纯互搏无需快照，动态噪点提供参照）
EVAL_EVERY = 25        # 每 N 局评估一次（牢大定：25 局，波形图更密）
SAVE_EVERY = 20        # 每 N 局保存权重 + 心跳
MAX_GUARD = 600        # 单局步数上限
HISTORY_WINDOW_GAMES = 1000  # rl_history 只保留最近 1000 局（RL 一局=一次训练，牢大定）

# ── 奖励塑形（针对 AIM 特殊性设计，非通用 RL 奖励）──
# 胜负判据是 sum_of（双方所有单位数值总和，谁先归零谁输），核心信号是
# 「战力差 Δ = 我方sum - 敌方sum」。
# 牢大定 2026：每步按「全局状态」打分（不是只奖励 Δ 变化）——
#   step_r = R_STATE * tanh(Δ/STATE_SCALE)  当前全局战力差的分（碾压→+，挨打→−）
#          + 事件奖励（击杀/损失/吞噬/重复警告）
#          − R_STEP_COST                     每走一步扣分：行动越多扣越多（逼高效）
# 终局 = 结果基础分（胜/败）± 全局行为修正（平均Δ/K-D/造兵，幅度封顶防刷奖励）
# 超9吞噬「变拉」（15→1+5=6）导致 sum 缩水，状态分自动惩罚，无需硬编码禁招。
R_STATE = 0.5         # 每步全局状态分权重（tanh 压缩到 ±1 后乘）
STATE_SCALE = 12.0    # 战力差归一化尺度：Δ=12 → tanh(1)≈0.76，Δ=24 → 0.96
R_STEP_COST = 0.02    # 每走一步扣分（行动成本：100 步 -2，200 步 -4，配合速战折扣双罚拖局）
R_KILL = 0.4          # 击杀敌方单位（Δ 之外的事件奖励）
R_LOSS = -0.3         # 己方单位被灭
R_DEVOUR_ENEMY = 0.8  # 吞噬敌方（Δ 已算 2v，这里只给引导量——2.0 会让策略无脑吞）
R_DEVOUR_SELF = -0.1  # 吞噬己方（合成 8/9 是运营核心，几乎不惩罚）
R_REPEAT_WARN = -0.6  # 第二次重复操作警告（第三次直接判负）
R_WIN = 5.0           # 终局胜利（主导信号）
R_LOSE = -5.0         # 终局失败
DEVOUR_PRIOR = 1.5    # 吞敌槽探索先验（logit 偏置，仅训练期引导，参与更新可被拉回）
EPS = 0.05            # ε 均匀探索基础值（固定：稀有合法动作也有公平机会被尝试）
# ── 自适应探索（牢大定 2026）：互搏失败率驱动噪点，左右独立 ──
# 指标 = 纯各项测试 + 双方对决成功率（互搏）；规则 AI 胜率不算数。
# 噪点用 temperature（softmax 温度）：概率变平但保持相对偏好，比 ε 均匀随机平滑——
# ε 提到 0.30 会让 30% 的步完全随机，训练数据被污染，自博弈胜率反而掉（实测 50%→44%）。
# 核心规则：某侧互搏失败率一直很低（一直赢）→ 该侧尝试更激进的噪点随机，
# 走出舒适区（避免自博弈里赢家固化打法，给输家追赶空间）。
TEMP_BASE = 1.0       # 采样温度基础值
TEMP_STEP = 0.3       # 每触发一次加噪点，温度 +0.3
TEMP_MAX = 2.5        # 温度封顶（太激进会变成随机乱打）
DUEL_WINDOW = 40      # 互搏失败率滑动窗口（最近 N 局互搏）
FAIL_LOW = 0.2        # 失败率 ≤20%（胜率 ≥80%）→ 一直赢 → 加噪点
FAIL_HIGH = 0.5       # 失败率 ≥50% → 输麻了 → 温度回落收敛
ENTROPY_BETA = 0.02   # 熵正则系数：强制策略保持随机性，argmax 不早熟固化——
                      # 否则 PPO 只强化当前最优动作，argmax 永不翻转（实测 15000 局只变 1%）
# ── 速战速决奖励（牢大定）：对齐评估「速战速决」指标 ──
# 20 回合内赢 → 全额 R_WIN；之后每拖 10 回合扣 1（下限 0.5）；输仍 R_LOSE
WIN_TURNS_OK = 20
WIN_TURN_PENALTY = 1.0   # 每 10 回合扣分（WIN_TURN_PENALTY * 10 回合）
# ── 终局综合打分（牢大定 2026）：不固定 ±R_WIN，按全局行为 + 最后结果综合 ──
# 结果基础分（胜 R_WIN / 败 R_LOSE）仍主导胜负信号，行为分只调幅度：
#   avg_delta（整局平均战力差）：碾压 → 加满；被压 → 减
#   K/D：杀人多死得少 → 加；K/D=1 中性
#   造兵：运营好 → 小幅加
# 胜方最高 +1.5（碾压 6.5），最低 -1.5（侥幸翻盘 3.5）；
# 败方 -1.0 ~ +1.0（体面败 -4，被碾压 -6）。行为分幅度封顶，防刷奖励。
BEHAVIOR_DELTA = 15.0    # 平均战力差归一化尺度（平均领先 15 点 = 满分）
BEHAVIOR_KD = 2.0        # K/D 归一化尺度（(kd-1)/2 后截断 ±1）
BEHAVIOR_PROD = 12.0     # 造兵数归一化尺度（造 12 个 = 满分）
BEHAVIOR_WIN = 1.5       # 胜方行为分上限
BEHAVIOR_LOSE = 1.0      # 败方行为分上限


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
            # 恢复各自温度（左右独立噪点，重启后延续探索状态）
            if 'temp' in w:
                try:
                    self.temp = float(w['temp'])
                except Exception:
                    pass
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


# ── 自博弈一局：返回 (winner, traj, devour_stat) ──
# traj: [(x, slot, lp, r, owner)] 每步即时奖励（终局综合分已并入最后一步）
# devour_stat: {'enemy': n, 'self': n} 本局吞噬敌/己次数（验证修正效果）
# record_for: 'a'=只记玩家0（左）侧轨迹；'b'=只记玩家1（右）侧；'both'=两侧都记（左右互搏）
# 奖励设计（牢大定 2026）：
#   1. 每步按全局状态打分：R_STATE * tanh(Δ/STATE_SCALE)，Δ=动作后我方战力差——
#      碾压局面每步拿正分，挨打局面每步拿负分（不是只奖励变化量）
#   2. 事件奖励：击杀/损失/吞噬敌/吞噬己/重复警告
#   3. 每走一步扣 R_STEP_COST：行动越多扣越多，逼策略高效不磨蹭
#   4. 滚木回合间自动结算：按滚木后全局状态给分，挂在其下一次行动上（pending），不扣步数
#   5. 终局综合打分：结果基础分（胜/败）+ 全局行为修正（平均战力差/K/D/造兵）
def play_game(policy_a, policy_b, seed=0, record_for='a'):
    g = AimGame(limit=16)
    ai_a, ai_b = policy_a, policy_b  # 玩家0=policy_a（左），玩家1=policy_b（右）
    traj = []
    pending = [0.0, 0.0]   # 滚木结算奖励，等滚木主人下一次行动时并入
    devour_stat = {'enemy': 0, 'self': 0}
    delta_acc = [0.0, 0.0]  # 每步战力差累加（owner 视角，综合打分用）
    delta_n = [0, 0]        # 采样步数
    guard = 0
    while g.winner is None and guard < MAX_GUARD:
        guard += 1
        owner = g.turn
        p = ai_a if owner == 0 else ai_b
        a, lp = p.act(g, sample=True)
        if a is None:
            break
        # 是否需要记录本步（ε 探索步 lp=None 不记录；规则 AI 无 encode 接口，
        # 但 record_for 只针对模型侧 owner，规则 AI 执另一侧时天然不记）
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
        # 牢大定：每步按全局状态打分（tanh 压缩战力差）+ 事件奖励 − 行动成本
        delta1 = g.sum_of(owner) - g.sum_of(1 - owner)
        delta_acc[owner] += delta1
        delta_n[owner] += 1
        step_r = R_STATE * np.tanh(delta1 / STATE_SCALE) - R_STEP_COST
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
            rk0, rl0 = g.stats['kills'][roller], g.stats['losses'][roller]
            while g.has_pending_roll:
                if g.roll_step_once(g.turn) is None:
                    g.clear_pending_roll()
                    break
            rd1 = g.sum_of(roller) - g.sum_of(1 - roller)
            delta_acc[roller] += rd1
            delta_n[roller] += 1
            # 滚木结算：按全局状态打分（不扣步数——不是行动），事件奖励照旧
            roll_r = R_STATE * np.tanh(rd1 / STATE_SCALE)
            rk1, rl1 = g.stats['kills'][roller], g.stats['losses'][roller]
            roll_r += R_KILL * (rk1 - rk0) + R_LOSS * (rl1 - rl0)
            pending[roller] += roll_r
        # 记录模型侧轨迹（动作前状态 x_before + 动作前槽位，与 BC 数据/评估一致）
        # lp=None = ε 探索步（off-policy），不参与学习
        if need_record:
            if slot is not None:
                traj.append((x_before, slot, lp, step_r + pending[owner], owner))
                pending[owner] = 0.0
    # ── 终局综合打分（并入两侧各自最后一步，含未结算的滚木奖励）──
    # 牢大定：不固定 ±R_WIN——结果基础分 + 全局行为修正（平均战力差/K/D/造兵）。
    # 胜方：基础分（速战速决折扣）±行为分；败方：R_LOSE ±行为分（体面败少扣）。
    # 两侧都结算：赢家 +、输家 -，各自从自己侧轨迹拿到终局信号。
    if g.winner is not None and traj:
        for own in (0, 1):
            idx = None
            for i in range(len(traj) - 1, -1, -1):
                if traj[i][4] == own:
                    idx = i
                    break
            if idx is None:
                continue
            x, slot, lp, rr, _o = traj[idx]
            # 全局行为（own 视角）：整局平均战力差 + K/D + 造兵运营
            avg_delta = delta_acc[own] / delta_n[own] if delta_n[own] else 0.0
            k = g.stats['kills'][own]
            l = g.stats['losses'][own]
            kd = (k / l) if l else (3.0 if k > 0 else 1.0)   # 没死 → K/D 视为优秀
            d_score = max(-1.0, min(1.0, avg_delta / BEHAVIOR_DELTA))
            kd_score = max(-1.0, min(1.0, (kd - 1.0) / BEHAVIOR_KD))
            prod_score = max(0.0, min(1.0, g.stats['produce'][own] / BEHAVIOR_PROD))
            behavior = 0.6 * d_score + 0.3 * kd_score + 0.1 * prod_score
            if own == g.winner:
                base = max(0.5, R_WIN - max(0, g.turn_count - WIN_TURNS_OK) / 10.0 * WIN_TURN_PENALTY)
                final_r = base + behavior * BEHAVIOR_WIN
            else:
                final_r = R_LOSE + behavior * BEHAVIOR_LOSE
            traj[idx] = (x, slot, lp, rr + pending[own] + final_r, own)
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


# ── 评估：完整测试（互搏对局 + 能力考试 + 综合评分 0-100）──
# 牢大定：vs easy/normal/hard 胜率不算指标（规则 AI 没参考价值），
# 指标 = 纯各项测试（能力考试）+ 双方对决成功率（左右互搏）。
DUEL_GAMES = 16       # 评估互搏局数（左右各执一侧，双方对决成功率）

def eval_model_score(left_policy, right_policy):
    """保存双策略到临时权重，跑完整评估（互搏 + 能力考试）。
    结果落盘 eval_result.json（monitor 模型实力测试/考试面板实时数据源）"""
    left_policy.save(EVAL_TMP_L, version=0)
    right_policy.save(EVAL_TMP_R, version=0)
    from eval_model import run_eval
    data = run_eval(EVAL_TMP_L, EVAL_TMP_R, DUEL_GAMES, out_path=EVAL_FILE)
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


def next_version(path):
    try:
        if os.path.exists(path):
            return int(json.load(open(path, encoding='utf-8')).get('version', 0)) + 1
    except Exception:
        pass
    return 1


def base_win_rate():
    """原模型（BC 基础）能力：eval_result.json 的互搏胜率（左+右）/2"""
    try:
        if os.path.exists(EVAL_FILE):
            ev = json.load(open(EVAL_FILE, encoding='utf-8'))
            d = ev.get('duel')
            if d:
                return round((d.get('leftRate', 0) + d.get('rightRate', 0)) / 2, 2)
    except Exception:
        pass
    return None


def load_human_data(path=HUMAN_DATA):
    """读人类对局 → 按 owner 分流的 BC 样本。
    返回 {'left': (X, slots)|None, 'right': (X, slots)|None}；无数据返回 None。"""
    try:
        from train_bc import load_games, build_samples
    except Exception:
        return None
    try:
        games = load_games(path)
        if not games:
            return None
        out = {}
        for side, key in ((0, 'left'), (1, 'right')):
            try:
                X, Y, _st = build_samples(games, side=side)
            except Exception:
                X = None
            if X is not None and len(X) >= 10:
                out[key] = (X, np.argmax(Y, axis=1))
        return out or None
    except Exception:
        return None


def bc_count(pool, key):
    if pool is None or key not in pool:
        return 0
    return len(pool[key][0])


def decision_diff(policy, base_ref, n=6):
    """行为诊断：argmax 决策 vs base 的差异率（全局面轮转，两策略独立对比）"""
    from rules import AimGame
    same = diff = 0
    for _ in range(n):
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
    return diff / (same + diff) * 100 if (same + diff) else 0


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--games', type=int, default=0,
                    help='目标训练局数（0=无限跑；跑满自动停止并保存）')
    args = ap.parse_args()
    target_games = args.games
    print('=== BC+RL 混合训练启动（左右双策略独立进化）目标局数=%s ===' % (target_games or '无限'), flush=True)
    if os.path.exists(STOP_FILE):
        os.remove(STOP_FILE)
    # 左右策略各自加载/初始化（无权重 → 从零随机初始化，互不影响）
    left_policy = RlPolicy(BC_WEIGHTS_LEFT, seed=42)
    right_policy = RlPolicy(BC_WEIGHTS_RIGHT, seed=7)
    print('左策略: %s；右策略: %s' % (
        '从零初始化' if not os.path.exists(BC_WEIGHTS_LEFT) else '从左权重起步',
        '从零初始化' if not os.path.exists(BC_WEIGHTS_RIGHT) else '从右权重起步'), flush=True)
    base_ref_left = RlPolicy(BC_WEIGHTS_LEFT, seed=0)   # 行为诊断参照（与左策略同起点）
    base_ref_right = RlPolicy(BC_WEIGHTS_RIGHT, seed=1)
    optimizer_lr = LR
    total_games = 0
    try:
        # 从上次心跳续接局数（波形图连续）
        if os.path.exists(STATUS_FILE):
            total_games = int(json.load(open(STATUS_FILE, encoding='utf-8')).get('games', 0))
    except Exception:
        pass
    start_games = total_games  # 本轮起点；target 按本轮局数判定
    rewards_l, rewards_r = [], []
    batch_left, batch_right = [], []
    bc_pool = load_human_data()   # 人类样本池（按 side 分流），数据不足时 None
    devour_total = [0, 0]   # [吞敌, 吞己] 累计（验证吞噬修正效果）
    duel_wins = [0, 0]      # 互搏局胜场（只算左右互搏，规则 AI 局不算——牢大：指标=双方对决成功率）
    duel_results = []       # 最近互搏局 winner 序列（滑动窗口，动态噪点用）
    t0 = time.time()
    base_wr = base_win_rate()  # 原模型 vs hard 胜率（保留参考）
    base_score = None
    # 用起点权重实时评估一次（无权重则跳过）
    try:
        from eval_model import run_eval
        if os.path.exists(BC_WEIGHTS_LEFT) or os.path.exists(BC_WEIGHTS_RIGHT):
            data = run_eval(BC_WEIGHTS_LEFT, BC_WEIGHTS_RIGHT, DUEL_GAMES)
            if data:
                base_score = data['score']['total']
                base_wr = data['duel'].get('leftRate')
                print(f'实时基准评估: 起点综合分 {base_score}（{data["score"]["grade"]}） 互搏左胜率 {base_wr}', flush=True)
    except Exception as e:
        print(f'实时基准评估失败（跳过）: {e}', flush=True)
    print(f'原模型互搏胜率基准: {base_wr}  综合评分: {base_score}', flush=True)
    if bc_pool is not None:
        print(f'人类模仿样本: 左 {bc_count(bc_pool, "left")} 条 / 右 {bc_count(bc_pool, "right")} 条（β={BC_BETA}，每 {BC_RELOAD_EVERY} 局刷新）', flush=True)
    else:
        print('暂无人像模仿样本（纯 RL 阶段，人类数据到位后自动混合）', flush=True)

    while True:
        round_games = total_games - start_games  # 本轮局数（周期判定用，从存档继续不错乱）
        if os.path.exists(STOP_FILE):
            print('检测到停止信号，保存退出', flush=True)
            lv = next_version(BC_WEIGHTS_LEFT)
            rv = next_version(BC_WEIGHTS_RIGHT)
            left_policy.save(BC_WEIGHTS_LEFT, version=lv,
                             extra={'games': total_games, 'side': 'left',
                                    'avgReward': round(float(np.mean(rewards_l[-50:])) if rewards_l else 0, 3),
                                    'temp': left_policy.temp})
            right_policy.save(BC_WEIGHTS_RIGHT, version=rv,
                              extra={'games': total_games, 'side': 'right',
                                     'avgReward': round(float(np.mean(rewards_r[-50:])) if rewards_r else 0, 3),
                                     'temp': right_policy.temp})
            write_status({'state': 'stopped', 'games': total_games, 'baseWinRate': base_wr,
                          'leftVersion': lv, 'rightVersion': rv,
                          'leftTemp': left_policy.temp, 'rightTemp': right_policy.temp,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
            return
        # ── 一局自博弈 ──
        # 全部左右互搏（牢大定：easy/normal/hard 规则 AI 没参考价值，不打也不学）
        winner, traj, dev = play_game(left_policy, right_policy, seed=total_games, record_for='both')
        # 互搏局战绩（双方对决成功率 = 牢大定的核心指标）
        if winner == 0:
            duel_wins[0] += 1
        elif winner == 1:
            duel_wins[1] += 1
        if winner is not None:
            duel_results.append(winner)
            if len(duel_results) > DUEL_WINDOW:
                duel_results.pop(0)
        total_games += 1
        devour_total[0] += dev['enemy']
        devour_total[1] += dev['self']
        # 达到目标局数 → 自动停止（优雅保存）；目标按「本轮局数」判定（从存档继续时累计不误触）
        if target_games > 0 and (total_games - start_games) >= target_games:
            score, grade = eval_model_score(left_policy, right_policy)
            avg = float(np.mean(rewards_l[-50:] + rewards_r[-50:])) if (rewards_l or rewards_r) else 0
            append_history(total_games, score, grade, avg)
            lv = next_version(BC_WEIGHTS_LEFT)
            rv = next_version(BC_WEIGHTS_RIGHT)
            left_policy.save(BC_WEIGHTS_LEFT, version=lv,
                             extra={'games': total_games, 'side': 'left', 'avgReward': round(avg, 3),
                                    'score': score, 'grade': grade, 'targetGames': target_games,
                                    'temp': left_policy.temp})
            right_policy.save(BC_WEIGHTS_RIGHT, version=rv,
                              extra={'games': total_games, 'side': 'right', 'avgReward': round(avg, 3),
                                     'score': score, 'grade': grade, 'targetGames': target_games,
                                     'temp': right_policy.temp})
            write_status({'state': 'stopped', 'games': total_games, 'avgReward': round(avg, 3),
                          'score': score, 'grade': grade, 'baseWinRate': base_wr, 'baseScore': base_score,
                          'leftVersion': lv, 'rightVersion': rv, 'targetGames': target_games,
                          'leftTemp': left_policy.temp, 'rightTemp': right_policy.temp,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
            print(f'目标局数 {target_games} 达成，自动停止。综合分 {score}（{grade}） 温度 L{left_policy.temp:.2f}/R{right_policy.temp:.2f}', flush=True)
            return
        # 每步即时奖励 → 折现 return-to-go（按侧分账，并入各自 batch）
        if traj:
            tL = [t for t in traj if t[4] == 0]
            tR = [t for t in traj if t[4] == 1]
            if tL:
                rs = np.array([t[3] for t in tL], dtype=np.float64)
                rewards_l.append(float(rs.mean()))
                rets = discount(rs, GAMMA)
                for (x, slot, lp, _r, _o), ret in zip(tL, rets):
                    batch_left.append((x, slot, lp, ret))
            if tR:
                rs = np.array([t[3] for t in tR], dtype=np.float64)
                rewards_r.append(float(rs.mean()))
                rets = discount(rs, GAMMA)
                for (x, slot, lp, _r, _o), ret in zip(tR, rets):
                    batch_right.append((x, slot, lp, ret))
        # 定期刷新人类模仿样本（增量吸收新对局）
        if bc_pool is not None or (round_games > 0 and round_games % BC_RELOAD_EVERY == 0):
            if round_games > 0 and round_games % BC_RELOAD_EVERY == 0:
                new_pool = load_human_data()
                if new_pool is not None:
                    bc_pool = new_pool
                    print(f'  人类模仿样本刷新: 左 {bc_count(bc_pool, "left")} 条 / 右 {bc_count(bc_pool, "right")} 条', flush=True)
        # 更新（每 BATCH_GAMES 局一次；左右各吃各自轨迹 + 各自人类样本）
        if round_games > 0 and round_games % BATCH_GAMES == 0:
            if batch_left:
                update(left_policy, batch_left, bc=bc_pool.get('left') if bc_pool else None, lr=optimizer_lr)
                batch_left = []
            if batch_right:
                update(right_policy, batch_right, bc=bc_pool.get('right') if bc_pool else None, lr=optimizer_lr)
                batch_right = []
        # 定期评估 + 保存
        if round_games > 0 and round_games % EVAL_EVERY == 0:
            score, grade = eval_model_score(left_policy, right_policy)
            avg = float(np.mean(rewards_l[-EVAL_EVERY:] + rewards_r[-EVAL_EVERY:])) if (rewards_l or rewards_r) else 0
            # ── 行为变化诊断（每 200 局）：argmax 决策 vs base 的差异率（左右各自）──
            if round_games > 0 and round_games % 200 == 0:
                dl = decision_diff(left_policy, base_ref_left)
                dr = decision_diff(right_policy, base_ref_right)
                print(f'  行为诊断: 左策略 diff {dl:.1f}% / 右策略 diff {dr:.1f}%（vs base）', flush=True)
            sp = round_games
            duel_total = duel_wins[0] + duel_wins[1]
            print(f'[{total_games}局] 均奖 L {float(np.mean(rewards_l[-50:])) if rewards_l else 0:.2f} / R {float(np.mean(rewards_r[-50:])) if rewards_r else 0:.2f} '
                  f'综合分 {score}（{grade}） 温度 L{left_policy.temp:.2f}/R{right_policy.temp:.2f} '
                  f'吞敌{devour_total[0]} 吞己{devour_total[1]} '
                  f'互搏胜率 L{duel_wins[0]/max(1, duel_total)*100:.0f}%/R{duel_wins[1]/max(1, duel_total)*100:.0f}% '
                  f'耗时{(time.time()-t0)/60:.1f}m', flush=True)
            append_history(total_games, score, grade, avg)  # 波形图历史（综合得分）
            # ── 自适应探索（牢大定）：互搏失败率驱动，左右独立 ──
            # 某侧失败率一直很低（一直赢）→ 该侧更激进噪点随机，走出舒适区；
            # 失败率太高（输麻了）→ 温度回落收敛。规则 AI 局不计（指标只认互搏）。
            if len(duel_results) >= 10:
                for side, pol in ((0, left_policy), (1, right_policy)):
                    fail = sum(1 for w in duel_results if w != side) / len(duel_results)
                    if fail <= FAIL_LOW:
                        nt = min(pol.temp + TEMP_STEP, TEMP_MAX)
                        if nt != pol.temp:
                            print(f'  动态噪点: {"左" if side == 0 else "右"}策略互搏失败率 {fail:.0%}（一直赢）→ 温度 {pol.temp:.2f} → {nt:.2f}（更激进探索）', flush=True)
                            pol.temp = nt
                    elif fail >= FAIL_HIGH:
                        nt = max(pol.temp - TEMP_STEP, TEMP_BASE)
                        if nt != pol.temp:
                            print(f'  动态噪点: {"左" if side == 0 else "右"}策略互搏失败率 {fail:.0%}（输麻了）→ 温度 {pol.temp:.2f} → {nt:.2f}（收敛）', flush=True)
                            pol.temp = nt
            lv = next_version(BC_WEIGHTS_LEFT)
            rv = next_version(BC_WEIGHTS_RIGHT)
            left_policy.save(BC_WEIGHTS_LEFT, version=lv,
                             extra={'games': total_games, 'side': 'left', 'avgReward': round(avg, 3),
                                    'score': score, 'grade': grade, 'temp': left_policy.temp,
                                    'duelWinRate': round(duel_wins[0] / max(1, duel_total), 3)})
            right_policy.save(BC_WEIGHTS_RIGHT, version=rv,
                              extra={'games': total_games, 'side': 'right', 'avgReward': round(avg, 3),
                                     'score': score, 'grade': grade, 'temp': right_policy.temp,
                                     'duelWinRate': round(duel_wins[1] / max(1, duel_total), 3)})
            write_status({'state': 'running', 'games': total_games, 'avgReward': round(avg, 3),
                          'score': score, 'grade': grade, 'rlVersion': lv,
                          'leftVersion': lv, 'rightVersion': rv, 'baseWinRate': base_wr, 'baseScore': base_score,
                          'leftTemp': left_policy.temp, 'rightTemp': right_policy.temp,
                          'duelWinRateL': round(duel_wins[0] / max(1, duel_total), 3),
                          'duelWinRateR': round(duel_wins[1] / max(1, duel_total), 3),
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
        elif round_games > 0 and round_games % SAVE_EVERY == 0:
            lv = next_version(BC_WEIGHTS_LEFT)
            rv = next_version(BC_WEIGHTS_RIGHT)
            avg = float(np.mean(rewards_l[-SAVE_EVERY:] + rewards_r[-SAVE_EVERY:])) if (rewards_l or rewards_r) else 0
            left_policy.save(BC_WEIGHTS_LEFT, version=lv,
                             extra={'games': total_games, 'side': 'left', 'avgReward': round(avg, 3),
                                    'temp': left_policy.temp})
            right_policy.save(BC_WEIGHTS_RIGHT, version=rv,
                              extra={'games': total_games, 'side': 'right', 'avgReward': round(avg, 3),
                                     'temp': right_policy.temp})
            write_status({'state': 'running', 'games': total_games, 'avgReward': round(avg, 3),
                          'rlVersion': lv, 'leftVersion': lv, 'rightVersion': rv,
                          'baseWinRate': base_wr, 'baseScore': base_score,
                          'leftTemp': left_policy.temp, 'rightTemp': right_policy.temp,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})


if __name__ == '__main__':
    main()
