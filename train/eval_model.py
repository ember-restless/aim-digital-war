#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
模型实力评估（监视台用）—— 新模型训练部署后自动跑
- 模型 vs easy/normal/hard 启发式，左右两侧各打若干局
- 输出 /root/aim/train_data/eval_result.json：
  { ts, modelVersion, totalGames, results: [{opponent, side, games, wins, winRate, avgTurns}], summary: {overall, asLeft, asRight, vsEasy, vsNormal, vsHard} }
用法：python3 eval_model.py [--games easy=3,normal=3,hard=5]
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, '/root/aim/pc')
sys.path.insert(0, '/root/aim/train')
from rules import AimGame
from ai import AimAi
from eval_ai import ModelAi
from eval_bench import run_bench

WEIGHTS = '/root/aim/server/public/downloads/train_weights.json'
OUT = '/root/aim/train_data/eval_result.json'


def play(ai0, ai1, seed=0, max_guard=600):
    """完整对局（含滚木逐步驱动），返回 (winner, turn_count, stats, max_digit)"""
    g = AimGame(limit=16)
    guard = 0
    while g.winner is None and guard < max_guard:
        guard += 1
        owner = g.turn
        a = ai0.decide(g) if owner == 0 else ai1.decide(g)
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
        while g.has_pending_roll:
            if g.roll_step_once(g.turn) is None:
                g.clear_pending_roll()
                break
    max_digit = 0
    for c in g.cells:
        if c.v > max_digit:
            max_digit = c.v
    return g.winner, g.turn_count, g.stats, max_digit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--games', default='easy=3,normal=3,hard=5',
                    help='各对手每侧局数，如 easy=3,normal=3,hard=5')
    args = ap.parse_args()
    if not os.path.exists(WEIGHTS):
        print('没有权重文件，跳过评估')
        return
    model_ver = 0
    try:
        model_ver = int(json.load(open(WEIGHTS, encoding='utf-8')).get('version', 0))
    except Exception:
        pass
    plan = []
    for kv in args.games.split(','):
        name, n = kv.split('=')
        plan.append((name, int(n)))

    results = []
    agg = {'kills': 0, 'losses': 0, 'produce': 0, 'maxDigit': 0, 'turns': 0, 'n': 0}
    for opp, n in plan:
        for side in (0, 1):
            wins = 0
            turns = []
            for i in range(n):
                m = ModelAi(WEIGHTS, seed=i * 7 + side * 101)
                o = AimAi(opp, seed=i * 13 + side * 37)
                if side == 0:
                    w, tc, st, md = play(m, o, seed=i)
                else:
                    w, tc, st, md = play(o, m, seed=i)
                if w == side:
                    wins += 1
                turns.append(tc)
                agg['kills'] += st['kills'][side]
                agg['losses'] += st['losses'][side]
                agg['produce'] += st['produce'][side]
                agg['maxDigit'] = max(agg['maxDigit'], md)
                agg['turns'] += tc
                agg['n'] += 1
            results.append({
                'opponent': opp, 'side': side, 'games': n,
                'wins': wins, 'winRate': round(wins / n, 2),
                'avgTurns': round(sum(turns) / len(turns), 1) if turns else 0,
            })
            print(f'vs {opp} side={side}: {wins}/{n} 胜率{wins / n:.0%} 均回合{sum(turns) / len(turns) if turns else 0:.0f}')

    def wr(r): return r['winRate'] if r['games'] else 0
    summary = {
        'overall': round(sum(r['wins'] for r in results) / sum(r['games'] for r in results), 2),
        'asLeft': round(sum(r['wins'] for r in results if r['side'] == 0) /
                        sum(r['games'] for r in results if r['side'] == 0), 2),
        'asRight': round(sum(r['wins'] for r in results if r['side'] == 1) /
                         sum(r['games'] for r in results if r['side'] == 1), 2),
    }
    for opp, n in plan:
        rr = [r for r in results if r['opponent'] == opp]
        summary['vs' + opp.capitalize()] = round(sum(r['wins'] for r in rr) / sum(r['games'] for r in rr), 2)

    data = {
        'ts': time.strftime('%Y-%m-%d %H:%M:%S'),
        'modelVersion': model_ver,
        'totalGames': sum(r['games'] for r in results),
        'results': results,
        'summary': summary,
        # 对局统计（模型表现特征）
        'gameStats': {
            'avgKills': round(agg['kills'] / agg['n'], 1) if agg['n'] else 0,
            'avgLosses': round(agg['losses'] / agg['n'], 1) if agg['n'] else 0,
            'avgProduce': round(agg['produce'] / agg['n'], 1) if agg['n'] else 0,
            'avgTurns': round(agg['turns'] / agg['n'], 1) if agg['n'] else 0,
            'maxDigit': agg['maxDigit'],
        },
        # 能力基准测试（固定局面考试：进攻/防守/经济/战术）
        'bench': run_bench(WEIGHTS),
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    b = data['bench']
    print(f'评估完成 → {OUT}  总体胜率 {summary["overall"]:.0%}（左 {summary["asLeft"]:.0%} / 右 {summary["asRight"]:.0%}）')
    print(f'能力考试 {b["passRate"]:.0%}：' +
          ' '.join(f'{k} {v["rate"]:.0%}' for k, v in b['byCat'].items()))


if __name__ == '__main__':
    main()
