# AIM 数字大战 — PC 版入口（pygame）
# 主菜单：模式选择（双人热座 / AI 三档）/ 地图大小 / 规则开关 / 设置 / 投喂小猫 / 常驻小贴士
import os
import random
import sys
import time
import webbrowser

import pygame

from rules import AimGame
from ai import AimAi, EASY, NORMAL, HARD
from audio import Audio
from game_ui import (GameUI, INK, PAPER, SIGNAL, ENEMY, DIM, WARN, ORANGE,
                     BORDER, GREEN, _font)

W, H = 1280, 720

# ── 加载小贴士（与手机版对齐）──
TIPS = [
    ('开发', '这是一条 1.0 版本的 tip！'),
    ('开发', 'yhb 是项目的赞助人，至少他觉得自己是'),
    ('开发', '你很难想象没有平衡游戏性之前左边有多强……'),
    ('投喂', '喵喵喵～点击主页面的投喂按钮，投喂一下小猫吧～拜托啦！'),
    ('健康', '高三党！现在！立刻！给我去……喝口水…非高三党也是'),
    ('？？？', 'awa'),
    ('牢大', '我不要上学！！！'),
    ('开发', '新手教程剧情纯小猫编写，不要嫌弃喵！'),
    ('彩蛋', '你猜下一次看到这个 tip 是什么时候？'),
    ('角色', '8 是基地，9 是指挥部——把 8 喂成 9，就是全场最肥的单位。'),
    ('角色', '3 是弓手，射程 2；4 是炮手，射程 3。隔着格子白嫖，才是远程的正确用法。'),
    ('角色', '2 和 5 是骑兵，一回合能冲两步，比步兵腿长一倍。'),
    ('角色', '7 是盾兵，能挡下敌方攻击——把 7 顶在前面，后排才能安心输出。'),
    ('角色', '1 是最便宜的小兵，但别小看它：它是滚木的优质饲料。'),
    ('规则', '滚木每回合滚 3 格：前两格压伤单位（还会升级插桥），第三格直接抹杀。'),
    ('规则', '攻击的伤害溢出会长出桥——桥能过兵，但也可能被对手利用。'),
    ('规则', '1/2/3 能安全过桥；4（重装）和 5/7 踩桥会把桥踩塌，连人带桥一起没。'),
    ('规则', '吞噬超过 9 会拆成两个数字，贪心会变拉。'),
    ('规则', '一方无棋可走直接判负——把自己卡死也算输。'),
    ('规则', '象棋式防循环：完全相同的操作重复三次（局面复原）直接判负，别来回拉扯。'),
    ('技巧', '把 1 送到自家滚木的路径上：碾过去变 5，白赚一只骑兵。'),
    ('技巧', '滚木撞桥、撞建筑、滚出边界都会死——别让滚木白白送命。'),
    ('技巧', '点数快耗尽时会强制过回合，记得留点余粮。'),
    ('技巧', '回合二选一：造兵养势，或行动攻伐。憋大数字还是快攻，看准时机。'),
    ('技巧', '困难 AI 会用滚木刷兵、刷桥——这不是 bug，是特性。学就完了。'),
]

MODES = [
    ('双人热座', '两人共用一台电脑轮流操作', None),
    ('AI·简单', '随机出招，新手练手', EASY),
    ('AI·普通', '会攻击会合体，有来有回', NORMAL),
    ('AI·困难', '防守老练，会卡你走位', HARD),
]

AI_LABELS = {EASY: 'AI·简单（萌新）', NORMAL: 'AI·普通（老兵）', HARD: 'AI·困难（军团）'}

FEED_URL = 'http://192.140.166.178:5000/downloads/wechat_qr.png'
FEED_PAGE = 'http://192.140.166.178:8001/'


