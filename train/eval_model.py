#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
模型实力评估（监视台用）—— 新模型训练部署后自动跑
- 评估不再 vs easy/normal/hard（牢大定：规则 AI 没参考价值，不当指标）
- 指标 = 纯各项测试（能力考试）+ 双方对决成功率（左右互搏）
- 左右互搏 N 局：左策略执左 vs 右策略执右，统计互搏胜率 + 对局运营统计
- 输出 /root/aim/train_data/eval_result.json：
  { ts, modelVersion, duel: {games,leftWins,rightWins,leftRate,rightRate},
    gameStats, bench, benchR, score, scoreL, scoreR, summaryL, summaryR }
用法：python3 eval_model.py [--duel 12]
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

WEIGHTS_LEFT = '/root/aim/server/public/downloads/train_weights_left.json'
WEIGHTS_RIGHT = '/root/aim/server/public/downloads/train_weights_right.json'
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


# ── 综合评分（0-100，牢大定指标）：互搏 40 + 能力 40 + 运营 20 ──
# vs easy/normal/hard 胜率不再参与评分（规则 AI 没参考价值）。
def compute_score(duel_rate, bench, gs):
    def add(key, name, score, mx, basis, std):
        items.append({'key': key, 'name': name, 'score': round(score, 1), 'max': mx,
                      'basis': basis, 'std': std})

    items = []
    # 双方对决成功率（40）——左右各自互搏胜率
    add('duel', '对决·互搏', duel_rate * 40, 40,
        f'互搏胜率 {duel_rate:.0%}', '互搏胜率 × 40 分（双方对决成功率，规则 AI 不算数）')
    # 能力（40，5 类每类 8）—— 纯各项测试（单侧考试）
    for cat, key in (('进攻', 'atk'), ('防守', 'def'), ('经济', 'eco'), ('战术', 'tac'), ('自律', 'self')):
        c = bench['byCat'].get(cat, {'score': 0, 'total': 0})
        rate = c.get('score', 0) / c.get('total', 1) if c.get('total') else 0
        add(key, f'能力·{cat}', rate * 8, 8,
            f'{c.get("score", 0)}/{c.get("total", 0)} 题通过', '单侧考试通过率 × 8 分')
    # 运营（20）—— 来自互搏对局统计
    kd = gs['avgKills'] / gs['avgLosses'] if gs['avgLosses'] else 9.9
    add('eco', '运营·造兵效率', min(5, 1 + gs['avgProduce'] * 2), 5,
        f'平均造兵 {gs["avgProduce"]}', '≥2 满分 5；每少 0.5 扣 1')
    add('kd', '运营·攻守效率', min(5, 1 + kd * 2.5), 5,
        f'击杀/损失 = {gs["avgKills"]}/{gs["avgLosses"]} = {kd:.2f}', 'K/D≥1.6 满分；≥1 得 3.5；≥0.5 得 2')
    add('dev', '运营·发展上限', min(5, 1 + max(0, gs['maxDigit'] - 5)), 5,
        f'单局最高数字 {gs["maxDigit"]}', '达到 9 满分 5；8 得 4；7 得 3；6 得 2')
    wt = gs.get('avgWinTurns', 0)
    add('spd', '运营·速战速决', max(0, 5 - max(0, wt - 25) / 25), 5,
        f'获胜局平均回合 {wt}', '≤25 回合满分 5；每多 25 回合扣 1 分')

    total = round(sum(i['score'] for i in items), 1)
    grade = 'S' if total >= 90 else 'A' if total >= 75 else 'B' if total >= 60 else 'C' if total >= 45 else 'D'
    return {'total': total, 'max': 100, 'grade': grade, 'items': items}


