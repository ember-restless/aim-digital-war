# 全页面截图：菜单/房间/对局各阶段/热座/胜利
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
import pygame

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from art import list_packs, Pack
from menu_view import MenuView
from game_view import GameView

pygame.init()
screen = pygame.display.set_mode((960, 720))

packs = list_packs()
pack = Pack(packs[0]['dir'])

class FakeClient:
    def __init__(self):
        self.sio = type('S', (), {'emit': lambda *a, **k: None})()
    def action(self, a): pass
    def start_game(self, l): pass
    def create_room(self, n, mode='online'): pass
    def join_room(self, r, n): pass
    def list_rooms(self): pass

client = FakeClient()
OUT = '/root/.openclaw/workspace/aim_shots'
os.makedirs(OUT, exist_ok=True)

def snap(name):
    pygame.image.save(screen, f'{OUT}/{name}.png')
    print('saved', name)

# 1. 主菜单
menu = MenuView(screen, pack, client, packs)
menu.on_event('connect', None)
menu.draw(0.016)
snap('01_menu')

# 2. 房间（在线，两人到齐）
menu = MenuView(screen, pack, client, packs)
menu.on_event('connect', None)
menu.on_event('you_are', {'roomId': 'A1000', 'playerIdx': 0})
menu.on_event('room_update', {'id': 'A1000', 'status': 'waiting', 'mode': 'online',
                              'players': [{'name': '离离'}, {'name': '牢大'}]})
menu.draw(0.016)
snap('02_room')

# 3. 房间（热座）
menu = MenuView(screen, pack, client, packs)
menu.on_event('connect', None)
menu.on_event('you_are', {'roomId': 'A1001', 'playerIdx': 0})
menu.on_event('room_update', {'id': 'A1001', 'status': 'waiting', 'mode': 'hotseat',
                              'players': [{'name': '玩家1'}, {'name': '玩家2'}]})
menu.draw(0.016)
snap('03_room_hotseat')

def mk_state(**kw):
    base = {
        'cells': [
            {'v': 8, 'o': 0}, {'v': 2, 'o': 0}, {'bridge': True}, {'v': 1, 'o': 0, 'onBridge': True},
            {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 5, 'o': 1}, {'v': 8, 'o': 1},
        ],
        'mapLen': 8, 'limit': 16,
        'turn': 0, 'phase': None, 'points': 2, 'produceLeft': 1,
        'winner': None, 'yourIdx': 0,
        'names': ['离离', '牢大'], 'hotseat': False,
        'mySum': 12, 'enemySum': 13, 'myBases': 1, 'myHqs': 0,
        'legalActions': [], 'log': ['欢迎来到 AIM！'],
    }
    base.update(kw)
    return base

# 4. 对局：选阶段
g = GameView(screen, pack, client)
g.on_state(mk_state(legalActions=[{'type': 'choosePhase', 'phase': 'action'},
                                  {'type': 'choosePhase', 'phase': 'produce'}]))
g.draw(0.016)
snap('04_game_phase_choose')

# 5. 对局：行动阶段（选中单位）
g = GameView(screen, pack, client)
g.on_state(mk_state(phase='action', legalActions=[
    {'type': 'move', 'i': 1, 'steps': 2}, {'type': 'move', 'i': 1, 'steps': 1},
    {'type': 'attack', 'i': 1, 'j': 6}, {'type': 'split', 'i': 1, 'a': 1, 'b': 1, 'front': 'a'},
    {'type': 'endTurn'}]))
g.sel_unit = 1
g.draw(0.016)
snap('05_game_action_selected')

# 6. 对局：攻击选目标
g = GameView(screen, pack, client)
g.on_state(mk_state(phase='action', legalActions=[
    {'type': 'move', 'i': 1, 'steps': 2}, {'type': 'attack', 'i': 1, 'j': 6},
    {'type': 'endTurn'}]))
g.sel_unit = 1
g.sel_action = 'attack'
g.draw(0.016)
snap('06_game_attack_target')

# 7. 对局：拆分选项
g = GameView(screen, pack, client)
g.on_state(mk_state(phase='action', legalActions=[
    {'type': 'move', 'i': 1, 'steps': 2}, {'type': 'split', 'i': 1, 'a': 1, 'b': 1, 'front': 'a'},
    {'type': 'endTurn'}]))
g.sel_unit = 1
g.split_options = [{'type': 'split', 'i': 1, 'a': 1, 'b': 1, 'front': 'a'}]
g.draw(0.016)
snap('07_game_split')

# 8. 对局：造兵阶段
g = GameView(screen, pack, client)
g.on_state(mk_state(phase='produce', produceLeft=1, legalActions=[
    {'type': 'produce', 'i': 0, 'j': 1}, {'type': 'endTurn'}]))
g.draw(0.016)
snap('08_game_produce')

# 9. 热座对局（玩家2回合）
g = GameView(screen, pack, client)
g.on_state(mk_state(turn=1, yourIdx=1, names=['玩家1', '玩家2'], hotseat=True,
                    mySum=13, enemySum=12, myBases=1, myHqs=0,
                    cells=[
                        {'v': 8, 'o': 0}, {'v': 5, 'o': 0}, {'v': 0, 'o': None},
                        {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 0, 'o': None},
                        {'v': 1, 'o': 1}, {'v': 8, 'o': 1}],
                    legalActions=[{'type': 'move', 'i': 6, 'steps': 1}]))
g.draw(0.016)
snap('09_hotseat_p2_turn')

# 10. 胜利画面
g = GameView(screen, pack, client)
g.on_state(mk_state(winner=0, legalActions=[]))
g.on_over({'winner': 0, 'winnerName': '离离'})
g.draw(0.016)
snap('10_victory')

print('全部截图完成:', OUT)
