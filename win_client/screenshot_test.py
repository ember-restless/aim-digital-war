# UI 截图测试：无头模式渲染菜单和对局画面
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
    def create_room(self, n): pass
    def join_room(self, r, n): pass
    def list_rooms(self): pass

client = FakeClient()

# 菜单画面
menu = MenuView(screen, pack, client, packs)
menu.on_event('connect', None)
menu.on_event('room_update', {'id': 'A1000', 'players': [{'name': '离离'}, {'name': '牢大'}]})
menu.draw(0.016)
pygame.image.save(screen, '/root/.openclaw/workspace/aim_menu.png')

# 对局画面：模拟一个进行中的 game_state
game = GameView(screen, pack, client)
state = {
    'cells': [
        {'v': 8, 'o': 0}, {'v': 1, 'o': 0}, {'v': 0, 'o': None}, {'v': 0, 'o': None},
        {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 8, 'o': 1},
    ],
    'mapLen': 8, 'limit': 16,
    'turn': 0, 'phase': None, 'points': 1, 'produceLeft': 1,
    'winner': None, 'yourIdx': 0,
    'mySum': 9, 'enemySum': 8, 'myBases': 1, 'myHqs': 0,
    'legalActions': [
        {'type': 'choosePhase', 'phase': 'action'},
        {'type': 'choosePhase', 'phase': 'produce'},
    ],
    'log': ['欢迎来到 AIM！'],
}
game.on_state(state)
game.draw(0.016)
pygame.image.save(screen, '/root/.openclaw/workspace/aim_game1.png')

# 造兵阶段 + 溢出插桥后的复杂局面
state2 = {
    'cells': [
        {'v': 8, 'o': 0}, {'v': 2, 'o': 0}, {'bridge': True}, {'v': 1, 'o': 0, 'onBridge': True},
        {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 5, 'o': 1}, {'v': 8, 'o': 1},
    ],
    'mapLen': 8, 'limit': 16,
    'turn': 0, 'phase': 'action', 'points': 2, 'produceLeft': 0,
    'winner': None, 'yourIdx': 0,
    'mySum': 12, 'enemySum': 13, 'myBases': 1, 'myHqs': 0,
    'legalActions': [
        {'type': 'move', 'i': 1, 'steps': 2},
        {'type': 'move', 'i': 1, 'steps': 1},
        {'type': 'attack', 'i': 1, 'j': 6},
        {'type': 'split', 'i': 1, 'a': 1, 'b': 1, 'front': 'a'},
        {'type': 'endTurn'},
    ],
    'log': ['滚木碾过：5受6伤', '敌方数字和13'],
}
game.on_state(state2)
game.sel_unit = 1
game.draw(0.016)
pygame.image.save(screen, '/root/.openclaw/workspace/aim_game2.png')

# 胜利画面
state3 = dict(state2)
state3['winner'] = 0
game.on_state(state3)
game.on_over({'winner': 0, 'winnerName': '离离'})
game.draw(0.016)
pygame.image.save(screen, '/root/.openclaw/workspace/aim_win.png')

print('截图完成')
