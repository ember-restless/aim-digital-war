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


# ── 综合评分（0-100）：对战 40 + 能力 40 + 运营 20，每项带得分依据与判定标准 ──
def compute_score(summary, bench, gs, results):
    def wr(opp):
        rr = [r for r in results if r['opponent'] == opp]
        return sum(r['wins'] for r in rr) / sum(r['games'] for r in rr) if rr and sum(r['games'] for r in rr) else 0

    items = []

    def add(key, name, score, mx, basis, std):
        items.append({'key': key, 'name': name, 'score': round(score, 1), 'max': mx,
                      'basis': basis, 'std': std})

    # 对战（40）
    for opp, wt, cut in (('easy', 8, 1.5), ('normal', 12, 2), ('hard', 20, 4)):
        r = wr(opp)
        s = max(0, wt - max(0, (1 - r)) * 10 * cut)
        add('vs' + opp.capitalize(), f'对战·{opp}', s, wt,
            f'胜率 {r:.0%}', f'100% 胜率满分 {wt} 分；每降 10% 扣 {cut} 分')
    # 能力（40，5 类每类 8）
    for cat, key in (('进攻', 'atk'), ('防守', 'def'), ('经济', 'eco'), ('战术', 'tac'), ('自律', 'self')):
        c = bench['byCat'].get(cat, {'score': 0, 'total': 0})
        rate = c['score'] / c['total'] if c['total'] else 0
        add(key, f'能力·{cat}', rate * 8, 8,
            f'{c["score"]}/{c["total"]} 题通过', '通过率 × 8 分')
    # 运营（20）
    kd = gs['avgKills'] / gs['avgLosses'] if gs['avgLosses'] else 9.9
    add('eco', '运营·造兵效率', min(5, 1 + gs['avgProduce'] * 2), 5,
        f'平均造兵 {gs["avgProduce"]}', '≥2 满分 5；每少 0.5 扣 1')
    add('kd', '运营·攻守效率', min(5, 1 + kd * 2.5), 5,
        f'击杀/损失 = {gs["avgKills"]}/{gs["avgLosses"]} = {kd:.2f}', 'K/D≥1.6 满分；≥1 得 3.5；≥0.5 得 2')
    add('dev', '运营·发展上限', min(5, 1 + max(0, gs['maxDigit'] - 5)), 5,
        f'单局最高数字 {gs["maxDigit"]}', '达到 9 满分 5；8 得 4；7 得 3；6 得 2')
    add('dur', '运营·持久能力', min(5, 1 + gs['avgTurns'] / 8), 5,
        f'平均回合 {gs["avgTurns"]}', '≥35 回合满分 5；每少 7 扣 1')

    total = round(sum(i['score'] for i in items), 1)
    grade = 'S' if total >= 90 else 'A' if total >= 75 else 'B' if total >= 60 else 'C' if total >= 45 else 'D'
    return {'total': total, 'max': 100, 'grade': grade, 'items': items}


def run_eval(weights_path, games_spec='easy=3,normal=3,hard=5', out_path=None):
    """完整评估（对局 + 能力考试 + 综合评分），返回 data dict；out_path 非空则落盘"""
    if not os.path.exists(weights_path):
        return None
    model_ver = 0
    try:
        model_ver = int(json.load(open(weights_path, encoding='utf-8')).get('version', 0))
    except Exception:
        pass
    plan = []
    for kv in games_spec.split(','):
        name, n = kv.split('=')
        plan.append((name, int(n)))

    results = []
    agg = {'kills': 0, 'losses': 0, 'produce': 0, 'maxDigit': 0, 'turns': 0, 'n': 0}
    for opp, n in plan:
        for side in (0, 1):
            wins = 0
            turns = []
            for i in range(n):
                m = ModelAi(weights_path, seed=i * 7 + side * 101)
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
        'gameStats': {
            'avgKills': round(agg['kills'] / agg['n'], 1) if agg['n'] else 0,
            'avgLosses': round(agg['losses'] / agg['n'], 1) if agg['n'] else 0,
            'avgProduce': round(agg['produce'] / agg['n'], 1) if agg['n'] else 0,
            'avgTurns': round(agg['turns'] / agg['n'], 1) if agg['n'] else 0,
            'maxDigit': agg['maxDigit'],
        },
        'bench': run_bench(weights_path),
        'score': None,
    }
    data['score'] = compute_score(summary, data['bench'], data['gameStats'], results)
    if out_path:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
    b = data['bench']
    print(f'评估完成 总体胜率 {summary["overall"]:.0%} 能力考试 {b["passRate"]:.0%} 综合分 {data["score"]["total"]}（{data["score"]["grade"]}）')
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--games', default='easy=3,normal=3,hard=5',
                    help='各对手每侧局数，如 easy=3,normal=3,hard=5')
    args = ap.parse_args()
    run_eval(WEIGHTS, args.games, OUT)


if __name__ == '__main__':
    main()
