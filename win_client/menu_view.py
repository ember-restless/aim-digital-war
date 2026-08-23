# AIM 主菜单 / 房间界面（数字档案馆风：原创文案 + 数字主题装饰）
import random

import pygame

import settings as S
from ui import COL, Button, draw_text

VERSION = 'v0.2.0'


class MenuView:
    def __init__(self, screen, art, client, packs):
        self.screen = screen
        self.art = art
        self.client = client
        self.packs = packs
        self.pack_idx = 0
        self.name = '玩家'
        self.input_active = False
        self.room = None
        self.room_list = []
        self.limit = 16
        self.status = '连接中…'
        self.buttons = []
        self.connected = False
        self.you = None
        self._cursor_t = 0
        self._bg_cache = None
        self.update_info = None  # 检查更新结果
        self.show_settings = False
        self.rebinding = None    # 正在重绑的键名
        self.keys = S.load()
        self.show_tutorial = False
        self.tutorial_page = 0

    def on_event(self, name, data):
        if name == 'connect':
            self.connected = True
            self.status = '在线'
        elif name == 'disconnect':
            self.connected = False
            self.status = '离线'
        elif name == 'you_are':
            self.you = data
        elif name == 'room_update':
            self.room = data
            self.status = f'房间 {data["id"]}'
        elif name == 'room_list':
            self.room_list = data
        elif name == 'server_error':
            self.status = '⚠ ' + str(data.get('msg', '错误'))

    def handle(self, event):
        for b in self.buttons:
            b.handle(event)
        if self.show_tutorial:
            if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                w = self.screen.get_width()
                if pygame.Rect(w // 2 - 90, 640, 80, 36).collidepoint(event.pos):
                    self.tutorial_page = max(0, self.tutorial_page - 1)
                elif pygame.Rect(w // 2 + 10, 640, 80, 36).collidepoint(event.pos):
                    self.tutorial_page = min(3, self.tutorial_page + 1)
                elif pygame.Rect(w - 130, 14, 100, 30).collidepoint(event.pos):
                    self.show_tutorial = False
            return
        if self.show_settings:
            self._handle_settings(event)
            return
        if event.type == pygame.KEYDOWN and self.input_active:
            if event.key == pygame.K_BACKSPACE:
                self.name = self.name[:-1]
            elif event.key == pygame.K_RETURN:
                self.input_active = False
            else:
                if len(self.name) < 12 and event.unicode.isprintable():
                    self.name += event.unicode
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self._name_rect().collidepoint(event.pos):
                self.input_active = True
            else:
                self.input_active = False
            for r, rect in self._room_rects():
                if rect.collidepoint(event.pos):
                    self.client.join_room(r['id'], self.name)
                    return

    def _handle_settings(self, event):
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            # 快捷键项点击 → 进入重绑
            for i, (k, name) in enumerate(self._key_items()):
                r = pygame.Rect(340, 300 + i * 44, 220, 36)
                if r.collidepoint(event.pos):
                    self.rebinding = k
                    return
        if self.rebinding:
            if event.type == pygame.KEYDOWN:
                key = pygame.key.name(event.key).lower()
                if key == 'escape':
                    # MC 式：按 ESC = 清除该键位绑定
                    self.keys[self.rebinding] = ''
                    S.save(self.keys)
                    self.rebinding = None
                    return
                self._bind_key(key)
            elif event.type == pygame.MOUSEBUTTONDOWN:
                # 支持鼠标键
                self._bind_key(f'mouse{event.button}')

    def _bind_key(self, key):
        # 移除冲突（同一键绑给别的操作），然后绑定
        for k in list(self.keys):
            if self.keys[k] == key:
                self.keys[k] = ''
        self.keys[self.rebinding] = key
        S.save(self.keys)
        self.rebinding = None

    def _key_items(self):
        return [
            ('move', '移动'),
            ('attack', '攻击'),
            ('devour', '吞噬'),
            ('split', '拆分'),
            ('cancel', '取消选择'),
        ]

    def _name_rect(self):
        return pygame.Rect(430, 372, 250, 42)

    def _room_rects(self):
        out = []
        for i, r in enumerate(self.room_list[:4]):
            out.append((r, pygame.Rect(220, 452 + i * 46, 500, 38)))
        return out

    def _draw_bg(self):
        """近黑底 + 淡数字水印（0-9 随机散布，档案馆感）"""
        scr = self.screen
        w, h = scr.get_size()
        if self._bg_cache is None:
            surf = pygame.Surface((w, h))
            surf.fill(COL['bg'])
            rnd = random.Random(20260811)
            for _ in range(120):
                d = str(rnd.randint(0, 9))
                x = rnd.randint(0, w - 60)
                y = rnd.randint(0, h - 40)
                f = pygame.font.Font(None, rnd.choice([16, 22, 30]))
                img = f.render(d, True, (38, 36, 32))
                img.set_alpha(rnd.randint(30, 80))
                surf.blit(img, (x, y))
            self._bg_cache = surf
        scr.blit(self._bg_cache, (0, 0))

    def draw(self, dt):
        scr = self.screen
        w, h = scr.get_size()
        self._draw_bg()
        self.buttons = []
        self._cursor_t += dt

        # 顶栏
        draw_text(scr, f'AIM 数字大战 ▍ {VERSION}', 24, 12, color=COL['text_on_dark'], size=15)
        sc = COL['green'] if self.connected else COL['enemy']
        draw_text(scr, f'● {self.status}', w - 24, 12, color=sc, size=14, align='right')
        # 新版本提示（可点击去下载页）
        if self.update_info:
            nv = self.update_info.get('version', '?')
            self.buttons.append(Button((w - 280, 52, 256, 30),
                                       f'发现新版本 v{nv} → 下载',
                                       lambda: self._open_download(), color=COL['btn_dark'], on_dark=True))
        pygame.draw.line(scr, COL['border'], (0, 38), (w, 38), 1)
        # 顶栏右侧短竖线装饰
        draw_text(scr, '壹贰叁肆伍陆柒捌玖', w - 24, 22, color=(60, 56, 50), size=11, align='right')

        # 印章
        seal = pygame.Rect(24, 56, 96, 96)
        pygame.draw.rect(scr, COL['accent'], seal, 3)
        pygame.draw.rect(scr, COL['accent'], (seal.x + 6, seal.y + 6, seal.w - 12, seal.h - 12), 1)
        draw_text(scr, '数字', seal.centerx, seal.y + 16, color=COL['accent'], size=24, align='center')
        draw_text(scr, '大战', seal.centerx, seal.y + 46, color=COL['accent'], size=24, align='center')
        draw_text(scr, 'AIM', seal.centerx, seal.y + 76, color=COL['accent'], size=12, align='center')

        # 大标题 + 数字装饰
        draw_text(scr, 'AIM', 140, 46, color=COL['text_on_dark'], size=74)
        draw_text(scr, '0 1 2 3 4 5 6 7 8 9', 148, 118, color=(70, 64, 56), size=18)
        # 原创文案
        draw_text(scr, '数字即兵力——血与攻，都是数字本身。', 140, 150, color=COL['text_on_dark'], size=20)
        draw_text(scr, '一场战争，把敌人的数字减到零。', 140, 182, color=COL['text_dim'], size=14)

        # 规则（原创表述）
        draw_text(scr, '· 玩法速览 ·', 24, 226, color=COL['accent'], size=14)
        rules = [
            ('01', '数字即兵力', '有多少血，就有多大力'),
            ('02', '回合二选一', '造兵养势，或行动攻伐'),
            ('03', '打穿成桥', '溢出的伤害，长出独木桥'),
            ('04', '吞噬合一', '吞敌吞己，吞出基地与指挥'),
        ]
        for i, (no, t, d) in enumerate(rules):
            x = 24 + (i % 2) * 340
            y = 254 + (i // 2) * 48
            draw_text(scr, no, x, y, color=COL['accent'], size=15)
            draw_text(scr, t, x + 50, y, color=COL['text_on_dark'], size=16)
            draw_text(scr, d, x + 50, y + 22, color=COL['text_dim'], size=12)

        # 身份输入
        draw_text(scr, '身份 //', 24, 380, color=COL['text_dim'], size=13)
        nr = self._name_rect()
        pygame.draw.rect(scr, COL['bg_hi'], nr)
        pygame.draw.rect(scr, COL['accent'] if self.input_active else COL['border'], nr, 2)
        cur = '_' if (self.input_active and int(self._cursor_t * 2) % 2 == 0) else ''
        draw_text(scr, self.name + cur, nr.x + 12, nr.centery - 13, color=COL['text_on_dark'], size=20)

        # 按钮
        self.buttons.append(Button((24, 436, 180, 46), '接入对战', lambda: self.client.create_room(self.name), on_dark=True))
        self.buttons.append(Button((222, 436, 150, 46), '刷新队列', lambda: self.client.list_rooms(), color=COL['btn_dark'], on_dark=True))
        self.buttons.append(Button((390, 436, 180, 46), '🔥 本地热座', lambda: self.client.create_room(self.name, mode='hotseat'), color=COL['btn_dark'], on_dark=True))

        # 房间列表
        draw_text(scr, '等待中的房间 //', 220, 430 if False else 432 + 46 - 46, color=COL['text_dim'], size=13)
        for rid, rect in self._room_rects():
            pygame.draw.rect(scr, COL['bg_hi'], rect)
            pygame.draw.rect(scr, COL['border'], rect, 2)
            draw_text(scr, f'房间 {rid}', rect.x + 12, rect.centery - 11, color=COL['text_on_dark'], size=16)
            draw_text(scr, '加入 →', rect.right - 80, rect.centery - 11, color=COL['accent'], size=14)

        if self.room:
            self._draw_room(w, h)

        # 底部：版本 + 资源包
        pygame.draw.line(scr, COL['border'], (0, h - 56), (w, h - 56), 1)
        draw_text(scr, f'AIM {VERSION} · 数字大战', 24, h - 42, color=COL['text_dim'], size=12)
        draw_text(scr, '资源包 //', w - 420, h - 42, color=COL['text_dim'], size=12)
        if self.packs:
            p = self.packs[self.pack_idx]
            self.buttons.append(Button((w - 340, h - 48, 240, 32), f"{p['name']} · {p['author']}",
                                       self._cycle_pack, color=COL['btn_dark'], on_dark=True))

        for b in self.buttons:
            b.draw(scr)

        if self.show_settings:
            self._draw_settings(w, h)
        if self.show_tutorial:
            self._draw_tutorial(w, h)

    def _draw_tutorial(self, w, h):
        scr = self.screen
        pw, ph = 640, 460
        px, py = (w - pw) // 2, (h - ph) // 2 - 20
        s = pygame.Surface((w, h), pygame.SRCALPHA)
        s.fill((10, 10, 9, 215))
        scr.blit(s, (0, 0))
        pygame.draw.rect(scr, COL['bg_hi'], (px, py, pw, ph))
        pygame.draw.rect(scr, COL['border'], (px, py, pw, ph), 2)
        pygame.draw.line(scr, COL['accent'], (px + 12, py + 40), (px + pw - 12, py + 40), 2)
        draw_text(scr, f'新手教程 {self.tutorial_page + 1}/4', px + 16, py + 12, color=COL['accent'], size=16)
        pages = [
            [
                ('数字即兵力', 20, COL['text_on_dark']),
                ('0 空地 · 1 小兵 · 2 轻骑 · 3 弓手 · 4 炮手', 15, COL['text_dim']),
                ('5 重骑 · 6 滚木 · 7 盾兵 · 8 基地 · 9 指挥部', 15, COL['text_dim']),
                ('', 10, COL['text_dim']),
                ('血 = 攻 = 数字本身。受伤直接减数字，', 15, COL['text_dim']),
                ('减到 0 变空地；减成负数则数字取绝对值，', 15, COL['text_dim']),
                ('并在单位左边长出独木桥（地图+1格）。', 15, COL['text_dim']),
                ('', 10, COL['text_dim']),
                ('目标：把敌方所有数字之和减到 0，就赢了。', 17, COL['warn']),
                ('基地 8 是造兵点，指挥部 9 提供行动点（n+1）。', 15, COL['text_dim']),
            ],
            [
                ('回合', 20, COL['text_on_dark']),
                ('每回合二选一：造兵 或 行动。', 15, COL['text_dim']),
                ('点数必须用完，自动结束回合。', 15, COL['warn']),
                ('', 10, COL['text_dim']),
                ('造兵：点基地 → 再点一次，前方空地/己方+1，敌方-1。', 15, COL['text_dim']),
                ('行动（每点一个）：', 15, COL['text_dim']),
                ('移动：骑兵走2格，其他1格，只能前进', 14, COL['text_dim']),
                ('攻击：近战打面前，弓手2格，炮手3格', 14, COL['text_dim']),
                ('拆分：≥5 拆成两数，保留值自己选', 14, COL['text_dim']),
                ('吞噬：吃掉面前 ≤ 自己的单位（敌我皆可）', 14, COL['text_dim']),
            ],
            [
                ('独木桥 -', 20, COL['text_on_dark']),
                ('只有 1~4 轻单位能过桥。', 15, COL['text_dim']),
                ('5~7 强行走会踩塌桥，同归于尽。', 15, COL['warn']),
                ('小兵 1 过桥到对面能把桥拆成空地。', 15, COL['text_dim']),
                ('', 10, COL['text_dim']),
                ('滚木 6', 20, COL['text_on_dark']),
                ('造出来每回合自动滚 3 格，不能操控。', 15, COL['text_dim']),
                ('碾压 <6 的单位：溢出长桥，滚木继续滚', 15, COL['text_dim']),
                ('（若桥在前进方向，下一步会坠桥，桥毁木亡）', 14, COL['warn']),
                ('撞建筑消失 · 碾压 ≥7 只造成伤害', 15, COL['text_dim']),
            ],
            [
                ('操作', 20, COL['text_on_dark']),
                ('点自己单位选中 → 底部出现操作按键', 15, COL['text_dim']),
                ('移动/攻击/吞噬/拆分（能做啥显示啥）', 15, COL['text_dim']),
                ('单目标直接执行，多目标先选目标', 15, COL['text_dim']),
                ('拆分：滑动条选保留值，另一半放右侧', 15, COL['text_dim']),
                ('', 10, COL['text_dim']),
                ('电脑快捷键：1移动 2攻击 3吞噬 4拆分', 15, COL['warn']),
                ('（可在 ⚙ 设置里自定义，像 MC 一样绑定）', 14, COL['text_dim']),
                ('', 10, COL['text_dim']),
                ('观战：加入进行中的房间即可旁观', 15, COL['text_dim']),
            ],
        ]
        content = pages[self.tutorial_page]
        y = py + 60
        for text, size, color in content:
            draw_text(scr, text, px + 30, y, color=color, size=size)
            y += size + 8
        # 翻页按钮
        self.buttons.append(Button((px + pw // 2 - 90, py + ph - 46, 80, 36),
                                   '上一页', lambda: setattr(self, 'tutorial_page', max(0, self.tutorial_page - 1)), color=COL['btn_dark'], on_dark=True))
        self.buttons.append(Button((px + pw // 2 + 10, py + ph - 46, 80, 36),
                                   '下一页', lambda: setattr(self, 'tutorial_page', min(3, self.tutorial_page + 1)), color=COL['btn_dark'], on_dark=True))
        self.buttons.append(Button((px + pw - 110, py + 10, 90, 28), '关闭', lambda: setattr(self, 'show_tutorial', False), color=COL['btn_dark'], on_dark=True))

    def _draw_settings(self, w, h):
        scr = self.screen
        pw, ph = 420, 320
        px, py = (w - pw) // 2, (h - ph) // 2
        s = pygame.Surface((w, h), pygame.SRCALPHA)
        s.fill((10, 10, 9, 210))
        scr.blit(s, (0, 0))
        pygame.draw.rect(scr, COL['bg_hi'], (px, py, pw, ph))
        pygame.draw.rect(scr, COL['border'], (px, py, pw, ph), 2)
        pygame.draw.line(scr, COL['accent'], (px + 12, py + 40), (px + pw - 12, py + 40), 2)
        draw_text(scr, '设置 // 快捷键', px + 16, py + 12, color=COL['accent'], size=16)
        for i, (k, name) in enumerate(self._key_items()):
            r = pygame.Rect(px + 40, py + 62 + i * 46, 220, 38)
            pygame.draw.rect(scr, COL['bg_hi'], r)
            pygame.draw.rect(scr, COL['warn'] if self.rebinding == k else COL['border'], r, 2)
            draw_text(scr, name, r.x + 12, r.centery - 10, color=COL['text_on_dark'], size=15)
            key = self.keys.get(k, '')
            label = '按下新键…' if self.rebinding == k else (key.upper() if key else '（未绑定）')
            draw_text(scr, label, r.right - 12, r.centery - 10, color=COL['warn'], size=15, align='right')
        self.buttons.append(Button((px + 40, py + ph - 58, 200, 36), '创建桌面快捷方式',
                                    self._make_shortcut, color=COL['btn_dark'], on_dark=True))
        draw_text(scr, '点击按键项后按下新键即可重绑 · ESC 取消重绑',
                  px + pw // 2, py + ph - 26, color=COL['text_dim'], size=13, align='center')

    def _make_shortcut(self):
        import os
        import subprocess
        base = os.path.dirname(os.path.abspath(__file__))
        ps = ("$ws = New-Object -ComObject WScript.Shell; "
              "$d = [Environment]::GetFolderPath('Desktop'); "
              "$s = $ws.CreateShortcut($d + '\\AIM 数字大战.lnk'); "
              f"$s.TargetPath = '{base}\\run.bat'; "
              f"$s.WorkingDirectory = '{base}'; "
              f"$s.IconLocation = '{base}\\icon.ico,0'; $s.Save()")
        try:
            subprocess.Popen(['powershell', '-NoProfile', '-Command', ps],
                             creationflags=0x08000000)  # 隐藏窗口
            self.status = '已创建桌面快捷方式'
        except Exception as e:
            self.status = '创建失败: ' + str(e)[:30]

    def _cycle_pack(self):
        self.pack_idx = (self.pack_idx + 1) % len(self.packs)

    def _open_download(self):
        import webbrowser
        page = (self.update_info or {}).get('downloadPage') or 'http://192.140.166.178:5000/'
        try:
            webbrowser.open(page)
        except Exception:
            pass

    def _draw_room(self, w, h):
        r = self.room
        pw, ph = 500, 220
        px, py = (w - pw) // 2, 150
        s = pygame.Surface((w, h), pygame.SRCALPHA)
        s.fill((10, 10, 9, 210))
        self.screen.blit(s, (0, 0))
        pygame.draw.rect(self.screen, COL['bg_hi'], (px, py, pw, ph))
        pygame.draw.rect(self.screen, COL['border'], (px, py, pw, ph), 2)
        pygame.draw.line(self.screen, COL['accent'], (px + 12, py + 40), (px + pw - 12, py + 40), 2)
        mode = '热座' if r.get('mode') == 'hotseat' else '在线'
        draw_text(self.screen, f"房间 {r['id']} · {mode}", px + 16, py + 12, color=COL['accent'], size=15)
        names = [p['name'] for p in r['players']]
        draw_text(self.screen, '  vs  '.join(names) if len(names) == 2 else (names[0] + '  （等待对手…）'),
                  px + pw // 2, py + 62, color=COL['text_on_dark'], size=26, align='center')
        if self.you and self.you.get('playerIdx') == 0:
            draw_text(self.screen, '地图上限:', px + 40, py + 112, color=COL['text_dim'], size=14)
            for i, lim in enumerate([12, 14, 16]):
                x = px + 130 + i * 66
                c = COL['accent'] if self.limit == lim else COL['btn_dark']
                self.buttons.append(Button((x, py + 108, 58, 34), str(lim), lambda l=lim: self._set_limit(l), color=c, on_dark=True))
            if len(names) == 2:
                self.buttons.append(Button((px + pw // 2 - 90, py + 158, 180, 44), '开 战',
                                           lambda: self.client.start_game(self.limit), on_dark=True))

    def _set_limit(self, lim):
        self.limit = lim

    def _set_side(self, side):
        # 选边需要重建房（房主位置在服务端建房时定）
        # 简单方案：通过 leave + create 实现——但房间已建。用服务端接口更新
        if self.room:
            try:
                self.client.sio.emit('set_side', {'roomId': self.room['id'], 'side': side})
            except Exception:
                pass
