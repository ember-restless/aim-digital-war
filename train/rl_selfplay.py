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
STOP_FILE = os.path.join(BASE_DIR, 'train', 'rl_stop')
EVAL_FILE = os.path.join(BASE_DIR, 'train_data', 'eval_result.json')

IN_DIM, HIDDEN, OUT = 53, 64, 49
MAX_CELLS = 8
GAMMA = 0.99
LR = 1e-4
SNAP_EVERY = 20       # 每 N 局快照一次对手
EVAL_EVERY = 50       # 每 N 局评估一次 vs hard
SAVE_EVERY = 20       # 每 N 局保存权重 + 心跳
MAX_GUARD = 600       # 单局步数上限


def xavier(fan_in, fan_out, rng):
    return rng.uniform(-1, 1, (fan_in, fan_out)) * np.sqrt(6.0 / (fan_in + fan_out))


def _is_silly(action, game, owner):
    """「合法但无意义」动作：attack 己方、split 8/9（与 dart TrainAi / eval_ai 一致）"""
    t = action.get('type')
    if t == 'attack':
        j = int(action.get('j', -1))
        if 0 <= j < len(game.cells):
            target = game.cells[j]
            if target.o == owner:
                return True
    if t == 'split':
        i = int(action.get('i', -1))
        if 0 <= i < len(game.cells):
            v = game.cells[i].v
            if v in (8, 9):
                return True
    return False


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

    def slot_of(self, action, flip):
        t = action.get('type')
        i = int(action.get('i', -1))
        if i < 0 or i >= MAX_CELLS:
            return None
        if flip:
            i = MAX_CELLS - 1 - i
        if t == 'move':
            return i * 6 + (1 if int(action.get('steps', 1)) >= 2 else 0)
        if t == 'attack':
            return i * 6 + 2
        if t == 'devour':
            return i * 6 + 3
        if t == 'split':
            return i * 6 + 4
        if t == 'produce':
            return i * 6 + 5
        if t == 'endTurn':
            return 48
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
        playable = [a for a in acts if a['type'] != 'endTurn' and not _is_silly(a, game, owner)]
        if not playable:
            return {'type': 'endTurn'}, 0.0
        flip = owner == 1
        x = self.encode(game)
        _, logits, _ = self.forward(x)
        slots = []
        cands = []
        for a in playable:
            s = self.slot_of(a, flip)
            if s is not None and s < OUT:
                slots.append(s)
                cands.append(a)
        if not cands:
            return playable[0], 0.0
        logits = logits[slots]
        if sample:
            e = np.exp((logits - logits.max()) / temp)
            p = e / e.sum()
            idx = self.rng.choice(len(cands), p=p)
            lp = float(np.log(p[idx] + 1e-12))
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


# ── 自博弈一局：返回 (winner, side0_is_model, trajectory, stats_diff) ──
# trajectory: [(x, slot, lp)] 记录模型每一步（两侧都记，owner 视角归一化）
def play_game(policy_a, policy_b, seed=0, record_for='both'):
    g = AimGame(limit=16)
    ai_a, ai_b = policy_a, policy_b  # 玩家0=policy_a，玩家1=policy_b
    traj = []
    guard = 0
    prev_stats = [dict(g.stats), dict(g.stats)]
    while g.winner is None and guard < MAX_GUARD:
        guard += 1
        owner = g.turn
        p = ai_a if owner == 0 else ai_b
        a, lp = p.act(g, sample=True)
        if a is None:
            break
        r = g.apply_action(owner, a, defer_roll=True)
        if not r['ok']:
            acts = g.get_legal_actions(owner)
            if not acts:
                break
            r = g.apply_action(owner, acts[0], defer_roll=True)
            if not r['ok']:
                break
            a, lp = acts[0], 0.0
        # 记录模型侧轨迹（视角归一化后）
        if record_for == 'both' or (record_for == 'a' and owner == 0) or (record_for == 'b' and owner == 1):
            x = p.encode(g)
            slot = p.slot_of(a, owner == 1)
            if slot is not None:
                traj.append((x, slot, lp))
        while g.has_pending_roll:
            if g.roll_step_once(g.turn) is None:
                g.clear_pending_roll()
                break
    return g.winner, traj


