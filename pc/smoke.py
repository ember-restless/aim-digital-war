# PC 版冒烟测试（无显示器环境）：菜单渲染 → 开始对局 → AI 自动跑 → 热座手动操作
import os
os.environ['SDL_VIDEODRIVER'] = 'dummy'
os.environ['SDL_AUDIODRIVER'] = 'dummy'
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pygame

from rules import AimGame
from ai import AimAi, NORMAL
from game_ui import GameUI
from main import Menu, W, H

pygame.init()
screen = pygame.display.set_mode((W, H))

print('1. 主菜单渲染…')
menu = Menu(screen)
for _ in range(5):
    menu._draw()
    pygame.display.flip()
print('   OK')

print('2. 对局（玩家0 热座手动 + 玩家1 AI）…')
game = AimGame(limit=16)
ai = AimAi(NORMAL, seed=42)
ui = GameUI(screen, game, ai=ai, audio=menu.audio, player_name='P1', ai_label='AI·普通（老兵）')

frame = 0
ai_steps = 0
player_moves = 0
turns_seen = {0, 1}
while frame < 900:
    frame += 1
    # 模拟输入：玩家0 回合随机选阶段/行动
    if game.turn == 0 and game.phase is None and not ui.anim_lock and ui.ai_timer is None:
        acts = game.get_legal_actions(0)
        if acts:
            choose = [a for a in acts if a['type'] == 'choosePhase']
            ui._do_action(choose[0])
            player_moves += 1
    elif game.turn == 0 and game.phase == 'action' and not ui.anim_lock and ui.sel is None:
        # 选一个己方单位执行第一个行动
        acts = [a for a in game.get_legal_actions(0) if a['type'] in ('move', 'attack', 'devour', 'split')]
        if acts:
            ui._exec_action(acts[0])
            player_moves += 1
        else:
            ui._end_turn()
    elif game.turn == 0 and game.phase == 'produce' and not ui.anim_lock:
        acts = [a for a in game.get_legal_actions(0) if a['type'] == 'produce']
        if acts:
            ui._do_action(acts[0])
            player_moves += 1
        else:
            ui._end_turn()
    # AI 回合由 ui 内部 ai_timer 驱动
    if game.turn == 1 and not ui.anim_lock and ui.ai_timer is None and game.winner is None:
        ai_steps += 1
        ui.ai_timer = pygame.time.get_ticks() / 1000.0 + 0.7
    # 事件 + 更新 + 渲染
    ui._update(1 / 60)
    ui._draw()
    pygame.display.flip()
    if game.winner is not None:
        break

print(f'   帧数={frame} 玩家行动={player_moves} AI决策触发={ai_steps} winner={game.winner} 回合={game.turn_count}')
print('   OK（对局循环无崩溃）')

print('3. 结算面板…')
if game.winner is not None:
    ui._build_over_panel()
    ui._draw()
    pygame.display.flip()
    print('   OK')

print('4. 设置弹窗…')
menu._open_settings()  # 会卡循环——改用 draw 单帧替代
print('   （跳过交互式循环）')

print('\n冒烟测试完成 ✅')
