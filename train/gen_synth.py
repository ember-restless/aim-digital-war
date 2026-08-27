#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
合成数据生成器：规则 AI 自博弈 → 行为克隆训练数据（与人类对局 games.jsonl 同格式）。
用途：模型底子弱（98 局人类数据 + 64 单元），用 hard 规则 AI 的「棋谱」补充训练集，
让 BC 先学规则 AI 的水平，再上 RL 才有意义。
用法：python3 gen_synth.py --games 3000 --out /root/aim/train_data/synth_games.jsonl
"""
import json
import os
import random
import sys
import time

sys.path.insert(0, '/root/aim/pc')
sys.path.insert(0, '/root/aim/train')
from rules import AimGame
from ai import AimAi

LEVELS = ('easy', 'normal', 'hard')
PAIRS = (('easy', 'hard'), ('normal', 'hard'), ('hard', 'hard'))  # 难度配对：弱方学强方？不——都记录，混合学习


def cell_enc(c):
    return [c.v, c.o if c.o is not None else -1,
            1 if c.bridge else 0, 1 if c.onBridge else 0, 1 if c.auto else 0]


def play_one(ai0, ai1, seed):
    g = AimGame(limit=16)
    guard = 0
    steps = []
    while g.winner is None and guard < 600:
        guard += 1
        owner = g.turn
        ai = ai0 if owner == 0 else ai1
        a = ai.decide(g)
        if a is None:
            break
        if a['type'] == 'choosePhase':
            # 阶段选择不记录（与人类数据一致：UI 直接发操作，phase=None 由训练端推断）
            r = g.apply_action(owner, a, defer_roll=True)
            if not r['ok']:
                break
            continue
        # 操作前快照（phase 置 None，points/produceLeft 置 0，训练端按动作类型推断并重算）
        step = {
            'cells': [cell_enc(c) for c in g.cells],
            'turn': g.turn,
            'phase': None,
            'points': 0,
            'produceLeft': 0,
            'action': a,
            'owner': owner,
        }
        steps.append(step)
        r = g.apply_action(owner, a, defer_roll=True)
        if not r['ok']:
            acts = g.get_legal_actions(owner)
            if not acts:
                break
            g.apply_action(owner, acts[0], defer_roll=True)
        while g.has_pending_roll:
            if g.roll_step_once(g.turn) is None:
                g.clear_pending_roll()
                break
    return {'v': 1, 'winner': g.winner, 'turns': g.turn_count, 'limit': 16,
            'steps': steps, 'ts': time.strftime('%Y-%m-%dT%H:%M:%S.000Z')}


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--games', type=int, default=3000)
    ap.add_argument('--out', default='/root/aim/train_data/synth_games.jsonl')
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    n_pair = args.games // len(PAIRS)
    total = 0
    with open(args.out, 'w', encoding='utf-8') as f:
        for pi, (l0, l1) in enumerate(PAIRS):
            for i in range(n_pair):
                ai0 = AimAi(l0, seed=i * 31 + pi * 7)
                ai1 = AimAi(l1, seed=i * 17 + pi * 13)
                rec = play_one(ai0, ai1, i + pi * 1000)
                f.write(json.dumps(rec) + '\n')
                total += 1
            print(f'  {l0} vs {l1}: {n_pair} 局完成', flush=True)
    print(f'共生成 {total} 局合成对局 → {args.out}')


if __name__ == '__main__':
    main()
