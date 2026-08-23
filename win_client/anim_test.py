# 动画效果测试：模拟移动/受击/插桥，截动画中间帧
import os, sys
os.environ['SDL_VIDEODRIVER'] = 'dummy'
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pygame
from art import list_packs, Pack
from game_view import GameView

pygame.init()
screen = pygame.display.set_mode((960, 720))
pack = Pack(list_packs()[0]['dir'])
class FC:
    def __init__(self): self.sio = type('S', (), {'emit': lambda *a, **k: None})()
    def action(self, a): pass
client = FC()
g = GameView(screen, pack, client)

def cells_from(s):
    return [dict(c) for c in s]

# 初始状态
st1 = {'cells': [
    {'v': 8, 'o': 0}, {'v': 2, 'o': 0}, {'v': 0, 'o': None}, {'v': 0, 'o': None},
    {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 5, 'o': 1}, {'v': 8, 'o': 1},
], 'mapLen': 8, 'limit': 16, 'turn': 0, 'phase': 'action', 'points': 1, 'produceLeft': 0,
   'winner': None, 'yourIdx': 0, 'names': ['离离', '牢大'], 'hotseat': False,
   'mySum': 10, 'enemySum': 13, 'myBases': 1, 'myHqs': 0, 'legalActions': [], 'log': []}
g.on_state(st1)

# 新状态：2轻骑从格1走到格3；敌方5受1伤变4（攻击动画）；格2出现桥
st2 = {'cells': [
    {'v': 8, 'o': 0}, {'v': 0, 'o': None}, {'bridge': True}, {'v': 2, 'o': 0},
    {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 4, 'o': 1}, {'v': 8, 'o': 1},
], 'mapLen': 8, 'limit': 16, 'turn': 0, 'phase': 'action', 'points': 1, 'produceLeft': 0,
   'winner': None, 'yourIdx': 0, 'names': ['离离', '牢大'], 'hotseat': False,
   'mySum': 10, 'enemySum': 12, 'myBases': 1, 'myHqs': 0, 'legalActions': [], 'log': []}
g.on_state(st2)
print('动画数:', len(g.anims), '飘字数:', len(g.floats))

# 截动画中间帧（t≈0.15s）
for a in g.anims:
    a['t'] = 0.15
for f in g.floats:
    f['t'] = 0.3
g.draw(0.016)
pygame.image.save(screen, '/root/.openclaw/workspace/aim_shots/anim_mid.png')

# 滚木滚动动画测试
st3 = {'cells': [
    {'v': 8, 'o': 0}, {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 0, 'o': None},
    {'v': 6, 'o': 0, 'auto': True}, {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 8, 'o': 1},
], 'mapLen': 8, 'limit': 16, 'turn': 0, 'phase': 'action', 'points': 0, 'produceLeft': 0,
   'winner': None, 'yourIdx': 0, 'names': ['离离', '牢大'], 'hotseat': False,
   'mySum': 14, 'enemySum': 8, 'myBases': 1, 'myHqs': 0, 'legalActions': [], 'log': []}
g.on_state(st3)
st4 = {'cells': [
    {'v': 8, 'o': 0}, {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 0, 'o': None},
    {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 0, 'o': None}, {'v': 8, 'o': 1},
], 'mapLen': 8, 'limit': 16, 'turn': 1, 'phase': None, 'points': 0, 'produceLeft': 0,
   'winner': None, 'yourIdx': 0, 'names': ['离离', '牢大'], 'hotseat': False,
   'mySum': 8, 'enemySum': 8, 'myBases': 1, 'myHqs': 0, 'legalActions': [], 'log': []}
# 滚木从4滚出地图外（消失）——换个：滚木从4滚到2（移动+旋转）
st4['cells'][2] = {'v': 6, 'o': 0, 'auto': True}
g.on_state(st4)
for a in g.anims:
    a['t'] = 0.12
g.draw(0.016)
pygame.image.save(screen, '/root/.openclaw/workspace/aim_shots/anim_roller.png')
print('滚木动画数:', len(g.anims))
print('截图完成')