class Button:
    def __init__(self, rect, label, cb, accent=SIGNAL, size=20, sub=None):
        self.rect = rect
        self.label = label
        self.cb = cb
        self.accent = accent
        self.size = size
        self.sub = sub

    def draw(self, screen):
        pygame.draw.rect(screen, (26, 25, 22), self.rect)
        pygame.draw.rect(screen, self.accent, self.rect, 2)
        if self.sub:
            # 卡片式：标题大字(accent) + 描述小字(dim)，对齐手机端
            f = _font(self.size)
            t = f.render(self.label, True, self.accent)
            screen.blit(t, (self.rect.x + 12, self.rect.y + 6))
            fs = _font(13)
            ts = fs.render(self.sub, True, DIM)
            screen.blit(ts, (self.rect.x + 12, self.rect.y + self.size + 8))
        else:
            f = _font(self.size)
            t = f.render(self.label, True, self.accent)
            screen.blit(t, (self.rect.centerx - t.get_width() // 2,
                            self.rect.centery - t.get_height() // 2))

    def hit(self, pos):
        return self.rect.collidepoint(pos)


class Menu:
    def __init__(self, screen):
        self.screen = screen
        self.clock = pygame.time.Clock()
        self.audio = Audio(asset_dir=os.path.dirname(os.path.abspath(__file__)))
        if self.audio:
            self.audio.play_bgm('idle', asset_dir=os.path.dirname(os.path.abspath(__file__)))
        self.mode = 0            # MODES 下标（默认双人）
        self.limit = 16
        self.allow_own = True    # 滚木可被己方攻击
        self.pack_id = 'default'
        self.pack_name = '经典像素'   # 当前资源包（内置 default；扩展包时切换）
        self.tip_idx = random.randrange(len(TIPS))
        self.tip_timer = time.time() + 10
        self.player_name = '玩家1'
        self.exit_request = False
        self.buttons = []
        self._build_buttons()
        self._init_bubbles()

    def _build_buttons(self):
        self.buttons = []
        # 顶栏入口（右上）
        self.buttons.append(Button(pygame.Rect(W - 330, 16, 140, 30), '投喂小猫', self._feed, PAPER, size=13))
        self.buttons.append(Button(pygame.Rect(W - 180, 16, 140, 30), '设置', self._open_settings, PAPER, size=13))
        self.buttons.append(Button(pygame.Rect(W - 480, 16, 140, 30), '教程', self._open_tutorial, PAPER, size=13))
        # 资源包切换（底栏）
        self.buttons.append(Button(pygame.Rect(W - 330, H - 48, 150, 30), f'资源包 // {self.pack_name}', self._open_packs, DIM, size=13))
        # 模式入口（单行迷你按钮，横排，手机端 _miniBtn 风格）
        x = 470
        for i, (label, desc, lv) in enumerate(MODES):
            r = pygame.Rect(x, 430, 140, 36)
            self.buttons.append(Button(r, label, lambda i=i: self._start(i), WARN, size=15))
            x += 150
        # 地图 / 规则开关（手机端在进对局后设置，这里作为入口行提示）
        r = pygame.Rect(60, 480, 150, 36)
        self.buttons.append(Button(r, f'地图 {self.limit}', self._cycle_limit, ORANGE, size=15))
        r = pygame.Rect(220, 480, 190, 36)
        self.buttons.append(Button(r, '滚木可被己方攻击' if self.allow_own else '己方滚木免疫攻击',
                                   self._toggle_own, GREEN, size=15))
        # 退出（底栏右上）
        r = pygame.Rect(W - 160, H - 52, 120, 34)
        self.buttons.append(Button(r, '退出', self._quit, DIM, size=15))
        # 玩法速览说明
        self.hint_lines = [
            '数字即兵力——血与攻，都是数字本身。',
            '回合二选一：造兵养势，或行动攻伐。',
            '打穿成桥：溢出的伤害，长出独木桥。',
            '吞噬合一：吞敌吞己，吞出基地与指挥。',
        ]

    def _cycle_limit(self):
        self.limit = 12 if self.limit == 16 else (14 if self.limit == 12 else 16)
        self._build_buttons()

    def _toggle_own(self):
        self.allow_own = not self.allow_own
        self._build_buttons()

    def _feed(self):
        # 投喂弹窗：左收款码 + 右信息按钮（横屏横排，不超屏）；支持保存付款码到本地
        img = self._load_qr()
        status_txt = '已连接' if img is not None else '收款码加载失败（要联网）'
        saved_txt = ''
        done = False
        while not done and not self.exit_request:
            for e in pygame.event.get():
                if e.type == pygame.QUIT:
                    self.exit_request = True
                    done = True
                elif e.type == pygame.KEYDOWN and e.key == pygame.K_ESCAPE:
                    done = True
                elif e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
                    save_btn, close_btn, retry_btn = self._draw_feed(img, status_txt, saved_txt)
                    if save_btn.collidepoint(e.pos):
                        try:
                            path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wechat_qr.png')
                            with open(path, 'wb') as f:
                                f.write(self._qr_bytes)
                            saved_txt = '✅ 已保存到游戏目录 wechat_qr.png'
                            try:
                                webbrowser.open(path)
                            except Exception:
                                pass
                        except Exception:
                            saved_txt = '❌ 保存失败'
                    elif close_btn.collidepoint(e.pos):
                        done = True
                    elif img is None and retry_btn.collidepoint(e.pos):
                        img = self._load_qr()
                        status_txt = '已连接' if img is not None else '收款码加载失败（要联网）'
                        saved_txt = ''
            self._draw_feed(img, status_txt, saved_txt)
            pygame.display.flip()
            self.clock.tick(30)

    def _load_qr(self):
        # 下载收款码（缓存 bytes 供保存用），失败返回 None
        try:
            import urllib.request
            with urllib.request.urlopen(FEED_URL, timeout=8) as r:
                data = r.read()
            self._qr_bytes = data
            import io
            img = pygame.image.load(io.BytesIO(data))
            return img.convert_alpha() if img.get_alpha() else img.convert()
        except Exception:
            self._qr_bytes = b''
            return None

    def _draw_feed(self, img, status_txt, saved_txt):
        self.screen.fill(INK)
        ov = pygame.Surface((W, H), pygame.SRCALPHA)
        ov.fill((10, 10, 12, 190))
        self.screen.blit(ov, (0, 0))
        panel = pygame.Rect((W - 560) // 2, (H - 440) // 2, 560, 440)
        pygame.draw.rect(self.screen, (26, 25, 22), panel)
        pygame.draw.rect(self.screen, ORANGE, panel, 3)
        # 左：二维码（保持比例 contain，max 300）
        retry_btn = pygame.Rect(0, 0, 0, 0)
        if img is not None:
            scale = min(300 / img.get_width(), 380 / img.get_height(), 1.0)
            sw, sh = max(1, int(img.get_width() * scale)), max(1, int(img.get_height() * scale))
            scaled = pygame.transform.smoothscale(img, (sw, sh))
            self.screen.blit(scaled, (panel.x + 30, panel.centery - sh // 2))
        else:
            f = _font(16)
            t = f.render('加载失败', True, SIGNAL)
            self.screen.blit(t, (panel.x + 110 - t.get_width() // 2, panel.centery - 10))
            retry_btn = pygame.Rect(panel.x + 40, panel.centery + 20, 140, 40)
            pygame.draw.rect(self.screen, (42, 40, 36), retry_btn)
            pygame.draw.rect(self.screen, ORANGE, retry_btn, 2)
            rt = f.render('重试', True, ORANGE)
            self.screen.blit(rt, (retry_btn.centerx - rt.get_width() // 2, retry_btn.centery - rt.get_height() // 2))
        # 右：标题/说明/按钮
        rx = panel.x + 350
        f1 = _font(26)
        t1 = f1.render('🐱 投喂小猫咪', True, ORANGE)
        self.screen.blit(t1, (rx, panel.y + 60))
        f2 = _font(15)
        t2 = f2.render('喵呜～求求啦～给小猫一个小鱼干叭～', True, DIM)
        self.screen.blit(t2, (rx, panel.y + 110))
        t3 = f2.render('微信扫码 · 金额随意 · 投喂光荣', True, DIM)
        self.screen.blit(t3, (rx, panel.y + 136))
        # 保存按钮
        save_btn = pygame.Rect(rx, panel.y + 190, 180, 44)
        pygame.draw.rect(self.screen, (28, 46, 34), save_btn)
        pygame.draw.rect(self.screen, GREEN, save_btn, 2)
        st = f2.render('💾 保存付款码', True, GREEN)
        self.screen.blit(st, (save_btn.centerx - st.get_width() // 2, save_btn.centery - st.get_height() // 2))
        # 关闭按钮
        close_btn = pygame.Rect(rx, panel.y + 250, 180, 44)
        pygame.draw.rect(self.screen, (42, 40, 36), close_btn)
        pygame.draw.rect(self.screen, BORDER, close_btn, 2)
        ct = f2.render('收下猫的感谢', True, PAPER)
        self.screen.blit(ct, (close_btn.centerx - ct.get_width() // 2, close_btn.centery - ct.get_height() // 2))
        # 状态行
        if saved_txt:
            ft = _font(14)
            tt = ft.render(saved_txt, True, GREEN if '✅' in saved_txt else SIGNAL)
            self.screen.blit(tt, (rx, panel.y + 310))
        else:
            ft = _font(14)
            tt = ft.render(status_txt, True, DIM)
            self.screen.blit(tt, (rx, panel.y + 310))
        return save_btn, close_btn, retry_btn

    def _quit(self):
        self.exit_request = True

    def _start(self, idx):
        label, desc, lv = MODES[idx]
        self.mode = idx
        game = AimGame(limit=self.limit, allow_own_roller_attack=self.allow_own)
        ai = AimAi(lv) if lv else None
        ai_label = AI_LABELS.get(lv)
        ui = GameUI(self.screen, game, ai=ai, audio=self.audio,
                    player_name=self.player_name, ai_label=ai_label)
        # 对局循环（ui 自己跑事件循环，返回时回菜单）
        self._run_game_ui(ui)
        # 回到菜单：切 BGM
        if self.audio:
            self.audio.play_bgm('idle', asset_dir=os.path.dirname(os.path.abspath(__file__)))
        self._build_buttons()

    def _run_game_ui(self, ui):
        # 把事件循环交给 GameUI（它内部处理 run）
        # GameUI.run 内部已有 while 循环处理事件——这里用 try 包裹
        ui.run()
        # GameUI.run 里自己调 pygame.event.get，我们只需在它结束后返回

    def _loading(self, mode_label):
        # 黑屏 → Logo 淡入（1.5s）→ 停留 2.5s → 进对局；Logo 从服务器拉，失败兜底文字版
        logo = self._load_logo()
        t_start = time.time()
        fade_dur = 1.5
        hold_dur = 2.5
        done = False
        while not done and not self.exit_request:
            for e in pygame.event.get():
                if e.type == pygame.QUIT:
                    self.exit_request = True
                    return
            elapsed = time.time() - t_start
            if elapsed < fade_dur:
                alpha = int(255 * (elapsed / fade_dur))
            elif elapsed < fade_dur + hold_dur:
                alpha = 255
            else:
                done = True
                break
            self.screen.fill((0, 0, 0))
            if logo is not None:
                # 保持比例缩放（contain），最大占画幅 92%
                max_w, max_h = int(W * 0.92), int(H * 0.92)
                scale = min(max_w / logo.get_width(), max_h / logo.get_height(), 1.0)
                sw, sh = max(1, int(logo.get_width() * scale)), max(1, int(logo.get_height() * scale))
                scaled = pygame.transform.smoothscale(logo, (sw, sh))
                scaled.set_alpha(alpha)
                self.screen.blit(scaled, ((W - sw) // 2, (H - sh) // 2))
            else:
                f = _font(72)
                t = f.render('AIM', True, (255, 255, 255))
                t.set_alpha(alpha)
                self.screen.blit(t, ((W - t.get_width()) // 2, (H - t.get_height()) // 2 - 30))
            # 底部小字：模式信息
            f2 = _font(16)
            sub = f2.render(f'{mode_label} · 地图 {self.limit}', True, (120, 120, 130))
            self.screen.blit(sub, ((W - sub.get_width()) // 2, H - 60))
            pygame.display.flip()
            self.clock.tick(60)

    def _load_logo(self):
        # 本地打包的透明底白字 logo（离线可用）；失败返回 None（兜底文字版）
        try:
            path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logo.png')
            if not os.path.isfile(path):
                return None
            img = pygame.image.load(path)
            if img.get_alpha() is None:
                img = img.convert()
            else:
                img = img.convert_alpha()
            return img
        except Exception:
            return None

    def _open_packs(self):
        # 资源包：当前仅内置「经典像素」包（扩展包放 assets/art/<pid>/units 即出现在列表）
        done = False
        close_btn = pygame.Rect(0, 0, 0, 0)
        while not done and not self.exit_request:
            for e in pygame.event.get():
                if e.type == pygame.QUIT:
                    self.exit_request = True
                    return
                if e.type == pygame.KEYDOWN and e.key == pygame.K_ESCAPE:
                    done = True
                elif e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
                    if close_btn.collidepoint(e.pos):
                        done = True
            self.screen.fill(INK)
            ov = pygame.Surface((W, H), pygame.SRCALPHA)
            ov.fill((10, 10, 12, 190))
            self.screen.blit(ov, (0, 0))
            panel = pygame.Rect((W - 480) // 2, (H - 240) // 2, 480, 240)
            pygame.draw.rect(self.screen, (26, 25, 22), panel)
            pygame.draw.rect(self.screen, ORANGE, panel, 3)
            f = _font(22)
            t = f.render('资源包', True, ORANGE)
            self.screen.blit(t, (panel.x + 30, panel.y + 26))
            f2 = _font(16)
            t2 = f2.render(f'当前：{self.pack_name}（内置）', True, PAPER)
            self.screen.blit(t2, (panel.x + 30, panel.y + 82))
            t2 = f2.render('把自定义包放 assets/art/<包名>/units 即可切换', True, DIM)
            self.screen.blit(t2, (panel.x + 30, panel.y + 112))
            fb = _font(16)
            close_btn = pygame.Rect(panel.right - 130, panel.bottom - 52, 100, 36)
            pygame.draw.rect(self.screen, (42, 40, 36), close_btn)
            pygame.draw.rect(self.screen, ORANGE, close_btn, 2)
            bt = fb.render('关闭', True, ORANGE)
            self.screen.blit(bt, (close_btn.centerx - bt.get_width() // 2, close_btn.centery - bt.get_height() // 2))
            pygame.display.flip()
            self.clock.tick(60)
        self._build_buttons()

    def _open_tutorial(self):
        # 玩法说明弹窗（教程在 PC 版以玩法速览呈现；完整章节教程未移植）
        done = False
        lines = self.hint_lines
        close_btn = pygame.Rect(0, 0, 0, 0)
        while not done and not self.exit_request:
            for e in pygame.event.get():
                if e.type == pygame.QUIT:
                    self.exit_request = True
                    return
                if e.type == pygame.KEYDOWN and e.key == pygame.K_ESCAPE:
                    done = True
                elif e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
                    if close_btn.collidepoint(e.pos):
                        done = True
            self.screen.fill(INK)
            ov = pygame.Surface((W, H), pygame.SRCALPHA)
            ov.fill((10, 10, 12, 190))
            self.screen.blit(ov, (0, 0))
            panel = pygame.Rect((W - 560) // 2, (H - 320) // 2, 560, 320)
            pygame.draw.rect(self.screen, (26, 25, 22), panel)
            pygame.draw.rect(self.screen, SIGNAL, panel, 3)
            f = _font(24)
            t = f.render('· 玩法速览 ·', True, SIGNAL)
            self.screen.blit(t, (panel.x + 30, panel.y + 26))
            f2 = _font(17)
            y = panel.y + 78
            for line in lines:
                t2 = f2.render(line, True, PAPER)
                self.screen.blit(t2, (panel.x + 30, y))
                y += 34
            fb = _font(16)
            close_btn = pygame.Rect(panel.right - 140, panel.bottom - 54, 110, 38)
            pygame.draw.rect(self.screen, (42, 40, 36), close_btn)
            pygame.draw.rect(self.screen, ORANGE, close_btn, 2)
            bt = fb.render('关闭 (ESC)', True, ORANGE)
            self.screen.blit(bt, (close_btn.centerx - bt.get_width() // 2, close_btn.centery - bt.get_height() // 2))
            pygame.display.flip()
            self.clock.tick(60)
        self._build_buttons()

    def _open_settings(self):
        items = [
            ('BGM 音量', 'bgm', self.audio.bgm_vol if self.audio else 0.5),
            ('语音音量', 'voice', self.audio.voice_vol if self.audio else 1.0),
            ('音效音量', 'sfx', self.audio.sfx_vol if self.audio else 0.35),
        ]
        sel = 0
        done = False
        while not done and not self.exit_request:
            for e in pygame.event.get():
                if e.type == pygame.QUIT:
                    self.exit_request = True
                    done = True
                elif e.type == pygame.KEYDOWN:
                    if e.key == pygame.K_ESCAPE:
                        done = True
                    elif e.key == pygame.K_UP:
                        sel = (sel - 1) % len(items)
                    elif e.key == pygame.K_DOWN:
                        sel = (sel + 1) % len(items)
                    elif e.key == pygame.K_LEFT:
                        items[sel][2] = max(0.0, items[sel][2] - 0.05)
                    elif e.key == pygame.K_RIGHT:
                        items[sel][2] = min(1.0, items[sel][2] + 0.05)
                    elif e.key in (pygame.K_RETURN, pygame.K_SPACE):
                        done = True
            if self.audio:
                self.audio.bgm_vol = items[0][2]
                self.audio.voice_vol = items[1][2]
                self.audio.sfx_vol = items[2][2]
            self._draw_settings(items, sel)
            pygame.display.flip()
            self.clock.tick(30)

    def _draw_settings(self, items, sel):
        self.screen.fill(INK)
        f = _font(26)
        t = f.render('设置（↑↓选择  ←→调节  ESC返回）', True, WARN)
        self.screen.blit(t, ((W - t.get_width()) // 2, 140))
        f2 = _font(22)
        y = 230
        for i, (label, key, val) in enumerate(items):
            col = SIGNAL if i == sel else PAPER
            t1 = f2.render(f'{label}: {int(val * 100)}%', True, col)
            self.screen.blit(t1, ((W - t1.get_width()) // 2, y))
            y += 52
        f3 = _font(16)
        help_lines = [
            '对局快捷键：',
            '  A / P — 选择行动 / 造兵阶段',
            '  1-9 — 选中对应数字的己方单位',
            '  ↑↓ — 调整拆分保留值',
            '  Enter / 空格 — 执行选中行动 / 结束回合',
            '  E — 结束回合',
            '  M — 对局中打开设置',
            '  ESC — 取消选中 / 返回主菜单',
        ]
        y = 420
        for line in help_lines:
            t2 = f3.render(line, True, DIM)
            self.screen.blit(t2, ((W - t2.get_width()) // 2, y))
            y += 26

    def _init_bubbles(self):
        self.bubbles = []
        for _ in range(16):
            self.bubbles.append({
                'x': random.uniform(0, W), 'y': random.uniform(0, H),
                'dx': random.uniform(-16, 16), 'dy': random.uniform(-12, 12),
                'd': random.choice('0123456789'),
                'size': random.randint(28, 64),
                'ang': random.uniform(0, 360),
                'spin': random.uniform(-30, 30),
            })
        self._last_t = time.time()

    def _update_bubbles(self):
        now = time.time()
        dt = min(0.1, now - getattr(self, '_last_t', now))
        self._last_t = now
        mpos = pygame.mouse.get_pos()
        for b in self.bubbles:
            b['x'] += b['dx'] * dt
            b['y'] += b['dy'] * dt
            if b['x'] < -40 or b['x'] > W + 40:
                b['dx'] *= -1
            if b['y'] < -40 or b['y'] > H + 40:
                b['dy'] *= -1
            b['ang'] += b['spin'] * dt
            # 避开鼠标（靠近就推开），对齐手机端 BubbleDigits
            ddx, ddy = b['x'] - mpos[0], b['y'] - mpos[1]
            dd = (ddx * ddx + ddy * ddy) ** 0.5 + 1e-6
            if dd < 120:
                b['x'] += (ddx / dd) * 42 * dt
                b['y'] += (ddy / dd) * 42 * dt

    def _draw_bg_bubbles(self):
        self._update_bubbles()
        for b in self.bubbles:
            f = _font(int(b['size']))
            surf = f.render(b['d'], True, (58, 56, 50))
            surf.set_alpha(88)
            rot = pygame.transform.rotate(surf, b['ang'])
            self.screen.blit(rot, (b['x'] - rot.get_width() // 2,
                                   b['y'] - rot.get_height() // 2))

    def _draw(self):
        self.screen.fill(INK)
        self._draw_bg_bubbles()
        # ── 顶栏 ──
        ft = _font(14)
        t = ft.render('AIM 数字大战', True, PAPER)
        self.screen.blit(t, (20, 20))
        # ── 标题块：印章 + 大字 ──
        self._draw_seal(60, 78)
        f_big = _font(46)
        t = f_big.render('AIM', True, PAPER)
        self.screen.blit(t, (150, 74))
        f_d = _font(13)
        t = f_d.render('0 1 2 3 4 5 6 7 8 9', True, (120, 112, 96))
        self.screen.blit(t, (152, 130))
        f_c = _font(16)
        t = f_c.render('数字即兵力——血与攻，都是数字本身。', True, PAPER)
        self.screen.blit(t, (152, 156))
        f_s = _font(12)
        t = f_s.render('一场战争，把敌人的数字减到零。', True, DIM)
        self.screen.blit(t, (152, 184))
        # ── 玩法速览 ──
        self._draw_rules(60, 250)
        # ── Tip ──
        cat, txt = TIPS[self.tip_idx]
        ftip = _font(13)
        t = ftip.render('Tip: ', True, WARN)
        self.screen.blit(t, (60, 356))
        t = ftip.render(txt, True, DIM)
        self.screen.blit(t, (108, 356))
        # ── 入口行说明 ──
        fdesc = _font(12)
        self._blit_multiline(fdesc, '双人热座：单机双人，一台设备轮流操作\nAI：三档难度，人机对战', DIM, 60, 428, 26)
        # ── 按钮（顶栏/模式/地图/规则/退出）──
        for b in self.buttons:
            b.draw(self.screen)
        # ── 底栏 ──
        fb = _font(12)
        t = fb.render('AIM 1.2.1 · 数字大战', True, DIM)
        self.screen.blit(t, (20, H - 26))

    def _draw_seal(self, x, y):
        s = 64
        pygame.draw.rect(self.screen, SIGNAL, (x, y, s, s), 2)
        pygame.draw.rect(self.screen, SIGNAL, (x + 4, y + 4, s - 8, s - 8), 1)
        f = _font(30)
        t = f.render('A', True, SIGNAL)
        self.screen.blit(t, (x + s // 2 - t.get_width() // 2, y + s // 2 - t.get_height() // 2))

    def _draw_rules(self, x, y):
        rules = [('01', '数字即兵力', '有多少血，就有多大力'),
                 ('02', '回合二选一', '造兵养势，或行动攻伐'),
                 ('03', '打穿成桥', '溢出的伤害，长出独木桥'),
                 ('04', '吞噬合一', '吞敌吞己，吞出基地与指挥')]
        f = _font(14)
        t = f.render('· 玩法速览 ·', True, SIGNAL)
        self.screen.blit(t, (x, y))
        yy = y + 26
        fr, fd = _font(13), _font(11)
        for i, (no, title, desc) in enumerate(rules):
            rx = x + (i % 2) * 430
            ryy = yy + (i // 2) * 46
            t = fr.render(no, True, SIGNAL)
            self.screen.blit(t, (rx, ryy))
            t = fr.render(title, True, PAPER)
            self.screen.blit(t, (rx + 34, ryy))
            t = fd.render(desc, True, DIM)
            self.screen.blit(t, (rx + 34, ryy + 18))

    def _blit_multiline(self, f, text, color, x, y, lh):
        for line in text.split('\n'):
            t = f.render(line, True, color)
            self.screen.blit(t, (x, y))
            y += lh

    def run(self):
        while not self.exit_request:
            for e in pygame.event.get():
                if e.type == pygame.QUIT:
                    self.exit_request = True
                elif e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
                    for b in self.buttons:
                        if b.hit(e.pos):
                            b.cb()
                            break
                    # 点 tip 换一条
                    if e.pos[1] > H - 60:
                        self.tip_idx = (self.tip_idx + 1) % len(TIPS)
                elif e.type == pygame.KEYDOWN:
                    if e.key == pygame.K_ESCAPE:
                        self.exit_request = True
            # 定时换 tip
            if time.time() >= self.tip_timer:
                self.tip_idx = (self.tip_idx + 1) % len(TIPS)
                self.tip_timer = time.time() + 10
            self._draw()
            pygame.display.flip()
            self.clock.tick(60)
        pygame.quit()
        sys.exit(0)


def _load_logo():
    """本地打包的透明底白字 logo（离线可用）；失败返回 None（兜底文字版）。"""
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logo.png')
        if not os.path.isfile(path):
            return None
        img = pygame.image.load(path)
        if img.get_alpha() is None:
            img = img.convert()
        else:
            img = img.convert_alpha()
        return img
    except Exception:
        return None


def _startup_splash(screen, clock):
    """启动 logo 加载画面：黑屏 → Logo 淡入（1.5s）→ 停留（2.5s）→ 进主菜单。"""
    logo = _load_logo()
    t0 = time.time()
    fade_dur, hold_dur = 1.5, 2.5
    done = False
    while not done:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                return
        elapsed = time.time() - t0
        if elapsed < fade_dur:
            alpha = int(255 * (elapsed / fade_dur))
        elif elapsed < fade_dur + hold_dur:
            alpha = 255
        else:
            done = True
            break
        screen.fill((0, 0, 0))
        if logo is not None:
            max_w, max_h = int(W * 0.92), int(H * 0.92)
            scale = min(max_w / logo.get_width(), max_h / logo.get_height(), 1.0)
            sw = max(1, int(logo.get_width() * scale))
            sh = max(1, int(logo.get_height() * scale))
            sc = pygame.transform.smoothscale(logo, (sw, sh))
            sc.set_alpha(alpha)
            screen.blit(sc, ((W - sw) // 2, (H - sh) // 2))
        else:
            f = _font(72)
            t = f.render('AIM', True, (255, 255, 255))
            t.set_alpha(alpha)
            screen.blit(t, ((W - t.get_width()) // 2, (H - t.get_height()) // 2 - 30))
        pygame.display.flip()
        clock.tick(60)


def main():
    pygame.init()
    pygame.display.set_caption('AIM 数字大战')
    screen = pygame.display.set_mode((W, H))
    clock = pygame.time.Clock()
    # 启动 logo 加载（进入游戏时加载，而非进对局时）
    _startup_splash(screen, clock)
    menu = Menu(screen)
    menu.run()


if __name__ == '__main__':
    main()