def run_eval(left_weights, right_weights=None, duel_games=16, out_path=None):
    """完整评估（互搏对局 + 能力考试 + 综合评分），返回 data dict；out_path 非空则落盘。
    左右双权重：左策略执左（owner0）、右策略执右（owner1）互搏；
    right_weights=None 时回退用 left（兼容单权重调用）。"""
    if not os.path.exists(left_weights):
        return None
    if right_weights is None:
        right_weights = left_weights
    model_ver = 0
    try:
        model_ver = int(json.load(open(left_weights, encoding='utf-8')).get('version', 0))
    except Exception:
        pass

    def new_agg():
        return {'kills': 0, 'losses': 0, 'produce': 0, 'maxDigit': 0, 'turns': 0, 'n': 0,
                'winTurns': 0, 'winN': 0}

    # ── 左右互搏：左策略执左 vs 右策略执右（双方对决成功率）──
    # sample=True 采样模式（与训练采样口径一致）；temp 从各自权重恢复（左右独立噪点）。
    # 局数足够多（16）让成功率有统计意义；seed 变化保证每次评估有独立抽样。
    agg_l, agg_r = new_agg(), new_agg()
    left_wins = right_wins = 0
    for i in range(duel_games):
        ml = ModelAi(left_weights, seed=i * 7, sample=True)
        mr = ModelAi(right_weights, seed=i * 13, sample=True)
        w, tc, st, md = play(ml, mr, seed=i + 31)
        if w == 0:
            left_wins += 1
        elif w == 1:
            right_wins += 1
        for (ax, own) in ((agg_l, 0), (agg_r, 1)):
            for k in ('kills', 'losses', 'produce'):
                ax[k] += st[k][own]
            ax['maxDigit'] = max(ax['maxDigit'], md)
            ax['turns'] += tc
            ax['n'] += 1
            if w == own:
                ax['winTurns'] += tc
                ax['winN'] += 1
    duel = {
        'games': duel_games,
        'leftWins': left_wins, 'rightWins': right_wins,
        'leftRate': round(left_wins / duel_games, 2),
        'rightRate': round(right_wins / duel_games, 2),
    }

    def mk_gs(ax):
        return {
            'avgKills': round(ax['kills'] / ax['n'], 1) if ax['n'] else 0,
            'avgLosses': round(ax['losses'] / ax['n'], 1) if ax['n'] else 0,
            'avgProduce': round(ax['produce'] / ax['n'], 1) if ax['n'] else 0,
            'avgTurns': round(ax['turns'] / ax['n'], 1) if ax['n'] else 0,
            'avgWinTurns': round(ax['winTurns'] / ax['winN'], 1) if ax['winN'] else 0,
            'maxDigit': ax['maxDigit'],
        }

    gs_l, gs_r = mk_gs(agg_l), mk_gs(agg_r)
    bench = run_bench(left_weights)
    benchR = run_bench(right_weights, side=1)

    data = {
        'ts': time.strftime('%Y-%m-%d %H:%M:%S'),
        'modelVersion': model_ver,
        'duel': duel,
        'gameStats': {
            'avgKills': round((gs_l['avgKills'] + gs_r['avgKills']) / 2, 1),
            'avgLosses': round((gs_l['avgLosses'] + gs_r['avgLosses']) / 2, 1),
            'avgProduce': round((gs_l['avgProduce'] + gs_r['avgProduce']) / 2, 1),
            'avgTurns': round((gs_l['avgTurns'] + gs_r['avgTurns']) / 2, 1),
            'avgWinTurns': round((gs_l['avgWinTurns'] + gs_r['avgWinTurns']) / 2, 1) if (gs_l['avgWinTurns'] or gs_r['avgWinTurns']) else 0,
            'maxDigit': max(gs_l['maxDigit'], gs_r['maxDigit']),
        },
        'bench': bench,
        'benchR': benchR,
    }
    data['scoreL'] = compute_score(duel['leftRate'], bench, gs_l)
    data['scoreR'] = compute_score(duel['rightRate'], benchR, gs_r)
    avg_total = round((data['scoreL']['total'] + data['scoreR']['total']) / 2, 1)
    data['score'] = {'total': avg_total,
                     'max': 100,
                     'grade': 'S' if avg_total >= 90 else 'A' if avg_total >= 75 else 'B' if avg_total >= 60 else 'C' if avg_total >= 45 else 'D',
                     'items': data['scoreL']['items']}
    data['summaryL'] = {'duelRate': duel['leftRate'], 'overall': duel['leftRate'],
                        'wins': left_wins, 'games': duel_games, **gs_l}
    data['summaryR'] = {'duelRate': duel['rightRate'], 'overall': duel['rightRate'],
                        'wins': right_wins, 'games': duel_games, **gs_r}
    data['summary'] = {'overall': round((duel['leftRate'] + duel['rightRate']) / 2, 2),
                       'asLeft': duel['leftRate'], 'asRight': duel['rightRate']}
    if out_path:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
    b, br = bench, benchR
    print(f'评估完成 互搏 左{duel["leftRate"]:.0%}/右{duel["rightRate"]:.0%} 考试 左{b["passRate"]:.0%}/右{br["passRate"]:.0%} '
          f'综合分 左{data["scoreL"]["total"]}（{data["scoreL"]["grade"]}）/右{data["scoreR"]["total"]}（{data["scoreR"]["grade"]}）', flush=True)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--duel', type=int, default=16,
                    help='左右互搏局数（默认 16，双方对决成功率统计用；采样模式）')
    ap.add_argument('--games', default=None,
                    help='兼容旧参数（规则 AI 局已不作为指标，忽略）')
    args = ap.parse_args()
    run_eval(WEIGHTS_LEFT, WEIGHTS_RIGHT, args.duel, OUT)


if __name__ == '__main__':
    main()
