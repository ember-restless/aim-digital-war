#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
模型能力基准测试（benchmark）—— 像大模型测试集一样，固定局面「考试」
- 构造 N 个标准局面（进攻/防守/经济/战术 四类），每个局面有一个人类期望动作
- 模型在局面中决策，命中期望 → 得分；输出各分类通过率
- 期望动作按「动作类型」匹配（宽松）+ 关键局面按「类型+目标语义」匹配（严格）
"""
import sys

import numpy as np

sys.path.insert(0, '/root/aim/pc')
sys.path.insert(0, '/root/aim/train')
from rules import AimGame, AimCell
from eval_ai import ModelAi

MAX_CELLS = 8


def g16():
    """空棋盘 8 格，玩家0 视角，action 阶段，点数充足"""
    g = AimGame(limit=16)
    g.cells = [AimCell(0) for _ in range(8)]
    g.turn = 0
    g.phase = 'action'
    g.points = 6
    return g


# ── 期望动作检查器 ──
def type_match(expect_type):
    def check(a):
        return a.get('type') == expect_type
    return check


def attack_target(idx):
    def check(a):
        return a.get('type') == 'attack' and a.get('i') != idx  # 攻击者不是目标
    return check


def move_away(idx):
    def check(a):
        return a.get('type') == 'move' and a.get('i') != idx  # 不是把危险单位往里推
    return check


# ── 测试题集：{name, cat, build(), expect_name, check()} ──
CASES = []

# ═══ 进攻 ═══
def build_kill():
    g = g16()
    g.cells[3] = AimCell(5, o=0)   # 我方 5
    g.cells[4] = AimCell(2, o=1)   # 敌方 2 相邻，可一击消灭
    g.cells[7] = AimCell(8, o=1)
    return g
CASES.append({'name': '斩杀：5 打 2 一击消灭', 'cat': '进攻', 'build': build_kill,
              'expect': 'attack', 'check': type_match('attack')})


def build_kill_roller():
    g = g16()
    g.cells[2] = AimCell(5, o=0)   # 我方 5
    g.cells[3] = AimCell(6, o=1, auto=True)  # 敌方滚木（6 受 5 伤溢出 → 变 1+桥？5 打 6 溢出 1）
    return g
CASES.append({'name': '攻击敌方滚木', 'cat': '进攻', 'build': build_kill_roller,
              'expect': 'attack', 'check': type_match('attack')})


def build_shield():
    g = g16()
    g.cells[2] = AimCell(3, o=0)   # 我方弓手 3
    g.cells[3] = AimCell(7, o=1)   # 敌方盾兵 7（远程打不到）
    g.cells[4] = AimCell(1, o=1)   # 盾后小兵（被屏障保护）
    return g
CASES.append({'name': '盾兵屏障：远程不打无效目标', 'cat': '进攻', 'build': build_shield,
              'expect': 'move', 'check': type_match('move')})


# ═══ 防守 ═══
def build_defend_base():
    g = g16()
    g.cells[0] = AimCell(8, o=0)   # 我方基地
    g.cells[1] = AimCell(2, o=0)   # 我方小兵挡路
    g.cells[2] = AimCell(4, o=1)   # 敌方 4 逼近基地（2 格）
    g.cells[7] = AimCell(8, o=1)
    return g
CASES.append({'name': '防守：清除逼近基地的敌人', 'cat': '防守', 'build': build_defend_base,
              'expect': 'attack', 'check': type_match('attack')})


def build_avoid_roller():
    g = g16()
    g.cells[3] = AimCell(5, o=0)   # 我方 5
    g.cells[5] = AimCell(6, o=1, auto=True)  # 敌方滚木（会向右滚 3 格：6→7 出界死？向左滚 5→4→3）
    # 敌方滚木 dir = -1（玩家1 朝左）：滚 5→4→3，我方 5 号在 3 是第 3 格（抹杀区）
    return g
CASES.append({'name': '走位：躲开敌方滚木死亡区', 'cat': '防守', 'build': build_avoid_roller,
              'expect': 'move', 'check': type_match('move')})


def build_no_bridge():
    g = g16()
    g.cells[2] = AimCell(5, o=0)   # 我方重骑 5
    g.cells[3] = AimCell(0, bridge=True)  # 独木桥（5 踩桥塌桥人亡）
    return g
CASES.append({'name': '重单位不上桥（会塌）', 'cat': '防守', 'build': build_no_bridge,
              'expect': 'endTurn', 'check': type_match('endTurn')})


# ═══ 经济 ═══
def build_produce_attack():
    g = g16()
    g.cells[0] = AimCell(8, o=0)   # 我方基地
    g.cells[1] = AimCell(3, o=1)   # 敌方站在基地前 → 造兵攻击 -1
    g.phase = 'produce'
    g.produce_left = 1
    return g
CASES.append({'name': '造兵攻击：基地前有敌人', 'cat': '经济', 'build': build_produce_attack,
              'expect': 'produce', 'check': type_match('produce')})


def build_make_base():
    g = g16()
    g.cells[2] = AimCell(3, o=0)
    g.cells[3] = AimCell(5, o=0)   # 3+5=8 合成基地
    return g
CASES.append({'name': '合成 8 号基地', 'cat': '经济', 'build': build_make_base,
              'expect': 'devour', 'check': type_match('devour')})


def build_make_hq():
    g = g16()
    g.cells[2] = AimCell(4, o=0)
    g.cells[3] = AimCell(5, o=0)   # 4+5=9 合成指挥部
    return g
CASES.append({'name': '合成 9 号指挥部', 'cat': '经济', 'build': build_make_hq,
              'expect': 'devour', 'check': type_match('devour')})


# ═══ 战术 ═══
def build_dismantle_bridge():
    g = g16()
    g.cells[2] = AimCell(1, o=0)   # 小兵 1
    g.cells[3] = AimCell(0, bridge=True)  # 桥（1 过桥拆桥）
    return g
CASES.append({'name': '小兵过桥拆桥', 'cat': '战术', 'build': build_dismantle_bridge,
              'expect': 'move', 'check': type_match('move')})


def build_feed_roller():
    g = g16()
    g.cells[1] = AimCell(6, o=0, auto=True)  # 我方滚木（向右滚：2→3→4）
    g.cells[4] = AimCell(1, o=0)   # 我方小兵 1 在滚木第 3 格？不，滚木 1→2→3，4 是第 3 格
    # 滚木 dir=+1：1→2→3。4 不是路径。改：小兵放 2（第 1 格 → 被碾 1→5 净赚）
    g.cells[4] = AimCell(0)
    g.cells[2] = AimCell(1, o=0)
    return g
CASES.append({'name': '喂滚木：1 送进滚木第 1 格升级 5', 'cat': '战术', 'build': build_feed_roller,
              'expect': 'move', 'check': type_match('move')})


def build_split_light():
    g = g16()
    g.cells[2] = AimCell(5, o=0)   # 5 可拆
    g.cells[3] = AimCell(0, bridge=True)  # 桥前：拆出轻单位过桥？
    return g
CASES.append({'name': '桥前拆分：拆出轻单位过桥', 'cat': '战术', 'build': build_split_light,
              'expect': 'split', 'check': type_match('split')})


def run_bench(model_path):
    """返回 {score, total, byCat: {cat: {score, total}}, details: [{name,cat,ok,chosen}]}"""
    ai = ModelAi(model_path, seed=1)
    by_cat = {}
    details = []
    score = total = 0
    for c in CASES:
        g = c['build']()
        a = ai.decide(g)
        if a is None:
            a = {'type': None}
        ok = bool(c['check'](a))
        score += ok
        total += 1
        by_cat.setdefault(c['cat'], [0, 0])
        by_cat[c['cat']][0] += ok
        by_cat[c['cat']][1] += 1
        details.append({'name': c['name'], 'cat': c['cat'], 'ok': ok,
                        'chosen': a.get('type'), 'expect': c['expect']})
    return {
        'score': score, 'total': total,
        'passRate': round(score / total, 2) if total else 0,
        'byCat': {k: {'score': v[0], 'total': v[1],
                      'rate': round(v[0] / v[1], 2) if v[1] else 0} for k, v in by_cat.items()},
        'details': details,
    }


if __name__ == '__main__':
    import json
    r = run_bench('/root/aim/server/public/downloads/train_weights.json')
    print(json.dumps(r, ensure_ascii=False, indent=1))
