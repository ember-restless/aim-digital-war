# AIM PC 规则引擎对齐测试（与 Dart/JS 双端行为一致）
# 关键场景：吞噬拆分方向、stats、死局判负、滚木喂兵、滚木抹杀、桥、AI 基础
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rules import AimGame, AimCell

PASS = 0
FAIL = 0

def test(name, fn):
    global PASS, FAIL
    try:
        fn()
        PASS += 1
        print(f'  ✓ {name}')
    except AssertionError as e:
        FAIL += 1
        print(f'  ✗ {name}\n    {e}')
    except Exception as e:
        FAIL += 1
        print(f'  ✗ {name} [异常] {type(e).__name__}: {e}')

def eq(a, b, msg=''):
    assert a == b, f'{msg} 期望 {b} 实际 {a}'

def board12():
    return AimGame(limit=12)

def set_cells(g, rows):
    # 只放 rows 列出的格子（不满员，保留插桥/拆分空间）
    g.cells = [AimCell(v, o=o) for (v, o) in rows]
    return g

print('== 吞噬拆分方向 ==')
def t1():
    g = set_cells(board12(), [(8,0),(7,0),(5,0),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.phase='action'; g.points=5
    r = g.apply_action(0, {'type':'devour','i':1,'j':2})
    eq(r['ok'], True)
    eq(g.cells[1].v, 1); eq(g.cells[2].v, 2)
    eq(g.cells[1].o, 0); eq(g.cells[2].o, 0)
test('左方(玩家0) 7吞5=12 → me=1(十位)，目标位=2(个位)', t1)

def t2():
    g = set_cells(board12(), [(8,0),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(5,1),(7,1),(8,1)])
    g.turn=1; g.phase='action'; g.points=5
    r = g.apply_action(1, {'type':'devour','i':10,'j':9})
    eq(r['ok'], True)
    eq(g.cells[9].v, 1); eq(g.cells[10].v, 2)
    eq(g.cells[9].o, 1); eq(g.cells[10].o, 1)
test('右方(玩家1) 7吞5=12 → me=2(个位)，目标位=1(十位)', t2)

def t3():
    g = set_cells(board12(), [(8,0),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(2,1),(8,1),(8,1)])
    g.turn=1; g.phase='action'; g.points=5
    r = g.apply_action(1, {'type':'devour','i':10,'j':9})
    eq(r['ok'], True)
    eq(g.cells[9].v, 1); eq(g.cells[9].o, 1)
    eq(g.cells[10].v, 0); eq(g.cells[10].o, None)
test('右方(玩家1) 8吞2=10 → me 变空，目标位 1', t3)

print('== 基础机制 ==')
def t4():
    g = set_cells(board12(), [(8,0),(2,0),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.phase='action'; g.points=5
    r = g.apply_action(0, {'type':'move','i':1,'steps':1})
    eq(r['ok'], True)
    eq(g.cells[2].v, 2); eq(g.cells[2].o, 0); eq(g.cells[1].v, 0)
test('移动：玩家0 的 2 前进一步', t4)

def t5():
    g = set_cells(board12(), [(8,0),(3,0),(0,None),(1,1),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.phase='action'; g.points=5
    acts = g.get_legal_actions(0)
    eq(any(a['type']=='attack' and a['i']==1 and a['j']==3 for a in acts), True)
    r = g.apply_action(0, {'type':'attack','i':1,'j':3})
    eq(r['ok'], True)
    eq(g.cells[3].v, 0)
test('攻击：3 弓手射程2，隔一格打', t5)

def t6():
    g = set_cells(board12(), [(8,0),(7,0),(2,1),(0,None),(8,1)])
    g.phase='action'; g.points=5
    r = g.apply_action(0, {'type':'attack','i':1,'j':2})
    eq(r['ok'], True)
    eq(g.cells[2].bridge, True)
    eq(g.cells[3].v, 5)
test('溢出插桥：7 打 2 → 2-7=-5 → 桥+5', t6)

def t7():
    g = set_cells(board12(), [(8,0),(3,0),(0,None),(7,1),(2,1),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.phase='action'; g.points=5
    r = g.apply_action(0, {'type':'attack','i':1,'j':3})
    eq(r['ok'], True)
    eq(g.last_action.get('shielded'), True)
    eq(g.cells[3].v, 7)
test('盾兵挡箭：7 挡在目标前面', t7)

def t8():
    g = set_cells(board12(), [(8,0),(2,0),(1,1),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.phase='action'; g.points=5
    r = g.apply_action(0, {'type':'devour','i':1,'j':2})
    eq(r['ok'], True)
    eq(g.cells[1].v, 3)
    eq(len(g.cells), 11)
test('吞噬合成：2 吞 1 = 3', t8)

def t9():
    g = set_cells(board12(), [(8,0),(5,0),(0,None),(8,1)])
    g.phase='action'; g.points=5
    r = g.apply_action(0, {'type':'split','i':1,'keep':2})
    eq(r['ok'], True)
    eq(g.cells[1].v, 2); eq(g.cells[2].v, 3); eq(g.cells[2].o, 0)
test('拆分：5 → 2+3，产物插右侧', t9)

def t10():
    g = set_cells(board12(), [(8,0),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.phase='produce'; g.produce_left=2
    r = g.apply_action(0, {'type':'produce','i':0})
    eq(r['ok'], True)
    eq(g.cells[1].v, 1); eq(g.cells[1].o, 0)
    eq(g.stats['produce'][0], 1)
test('造兵：基地前 0 → 1，produce 统计', t10)

print('== stats 统计 ==')
def t11():
    g = set_cells(board12(), [(8,0),(1,0),(1,1),(0,None),(8,1)])
    g.phase='action'; g.points=5
    g.apply_action(0, {'type':'attack','i':1,'j':2})
    eq(g.stats['kills'][0], 1)
    eq(g.stats['losses'][1], 1)
test('击杀/损失：攻击致死记 kills/losses', t11)

print('== 死局判负 ==')
def t12():
    g = set_cells(board12(), [(6,0),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.cells[0].auto = True
    g.turn = 0
    g.points = 1
    r = g.apply_action(0, {'type':'choosePhase', 'phase':'action'})
    eq(r['ok'], True)
    eq(g.winner, 1, '玩家0无行动应判负给玩家1')
test('只剩锁死滚木：无行动 → 判负', t12)

print('== 滚木机制 ==')
def t13():
    g = set_cells(board12(), [(8,0),(1,0),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(0,None),(8,1)])
    g.cells[10] = AimCell(6, o=1)
    g.turn = 0
    g.end_turn(0)
    eq(g.turn, 1)
    eq(g.cells[7].v, 6, '滚木应滚到 7')
    eq(g.cells[7].o, 1)
test('滚木滚动：玩家1 滚木 10→7 三步', t13)

def t14():
    g = AimGame(limit=12)
    g.cells = [AimCell(8, o=0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
               AimCell(6, o=1), AimCell(1, o=0), AimCell(2, o=0), AimCell(0),
               AimCell(0), AimCell(0), AimCell(8, o=1)]
    g.turn = 0
    g.end_turn(0)
    # 滚木在 5 向左滚：4 空、3 空、2 → 第3格抹杀 2，滚木停在 2
    eq(g.cells[2].v, 6, '滚木应停在 2')
    eq(g.cells[2].o, 1)
    eq(g.cells[2].pressedV, None)
test('滚木抹杀：第3格单位直接死', t14)

print(f'\n结果: {PASS} 通过, {FAIL} 失败')
sys.exit(1 if FAIL else 0)
