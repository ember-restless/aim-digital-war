# AIM — 数字大战 Win 端入口
import os
import sys

import pygame

from art import ART_DIR, list_packs, Pack
from client import AIMClient, SERVER, check_update, APP_VERSION
from game_view import GameView
from menu_view import MenuView
from ui import COL

W, H = 960, 720
FPS = 60


def _check_update_async(menu):
    import threading

    def run():
        info = check_update()
        if info and info.get('version') != APP_VERSION:
            menu.update_info = info

    threading.Thread(target=run, daemon=True).start()


def main():
    os.environ['SDL_VIDEO_CENTERED'] = '1'
    pygame.init()
    pygame.display.set_caption('AIM 数字大战')
    try:
        icon = pygame.image.load(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icon.png'))
        pygame.display.set_icon(icon)
    except Exception:
        pass
    screen = pygame.display.set_mode((W, H))
    clock = pygame.time.Clock()

    # 资源包
    packs = list_packs()
    pack = Pack(packs[0]['dir']) if packs else None

    client = AIMClient(lambda ev, data: None)
    view_holder = {'cur': None}

    def on_event(ev, data):
        v = view_holder['cur']
        if v:
            v.on_event(ev, data)

    client.on_event = on_event

    menu = MenuView(screen, pack, client, packs)
    game = GameView(screen, pack, client)
    view_holder['cur'] = menu

    # 自动连服务器
    err = client.connect()
    if isinstance(err, str) and err is not True:
        menu.status = '连接失败: ' + str(err)[:40]
    _check_update_async(menu)

    running = True
    while running:
        dt = clock.tick(FPS) / 1000.0
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            else:
                v = view_holder['cur']
                if v:
                    v.handle(event)
                    # 游戏结束返回菜单
                    if hasattr(v, '_back_to_menu') and getattr(v, '_back', False):
                        view_holder['cur'] = menu
                        v._back = False

        v = view_holder['cur']
        if v:
            v.draw(dt)
        pygame.display.flip()

    client.disconnect()
    pygame.quit()
    sys.exit(0)


if __name__ == '__main__':
    main()