# ── REINFORCE + 价值基线更新 ──
def update(policy, batch, lr=LR):
    """batch: [(x, slot, lp, R)] 每步样本；R = 该局总奖励"""
    if not batch:
        return 0.0
    X = np.array([b[0] for b in batch], dtype=np.float64)
    slots = np.array([b[1] for b in batch], dtype=np.int64)
    lps = np.array([b[2] for b in batch], dtype=np.float64)
    R = np.array([b[3] for b in batch], dtype=np.float64)
    # 前向
    h1 = np.maximum(0, X @ policy.w1.T + policy.b1)
    h2 = np.maximum(0, h1 @ policy.w2.T + policy.b2)
    logits = h2 @ policy.wo.T + policy.bo
    values = h2 @ policy.wv.T + policy.bv
    # 策略概率 + logprob（按 slot 索引）
    lmax = logits.max(axis=1, keepdims=True)
    e = np.exp(logits - lmax)
    probs = e / e.sum(axis=1, keepdims=True)
    row = np.arange(len(batch))
    lp_cur = np.log(probs[row, slots] + 1e-12)
    # 价值基线（batch 内平均 R），advantage
    baseline = R.mean()
    adv = R - baseline
    # 损失
    loss_p = -(adv * lp_cur).mean()
    loss_v = ((R[:, None] - values) ** 2).mean()
    # 反向
    dlogits = probs.copy()
    dlogits[row, slots] -= 1
    dlogits *= (adv / len(batch))[:, None]   # 策略梯度（-logprob 的梯度）
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


# ── 评估 vs hard 启发式 ──
def eval_vs_hard(policy, games=10, seed=0):
    wins = 0
    for i in range(games):
        w, _ = play_game(policy, _hard_ai(seed + i), seed=i, record_for='none')
        if w == 0:
            wins += 1
    return wins / games


def _hard_ai(seed):
    return _Heuristic(seed)


class _Heuristic:
    """启发式对手包装（decide 接口同策略）"""

    def __init__(self, seed):
        self.ai = AimAi('hard', seed=seed)

    def act(self, game, sample=True, temp=1.0, fallback_seed=0):
        a = self.ai.decide(game)
        return a, 0.0


def write_status(data):
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    with open(STATUS_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f)


def main():
    base_version = 0
    try:
        if os.path.exists(BC_WEIGHTS):
            base_version = int(json.load(open(BC_WEIGHTS, encoding='utf-8')).get('version', 0))
    except Exception:
        pass
    print(f'=== 自博弈强化学习启动 base=BC v{base_version} ===', flush=True)
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
    t0 = time.time()

    while True:
        if os.path.exists(STOP_FILE):
            print('检测到停止信号，保存退出', flush=True)
            policy.save(RL_WEIGHTS, version=rl_version, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(float(np.mean(rewards[-50:])) if rewards else 0, 3)})
            write_status({'state': 'stopped', 'games': total_games, 'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
            return
        # 自博弈一局（策略 vs 延迟快照）
        winner, traj = play_game(policy, opponent, seed=total_games)
        total_games += 1
        # 奖励：胜负 ±1（我方=policy 在玩家0）
        R = 1.0 if winner == 0 else -1.0
        rewards.append(R)
        for (x, slot, lp) in traj:
            batch.append((x, slot, lp, R))
        # 更新
        if len(batch) >= 64:
            loss = update(policy, batch, lr=optimizer_lr)
            batch = []
        # 延迟快照对手
        if total_games % SNAP_EVERY == 0:
            opponent = policy.clone()
        # 定期评估 + 保存
        if total_games % EVAL_EVERY == 0:
            wr = eval_vs_hard(policy, games=10)
            avg = float(np.mean(rewards[-EVAL_EVERY:])) if rewards else 0
            print(f'[{total_games}局] 近{EVAL_EVERY}局均奖 {avg:.2f} vs hard {wr:.0%} 耗时{(time.time()-t0)/60:.1f}m', flush=True)
            policy.save(RL_WEIGHTS, version=rl_version, base_version=base_version,
                        extra={'games': total_games, 'avgReward': round(avg, 3), 'winRateVsHard': round(wr, 3)})
            write_status({'state': 'running', 'games': total_games, 'avgReward': round(avg, 3),
                          'winRateVsHard': round(wr, 3), 'rlVersion': rl_version,
                          'baseVersion': base_version, 'ts': time.strftime('%Y-%m-%d %H:%M:%S')})
        elif total_games % SAVE_EVERY == 0:
            write_status({'state': 'running', 'games': total_games,
                          'avgReward': round(float(np.mean(rewards[-SAVE_EVERY:])) if rewards else 0, 3),
                          'rlVersion': rl_version, 'baseVersion': base_version,
                          'ts': time.strftime('%Y-%m-%d %H:%M:%S')})


if __name__ == '__main__':
    main()
