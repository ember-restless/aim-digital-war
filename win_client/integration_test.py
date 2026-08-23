# Win 端集成测试：两个客户端建房对战，跑完若干回合
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from client import AIMClient

events0, events1 = [], []
c0 = AIMClient(lambda e, d: events0.append((e, d)))
c1 = AIMClient(lambda e, d: events1.append((e, d)))

assert c0.connect('http://127.0.0.1:5000') is True, 'c0 连接失败'
time.sleep(0.3)
c0.create_room('离离')
time.sleep(0.3)

# 找房间
c1.connect('http://127.0.0.1:5000')
time.sleep(0.3)
c1.list_rooms()
time.sleep(0.5)
rooms = [d for e, d in events1 if e == 'room_list']
print('房间列表:', rooms)
if rooms and rooms[0]:
    rid = rooms[0][0]['id']
    c1.join_room(rid, '牢大')
    time.sleep(0.5)
    c0.start_game(16)
    time.sleep(0.5)

# 自动对弈
turns = 0
MAX = 30
while turns < MAX:
    time.sleep(0.3)
    st0 = [d for e, d in events0 if e == 'game_state']
    st1 = [d for e, d in events1 if e == 'game_state']
    if not st0 or not st1:
        continue
    s0, s1 = st0[-1], st1[-1]
    if s0.get('winner') is not None:
        print('=== 游戏结束，胜者:', s0['winner'])
        break
    # 当前回合方行动
    if s0['turn'] == 0 and s0['legalActions']:
        acts = s0['legalActions']
        # 简单策略：选阶段→造兵→结束
        a = None
        if s0['phase'] is None:
            a = {'type': 'choosePhase', 'phase': 'produce'}
        elif s0['phase'] == 'produce':
            a = next((x for x in acts if x['type'] == 'produce'), {'type': 'endTurn'})
        else:
            a = {'type': 'endTurn'}
        c0.action(a)
        turns += 1
    elif s1['turn'] == 1 and s1['legalActions']:
        acts = s1['legalActions']
        a = None
        if s1['phase'] is None:
            a = {'type': 'choosePhase', 'phase': 'produce'}
        elif s1['phase'] == 'produce':
            a = next((x for x in acts if x['type'] == 'produce'), {'type': 'endTurn'})
        else:
            a = {'type': 'endTurn'}
        c1.action(a)
        turns += 1

if st0:
    s = st0[-1]
    print('最终状态: cells=', [f"{'[' if c.get('o')==0 else '{' if c.get('o')==1 else ' '}{'-' if c.get('bridge') else c.get('v')}{']' if c.get('o')==0 else '}' if c.get('o')==1 else ' '}" for c in s['cells']])
    print(f"回合数: {turns}, 胜者: {s.get('winner')}")
print('集成测试完成')
