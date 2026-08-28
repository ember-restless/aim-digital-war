#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIM 行为克隆训练（模仿学习）—— 从训练场对局数据学人类走法
- 数据：/root/aim/train_data/games.jsonl（每行一局，训练场 /api/train/upload 写入）
- 网络：MLP 134 → 128 → 128 → 305（槽位 = 16格×19操作 + endTurn，split 按 keep 拆 8 槽，与 client/lib/train/train_ai.dart 同构）
- 输出：train_weights_left.json / train_weights_right.json（左右 AI 独立权重，--side 指定训练侧；
  version 自增，客户端拉取即生效）
用法：python3 train_bc.py [--epochs 80] [--deploy] [--side left|right]
"""
import argparse
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, '/root/aim/pc')
from rules import AimGame, AimCell

DATA_FILE = '/root/aim/train_data/games.jsonl'
WEIGHTS_LEFT = '/root/aim/server/public/downloads/train_weights_left.json'
WEIGHTS_RIGHT = '/root/aim/server/public/downloads/train_weights_right.json'
OUT_SLOTS = 16 * 19 + 1  # 305：16格×19槽 + endTurn —— 与人类操作全集一致
# 每格 19 槽：move1, move2, atk敌1..3, atk己1..3, dev敌, dev己,
#            split keep=1..8（人类可指定拆分比例！8 槽覆盖 9 以内全部拆分）, produce
# 旧版 split 只有 1 槽 → argmax 永远拆 keep=1（8→1+7 自毁基地、7→1+6 拆出滚木），
# 网络根本表达不了「怎么拆」，只能选「拆不拆」。本次升级让 keep 进网络。
IN_DIM = 16 * 8 + 6      # 134：16格×8特征 + 6全局 —— 与人类视野一致
# 每格 8 特征：v/9, isMe, isEnemy, bridge, onBridge, auto,
#            pressedV/9（滚木脚下压着的单位值，人类可见）, hasPressed（有无按压）
# 全局 6：0(占位), phaseA, phaseP, points/10, produceLeft/8, turnCount/100
HIDDEN = 128
MAX_CELLS = 16           # 与游戏 limit=16 对齐

# ── 数据加载 ──
def load_games(path):
    games = []
    if not os.path.exists(path):
        return games
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                games.append(json.loads(line))
            except Exception:
                continue
    return games

def rebuild(step, limit):
    """从记录重建 AimGame（操作前状态）"""
    g = AimGame(limit=limit or 16)
    cells = []
    for enc in step['cells'][:MAX_CELLS]:
        v, o, bridge, onBridge, auto = enc
        # 防御：联机记录里桥格子 v 可能是 null/None（服务器规则桥无 v 字段），按 0 处理
        cells.append(AimCell(int(v) if v is not None else 0,
                             o=None if o == -1 else (int(o) if o is not None else None),
                             bridge=bool(bridge), onBridge=bool(onBridge), auto=bool(auto)))
    # 补足 16 格（与游戏 limit=16 对齐；棋盘动态增长，记录最多 16 格）
    while len(cells) < MAX_CELLS:
        cells.append(AimCell(0))
    g.cells = cells
    g.turn = int(step['turn'])
    g.phase = step['phase']
    g.points = int(step.get('points', 0))
    g.produce_left = int(step.get('produceLeft', 0))
    return g

def normalize_view(g, owner):
    """视角归一化：人类（owner）恒为玩家0（左方）——若 owner==1 则镜像棋盘+重标+turn=0。
    返回是否发生了翻转（动作槽位的格子索引也要镜像）。"""
    if owner == 0:
        return False
    # 镜像棋盘：左右翻转
    g.cells = list(reversed(g.cells))
    for c in g.cells:
        if c.o == 0:
            c.o = 1
        elif c.o == 1:
            c.o = 0
    g.turn = 0
    return True

def action_slot(action, flip=False, game=None):
    """动作 → 槽位（305）：每格 19 槽——
    move1, move2, atk敌1..3, atk己1..3, dev敌, dev己, split keep=1..8, produce
    攻击/吞噬槽位按「目标敌我 × 距离」细分，AI 能明确指定打谁（敌方优先习得）
    split 按 keep 细分 8 槽——人类能指定拆分比例（1+6 / 3+4 / 4+3...），
    网络必须能表达「怎么拆」，不再强制 keep=1 的自毁拆法。
    注意：翻转（flip）时 i 和 j 都必须镜像——game 已被 normalize_view 镜像
    且恒为 16 格（rebuild 补零），镜像公式 MAX_CELLS-1-i = 15-i 与推理端
    （补零到 16 格后 15-i）一致，否则右方状态下敌我判定错位会导致打自己。
    """
    t = action.get('type')
    i = int(action.get('i', -1))
    if i < 0 or i >= MAX_CELLS:
        return None
    if flip:
        i = MAX_CELLS - 1 - i  # 镜像：格子索引翻转
    if t == 'move':
        steps = int(action.get('steps', 1))
        return i * 19 + (1 if steps >= 2 else 0)
    if t == 'attack':
        k = abs(int(action.get('j', -1)) - int(action.get('i', -1)))  # 目标距离 1..3（翻转不变）
        if k < 1 or k > 3:
            return None
        j = int(action.get('j', -1))
        if flip:
            j = MAX_CELLS - 1 - j  # 目标格镜像（game 已镜像）
        # 目标是否敌方（o 非空且不是我方）
        is_enemy = bool(game is not None and 0 <= j < len(game.cells)
                        and game.cells[j].o is not None and game.cells[j].o != game.turn)
        return i * 19 + (2 + (k - 1) if is_enemy else 5 + (k - 1))
    if t == 'devour':
        j = int(action.get('j', -1))
        if flip:
            j = MAX_CELLS - 1 - j  # 目标格镜像（game 已镜像）
        is_enemy = False
        if game is not None and 0 <= j < len(game.cells):
            is_enemy = game.cells[j].o is not None and game.cells[j].o != game.turn
        return i * 19 + (8 if is_enemy else 9)
    if t == 'split':
        keep = int(action.get('keep', 1))
        if keep < 1 or keep > 8:
            return None
        return i * 19 + (9 + keep)  # keep=1→槽10, keep=2→槽11 ... keep=8→槽17
    if t == 'produce':
        return i * 19 + 18
    if t == 'endTurn':
        return 16 * 19
    return None

def core_eq(a, b):
    for k in ('type', 'i', 'j', 'steps', 'keep'):
        if a.get(k) != b.get(k):
            return False
    return True

def encode_state(g):
    """134 维：16格×8特征 + 6全局（与人类视野一致）
    每格：v/9, isMe, isEnemy, bridge, onBridge, auto,
         pressedV/9（滚木脚下压着的单位值）, hasPressed（有无按压）
    全局：0(占位), phaseA, phaseP, points/10, produceLeft/8, turnCount/100
    """
    x = []
    for c in g.cells[:MAX_CELLS]:
        x += [c.v / 9.0,
              1.0 if c.o == 0 else 0.0, 1.0 if c.o == 1 else 0.0,
              1.0 if c.bridge else 0.0, 1.0 if c.onBridge else 0.0, 1.0 if c.auto else 0.0,
              (c.pressedV or 0) / 9.0,
              1.0 if c.pressedV is not None else 0.0]
    while len(x) < MAX_CELLS * 8:
        x += [0.0] * 8
    x += [float(g.turn), 1.0 if g.phase == 'action' else 0.0,
          1.0 if g.phase == 'produce' else 0.0,
          g.points / 10.0, g.produce_left / 8.0,
          getattr(g, 'turn_count', 0) / 100.0]
    return np.array(x, dtype=np.float64)

def build_samples(games, side=None):
    """返回 (X, Y_onehot, ok_count, skip_reasons)
    side=None：全部样本；side=0：只取左方（owner==0）步；side=1：只取右方（owner==1）步。
    游戏状态照常逐局重建推进（保持局内连续性），只产出指定侧的样本——
    双人局的左右数据据此分流（左右 AI 各自独立训练）。"""
    X, Y = [], []
    ok = 0
    no_legal = 0
    not_found = 0
    for game in games:
        for step in game.get('steps', []):
            owner = int(step.get('owner', 0))
            if side is not None and owner != side:
                continue
            action = step.get('action')
            if not action:
                continue
            g = rebuild(step, game.get('limit'))
            # 阶段选择也交给网络（2026-08-28 牢大：阶段选择不该用启发式）：
            # UI 直接发操作（不显式 emit choosePhase），操作前 phase 为 null——
            # 保留 phase=null 输入（two-hot 全 0），候选 = 行动类 + 造兵类并集，
            # 人类发的动作类型本身就隐含了阶段选择（move=行动阶段，produce=造兵阶段）。
            if step.get('phase') is None:
                t = action.get('type')
                if t not in ('move', 'attack', 'devour', 'split', 'produce'):
                    continue
                # 行动类候选：临时切 action 阶段 + 重算行动点（枚举完还原）
                g.phase = 'action'
                g.points = g.count_of(owner, 9) + 1
                playable = [a for a in g.get_legal_actions(owner) if a['type'] != 'endTurn']
                # 造兵类候选：临时切 produce 阶段 + 重算造兵次数
                g.phase = 'produce'
                g.produce_left = g.count_of(owner, 8)
                for a in g.get_legal_actions(owner):
                    if a['type'] == 'produce' and a not in playable:
                        playable.append(a)
                # 还原 phase=null（编码 two-hot 全 0；points/produceLeft 还原记录值 0）
                g.phase = None
                g.points = int(step.get('points', 0))
                g.produce_left = int(step.get('produceLeft', 0))
            else:
                acts = g.get_legal_actions(owner)
                # 排除 endTurn（结束回合由游戏流程自动处理，不训练）
                playable = [a for a in acts if a['type'] != 'endTurn']
            if not playable:
                no_legal += 1
                continue
            # 视角归一化：人类（owner）恒为左方（玩家0）；人类在右则镜像棋盘
            flip = normalize_view(g, owner)
            slot = None
            for a in playable:
                if core_eq(a, action):
                    slot = action_slot(a, flip, g)
                    break
            if slot is None:
                not_found += 1
                continue
            X.append(encode_state(g))
            y = np.zeros(OUT_SLOTS, dtype=np.float64)
            y[slot] = 1.0
            Y.append(y)
            ok += 1
    if not X:
        return None, 0, {'no_legal': no_legal, 'not_found': not_found}
    return np.array(X), np.array(Y), {'ok': ok, 'no_legal': no_legal, 'not_found': not_found}

# ── numpy MLP + Adam ──
def xavier(fan_in, fan_out, rng):
    return rng.uniform(-1, 1, (fan_in, fan_out)) * np.sqrt(6.0 / (fan_in + fan_out))

def train_mlp(X, Y, epochs=80, lr=0.001, batch=64, seed=42, init=None):
    rng = np.random.default_rng(seed)
    N = X.shape[0]
    if init:
        # warm start：从现有权重（可能含 RL 成果）继续训练，不从头学
        W1 = init['w1'].copy(); b1 = init['b1'].copy()
        W2 = init['w2'].copy(); b2 = init['b2'].copy()
        Wo = init['wo'].copy(); bo = init['bo'].copy()
    else:
        W1 = xavier(IN_DIM, HIDDEN, rng)
        b1 = np.zeros(HIDDEN)
        W2 = xavier(HIDDEN, HIDDEN, rng)
        b2 = np.zeros(HIDDEN)
        Wo = xavier(HIDDEN, OUT_SLOTS, rng)
        bo = np.zeros(OUT_SLOTS)
    # Adam 状态
    m = [np.zeros_like(W1), np.zeros_like(b1), np.zeros_like(W2), np.zeros_like(b2), np.zeros_like(Wo), np.zeros_like(bo)]
    v = [np.zeros_like(x) for x in m]
    t_step = 0
    for ep in range(epochs):
        idx = rng.permutation(N)
        total_loss, total_correct, n_batch = 0.0, 0, 0
        for s in range(0, N, batch):
            bidx = idx[s:s + batch]
            xb = X[bidx]
            yb = Y[bidx]
            # 前向
            h1 = np.maximum(0, xb @ W1 + b1)
            h2 = np.maximum(0, h1 @ W2 + b2)
            logits = h2 @ Wo + bo
            # softmax + 交叉熵（数值稳定）
            lmax = logits.max(axis=1, keepdims=True)
            e = np.exp(logits - lmax)
            probs = e / e.sum(axis=1, keepdims=True)
            loss = -np.mean(np.sum(yb * np.log(probs + 1e-12), axis=1))
            total_loss += loss * len(bidx)
            correct = int((probs.argmax(axis=1) == yb.argmax(axis=1)).sum())
            total_correct += correct
            n_batch += 1
            # 反向
            dlogits = probs - yb
            dWo = h2.T @ dlogits
            dbo = dlogits.sum(axis=0)
            dh2 = dlogits @ Wo.T
            dh2[h2 <= 0] = 0
            dW2 = h1.T @ dh2
            db2 = dh2.sum(axis=0)
            dh1 = dh2 @ W2.T
            dh1[h1 <= 0] = 0
            dW1 = xb.T @ dh1
            db1 = dh1.sum(axis=0)
            grads = [dW1, db1, dW2, db2, dWo, dbo]
            params = [W1, b1, W2, b2, Wo, bo]
            t_step += 1
            for i in range(len(params)):
                m[i] = 0.9 * m[i] + 0.1 * grads[i]
                v[i] = 0.999 * v[i] + 0.001 * grads[i] * grads[i]
                mhat = m[i] / (1 - 0.9 ** t_step)
                vhat = v[i] / (1 - 0.999 ** t_step)
                params[i] -= lr * mhat / (np.sqrt(vhat) + 1e-8)
        acc = total_correct / N
        if ep % 10 == 0 or ep == epochs - 1:
            print(f'epoch {ep + 1}/{epochs}  loss {total_loss / N:.4f}  acc {acc:.3f}')
    return {'w1': W1, 'b1': b1, 'w2': W2, 'b2': b2, 'wo': Wo, 'bo': bo}

def flat(w):
    return [float(x) for x in w.flatten()]

def save_weights(params, out_path):
    version = 1
    if os.path.exists(out_path):
        try:
            old = json.load(open(out_path, 'r', encoding='utf-8'))
            version = int(old.get('version', 0)) + 1
        except Exception:
            pass
    # hidden 用实际权重维度（warm start 64 单元时是 64，不能写死 HIDDEN=128——
    # 否则加载端按 hidden 字段 reshape 会崩，游戏端 AI 直接失效）
    hidden = int(params['b1'].shape[0])
    # 关键：文件按「加载端语义」保存——推理端（eval_ai/train_ai.dart）按
    # (hidden,in) 行主序索引 w1[i*hidden... ] 不对，是 w1[i*in + k]（i=hidden 行）：
    # 即期望 flat = W1.T 的行主序。train_mlp 内部是 W1=(in,hidden)，
    # 保存时必须转置（w2 方形转置后行主序不同，wo 同理），否则部署的模型
    # 是训练模型的固定重排，行为完全不可控（曾导致 AI 行为怪异）。
    data = {
        'version': version,
        'updatedAt': time.strftime('%Y-%m-%d %H:%M:%S'),
        'in': IN_DIM, 'hidden': hidden, 'out': OUT_SLOTS,
        'w1': flat(params['w1'].T), 'b1': flat(params['b1']),
        'w2': flat(params['w2'].T), 'b2': flat(params['b2']),
        'wo': flat(params['wo'].T), 'bo': flat(params['bo']),
    }
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(data, f)
    return version

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--epochs', type=int, default=80)
    ap.add_argument('--lr', type=float, default=0.001)
    ap.add_argument('--fresh', action='store_true', help='从零训练（不 warm start）——洗掉旧标注学到的错误行为')
    ap.add_argument('--extra-data', default='',
                    help='附加训练数据文件（jsonl，如规则 AI 合成对局），与人类数据合并训练')
    ap.add_argument('--deploy', action='store_true', help='训练完写权重到下载目录（客户端拉取生效）')
    ap.add_argument('--force', action='store_true', help='样本不足 150 也强制训练部署（手动验证用）')
    ap.add_argument('--side', default=None, choices=[None, 'left', 'right'],
                    help='只训练指定侧（left=左方 owner0 / right=右方 owner1），None=全部样本')
    args = ap.parse_args()
    side_id = {'left': 0, 'right': 1}.get(args.side)
    WEIGHTS_FILE = WEIGHTS_LEFT if args.side == 'left' else WEIGHTS_RIGHT if args.side == 'right' else None

    games = load_games(DATA_FILE)
    if args.extra_data:
        extra = load_games(args.extra_data)
        print(f'附加数据: {args.extra_data} → {len(extra)} 局')
        games = games + extra
    print(f'对局数: {len(games)}' + (f'（训练侧: {args.side}）' if args.side else ''))
    if not games:
        print('没有训练数据，先去训练场打几局（http://192.140.166.178:5000/train/）')
        return
    X, Y, stats = build_samples(games, side=side_id)
    if X is None:
        print(f'无有效样本（{stats}）')
        return
    print(f'样本数: {len(X)}  （{stats}）')
    # 样本太少不部署：避免几局就触发训练导致权重反复横跳（305 槽大网络需要足量样本）
    # 手动训练可用 --force 绕过
    if len(X) < 150 and not args.force:
        print(f'有效样本仅 {len(X)} < 150，暂不部署（保留现有权重）；继续攒局，凑够再训')
        return
    print('开始训练 MLP ...')
    t0 = time.time()
    # warm start：从现有权重继续（RL 部署后不会被从零训练覆盖，平滑演进）
    # --fresh 时跳过：修复标注后旧权重残留错误行为，需从头洗掉
    init = None
    if WEIGHTS_FILE and not args.fresh and os.path.exists(WEIGHTS_FILE):
        try:
            w = json.load(open(WEIGHTS_FILE, encoding='utf-8'))
            if w.get('out') == OUT_SLOTS and w.get('in') == IN_DIM:
                old_hidden = int(w.get('hidden', HIDDEN))
                # 文件是 (hidden,in) 行主序（加载端语义），train_mlp 内部要 (in,hidden) → 转置还原
                init = {
                    'w1': np.array(w['w1'], dtype=np.float64).reshape(old_hidden, IN_DIM).T,
                    'b1': np.array(w['b1'], dtype=np.float64),
                    'w2': np.array(w['w2'], dtype=np.float64).reshape(old_hidden, old_hidden).T,
                    'b2': np.array(w['b2'], dtype=np.float64),
                    'wo': np.array(w['wo'], dtype=np.float64).reshape(OUT_SLOTS, old_hidden).T,
                    'bo': np.array(w['bo'], dtype=np.float64),
                }
                print(f'warm start：基于现有权重继续训练（hidden={old_hidden}）')
        except Exception:
            pass
    params = train_mlp(X, Y, epochs=args.epochs, lr=args.lr, init=init)
    print(f'训练耗时 {time.time() - t0:.1f}s')
    if args.deploy:
        if WEIGHTS_FILE is None:
            print('未指定 --side（left/right），跳过部署（预览权重仍会保存）')
        else:
            v = save_weights(params, WEIGHTS_FILE)
            print(f'已部署权重 v{v} → {WEIGHTS_FILE}')
            print('训练场/游戏客户端下次拉取即生效（无需重启服务器）')
    else:
        v = save_weights(params, '/root/aim/covers/train_weights_preview.json')
        print(f'预览权重已存 /root/aim/covers/train_weights_preview.json（v{v}）')
        print('加 --deploy 部署到游戏')

if __name__ == '__main__':
    main()
