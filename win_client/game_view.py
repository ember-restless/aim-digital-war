# AIM 对局界面（复古棋盘风）
import pygame

from ui import COL, Button, panel, draw_text, font

CELL = 88
CELL_PAD = 4
GRID_Y = 100
INFO_H = 84
PANEL_Y = 372
PANEL_H = 196
LOG_Y = 648


class GameView:
    def __init__(self, screen, art, client):
        self.screen = screen
        self.art = art
        self.client = client
        self.state = None
        self.myIdx = None
        self.sel_unit = None
        self.sel_action = None
        self.split_options = None
        self.split_full = None
        self.log = []
        self.buttons = []
        self.over = None
        self.toast = None
        self.toast_t = 0
        self._back = False
        self.scroll_x = 0
        self.round = 1
        self._my_phase_seen = False
        self.pending = None  # 多义目标选择（攻击/吞噬）
        self.split_slider = None  # {i, v, keep} 拆分滚动条

    # ---------- 状态 ----------
    def on_state(self, s):
        prev = self.state
        self.state = s
        if self.myIdx is None and 'yourIdx' in s:
            self.myIdx = s['yourIdx']

        # 回合计数：轮到自己且刚进入选阶段时 +1
        if s.get('turn') == s.get('yourIdx') and s.get('phase') is None and s.get('winner') is None:
            if not self._my_phase_seen:
                self.round += 1
                self._my_phase_seen = True
        elif s.get('phase') is not None or s.get('turn') != s.get('yourIdx'):
            self._my_phase_seen = False
        if s.get('winner') is not None:
            self.over = {'winner': s['winner'], 'winnerName': None}
        if s.get('log'):
            for line in s['log']:
                if line not in self.log[-20:]:
                    self.log.append(line)
        self.log = self.log[-6:]
        self.sel_unit = None
        self.sel_action = None
        self.split_options = None
        self.split_full = None
        self.pending = None

    def on_over(self, d):
        self.over = d

    def on_error(self, msg):
        self.toast = (msg, 2.0)
        self.toast_t = 2.0

    def on_event(self, name, data):
        if name == 'game_state':
            self.on_state(data)
        elif name == 'game_over':
            self.on_over(data)
        elif name == 'server_error':
            self.on_error(data.get('msg', '错误') if data else '错误')
        elif name == 'you_are':
            self.myIdx = data.get('playerIdx')
        elif name == 'chat':
            pass

    # ---------- 工具 ----------
    def my_turn(self):
        return self.state and self.state['turn'] == self.state['yourIdx'] and self.state['winner'] is None

    def cell_rect(self, idx, n):
        total = n * (CELL + CELL_PAD) - CELL_PAD
        w = self.screen.get_width()
        base = (w - total) // 2 if total < w else 10
        x = base + idx * (CELL + CELL_PAD) - self.scroll_x
        return pygame.Rect(x, GRID_Y, CELL, CELL)

    def _max_scroll(self, n):
        total = n * (CELL + CELL_PAD) - CELL_PAD
        w = self.screen.get_width()
        return max(0, total - w + 20)

    def legal_of_unit(self, i):
        if not self.state:
            return []
        return [a for a in self.state.get('legalActions', []) if a.get('i') == i]

    def can_click_unit(self, i):
        if not self.my_turn():
            return False
        c = self.state['cells'][i]
        if c.get('bridge') or c.get('v') == 0:
            return False
        if c.get('o') != self.myIdx:
            return False
        if self.state['phase'] == 'produce':
            return c['v'] == 8
        return len(self.legal_of_unit(i)) > 0

    # ---------- 事件 ----------
    def _hotkey(self, key):
        """快捷键：移动/攻击/吞噬/拆分/取消（选中单位时）"""
        if self.sel_unit is None:
            return False
        import settings as S
        keys = S.load()
        kmap = {keys.get('move'): 'move', keys.get('attack'): 'attack',
                keys.get('devour'): 'devour', keys.get('split'): 'split',
                keys.get('cancel'): 'cancel'}
        action = kmap.get(key)
        if action is None:
            return False
        if action == 'cancel':
            self.sel_unit = None
            self.sel_action = None
            self.split_slider = None
            return True
        if action in ('move', 'attack', 'devour', 'split'):
            acts = self.legal_of_unit(self.sel_unit)
            if not any(a['type'] == action for a in acts):
                return True  # 该操作不可用，吞掉按键
            self._mk_action(action)()
            return True
        return False

    def handle(self, event):
        for b in self.buttons:
            b.handle(event)
        if event.type == pygame.KEYDOWN:
            if self._hotkey(pygame.key.name(event.key).lower()):
                return
        if event.type == pygame.MOUSEWHEEL and self.state:
            if self.split_slider:
                # 拆分滚动条：滚轮切换保留值
                v = self.split_slider['v']
                self.split_slider['keep'] = max(1, min(v - 1, self.split_slider['keep'] + event.y))
            else:
                n = len(self.state['cells'])
                self.scroll_x = max(0, min(self.scroll_x - event.y * 48, self._max_scroll(n)))
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1 and self.state:
            # 左键：拆分滑块确认优先
            if self.split_slider and self._slider_rect().collidepoint(event.pos):
                self._confirm_split()
                return
            self._click(event.pos)


    def _try_produce(self, i):
        s = self.state
        dirn = -1 if self.myIdx == 1 else 1
        j = i + dirn
        cells = s['cells']
        if 0 <= j < len(cells) and not cells[j].get('bridge'):
            self.client.action({'type': 'produce', 'i': i, 'j': j})
        else:
            self.show_toast('造不来了（前方被独木桥挡住）')

    def _slider_rect(self):
        if not self.split_slider:
            return pygame.Rect(0, 0, 0, 0)
        n = len(self.state['cells'])
        r = self.cell_rect(self.split_slider['i'], n)
        return pygame.Rect(r.x - 10, r.y - 34, r.w + 20, 28)

    def _confirm_split(self):
        sl = self.split_slider
        if sl:
            self.client.action({'type': 'split', 'i': sl['i'], 'keep': sl['keep']})
            self.split_slider = None
            self.sel_unit = None

    def _click(self, pos):
        n = len(self.state['cells'])
        for i in range(n):
            if self.cell_rect(i, n).collidepoint(pos):
                self._click_cell(i)
                return
        if self.split_options:
            for opt, rect in self.split_options:
                if rect.collidepoint(pos):
                    self._pick_split(opt)
                    return

    def _click_cell(self, i):
        s = self.state
        c = s['cells'][i]
        if not self.my_turn():
            return
        # 造兵阶段：点基地直接造
        if s['phase'] == 'produce':
            if c.get('o') == self.myIdx and c.get('v') == 8 and not c.get('bridge'):
                self._try_produce(i)
            return
        if s['phase'] is None:
            # 未选阶段：点基地=造兵（隐式选造兵），点单位=选中（隐式行动）
            if c.get('o') == self.myIdx and c.get('v') == 8 and not c.get('bridge'):
                self._try_produce(i)
                return
            # 否则继续走选中/目标逻辑
        # 已选中单位：点目标格直接执行
        if self.sel_unit is not None:
            acts = self.legal_of_unit(self.sel_unit)
            targets = []
            for a in acts:
                if a['type'] == 'move' and self._move_target(a) == i:
                    targets.append(a)
                elif a['type'] in ('attack', 'devour') and a.get('j') == i:
                    targets.append(a)
            if targets:
                if len(targets) == 1:
                    self.client.action(targets[0])
                    self.sel_unit = None
                else:
                    # 多义目标（攻击+吞噬重叠）：弹选择
                    self.pending = targets
                return
            # 点自己取消选中
            if i == self.sel_unit:
                self.sel_unit = None
            return
        # 未选中：点单位选中
        if self.can_click_unit(i):
            self.sel_unit = i
            self.split_options = None
            self.split_full = None
            self.pending = None

    def _pick_split(self, opt):
        a, b = opt['a'], opt['b']
        if self.state['mapLen'] >= self.state['limit']:
            self.split_full = opt
            self.split_options = None
            return
        self.client.action({'type': 'split', 'i': opt['i'], 'keep': opt['a']})
        self.sel_unit = self.sel_action = None
        self.split_options = None

    # ---------- 渲染 ----------
    def _draw_bg(self):
        self.screen.fill(COL['bg'])

    def draw(self, dt):
        s = self.state
        if not s:
            return
        scr = self.screen
        self._draw_bg()
        self.buttons = []

        self._draw_info(s)
        # 地图底座（深色实验台）
        n = len(s['cells'])
        total = n * (CELL + CELL_PAD) - CELL_PAD
        base_x = (scr.get_width() - total) // 2 if total < scr.get_width() else 10
        pygame.draw.rect(scr, COL['bg_hi'], (base_x - 14 - min(self.scroll_x, 0), GRID_Y - 14,
                                             total + 28, CELL + 28))
        pygame.draw.rect(scr, COL['border'], (base_x - 14 - min(self.scroll_x, 0), GRID_Y - 14,
                                              total + 28, CELL + 28), 2)
        for i, c in enumerate(s['cells']):
            self._draw_cell(i, c, n)

        if self.split_options:
            self._draw_split_options()
        if self.split_full:
            self._draw_split_full()
        if self.split_slider:
            self._draw_split_slider()

        self._draw_action_panel(s)
        self._draw_log()

        if self.over:
            self._draw_over()

        for b in self.buttons:
            b.draw(scr)

        if self.toast:
            self.toast_t -= dt
            if self.toast_t <= 0:
                self.toast = None
            else:
                draw_text(scr, self.toast[0], scr.get_width() // 2, 30, color=COL['warn'], size=22, align='center')

    def _draw_info(self, s):
        scr = self.screen
        w = scr.get_width()
        names = s.get('names') or ['玩家1', '玩家2']
        if s.get('spectator'):
            sums = s.get('sums') or [0, 0]
            bases = s.get('bases') or [0, 0]
            hqs = s.get('hqs') or [0, 0]
            draw_text(scr, f'{names[0]}  基地×{bases[0]}  指挥部×{hqs[0]}  数字和{sums[0]}',
                      28, 22, color=COL['accent'], size=20)
            draw_text(scr, f'{names[1]}  数字和{sums[1]}', w - 28, 22, color=COL['enemy'], size=20, align='right')
            mid = '观战中 · 不能操作'
            tw = max(320, len(mid) * 17)
            tag = pygame.Rect((w - tw) // 2, 24, tw, 36)
            pygame.draw.rect(scr, COL['warn'], tag)
            pygame.draw.rect(scr, COL['border'], tag, 2)
            draw_text(scr, mid, w // 2, tag.y + 7, color=COL['text'], size=17, align='center')
            return
        me = s['yourIdx']
        en = 1 - me
        # 深色计分卡
        bar = pygame.Rect(12, 10, w - 24, 64)
        pygame.draw.rect(scr, COL['bg_hi'], bar)
        pygame.draw.rect(scr, COL['border'], bar, 2)
        draw_text(scr, f'{names[me]}  基地×{s["myBases"]}  指挥部×{s["myHqs"]}  数字和{s["mySum"]}',
                  28, 22, color=COL['text_on_dark'], size=20)
        draw_text(scr, f'{names[en]}  数字和{s["enemySum"]}', w - 28, 22, color=COL['enemy'], size=20, align='right')
        # 回合状态（橙红标签）
        if s['winner'] is not None:
            mid = 'EXPERIMENT OVER // 对局结束'
        elif self.my_turn():
            if s['phase'] is None:
                mid = f'回合 {self.round} · {names[me]}：行动 or 造兵'
            elif s['phase'] == 'produce':
                mid = f'回合 {self.round} · {names[me]} 造兵（剩 {s["produceLeft"]} 次）'
            else:
                mid = f'回合 {self.round} · {names[me]} 行动（剩 {s["points"]} 点）'
        else:
            mid = f'回合 {self.round} · 等待对手行动…'
        tw = max(320, len(mid) * 17)
        tag = pygame.Rect((w - tw) // 2, 24, tw, 36)
        pygame.draw.rect(scr, COL['accent'], tag)
        pygame.draw.rect(scr, COL['border'], tag, 2)
        draw_text(scr, mid, w // 2, tag.y + 7, color=COL['text_on_dark'], size=17, align='center')

    def _draw_cell(self, i, c, n):
        rect = self.cell_rect(i, n)
        # 棋盘格底色
        base = COL['cell_even'] if i % 2 == 0 else COL['cell_odd']
        pygame.draw.rect(self.screen, base, rect)
        # 我方/敌方格子微染色（暗调）
        if c.get('v') and c.get('v') > 0 and not c.get('bridge'):
            if c.get('o') == self.myIdx:
                base = (34, 30, 26) if i % 2 == 0 else (28, 25, 22)
            else:
                base = (32, 24, 22) if i % 2 == 0 else (26, 20, 18)
            pygame.draw.rect(self.screen, base, rect)
        # 图标：单位上桥后只显示单位（桥隐藏在脚下，不显示）
        if c.get('bridge') and not c.get('onBridge'):
            img = self.art.bridge()
        else:
            img = self.art.unit(c.get('v', 0), c.get('o', 0))
        if img:
            self.screen.blit(pygame.transform.scale(img, (CELL - 8, CELL - 8)), (rect.x + 4, rect.y + 4))
        # 边框
        border = COL['border']
        tt = self._target_type(i)
        if self.sel_unit == i:
            border = COL['warn']
        elif tt == 'move':
            border = COL['green']
        elif tt == 'attack':
            border = COL['enemy']
        elif tt == 'devour':
            border = COL['warn']
        elif self.can_click_unit(i):
            border = COL['green']
        elif c.get('v') is not None and c.get('v') > 0 and not c.get('bridge') and c.get('o') != self.myIdx:
            # 敌方单位：若有我方单位能攻击/吞噬它 → 亮橙红高亮（滚木等目标一眼可见）
            la = self.state.get('legalActions') or []
            if any(a.get('type') in ('attack', 'devour') and a.get('j') == i for a in la):
                border = COL['atk']
            else:
                border = COL['enemy']
        elif c.get('v') is not None and c.get('v') > 0 and not c.get('bridge'):
            border = COL['accent'] if c.get('o') == self.myIdx else COL['enemy']
        pygame.draw.rect(self.screen, border, rect, 3 if border != COL['border'] else 2)
        # 基地箭头
        if c.get('v') == 8 and c.get('o') is not None:
            dirn = -1 if c['o'] == 0 else 1
            cx = rect.centerx + dirn * (CELL // 2 - 8)
            pygame.draw.polygon(self.screen, COL['border'],
                                [(cx, rect.centery - 6), (cx, rect.centery + 6), (cx + dirn * 8, rect.centery)])

    def _move_target(self, a):
        """移动行动的目标格"""
        if not self.state:
            return None
        dirn = -1 if self.state['yourIdx'] == 1 else 1
        return a['i'] + dirn * a['steps']

    def _target_type(self, i):
        """目标格行动类型：move/attack/devour/None"""
        if not self.state or self.sel_unit is None:
            return None
        acts = self.legal_of_unit(self.sel_unit)
        for a in acts:
            if a['type'] == 'move' and self._move_target(a) == i:
                return 'move'
            if a['type'] in ('attack', 'devour') and a.get('j') == i:
                return a['type']
        return None

    def _draw_action_panel(self, s):
        scr = self.screen
        w = scr.get_width()
        panel(scr, pygame.Rect(12, PANEL_Y, w - 24, PANEL_H), title='行动')
        bx, by = 28, PANEL_Y + 38
        # 图例
        lx = w - 420
        draw_text(scr, '边框:', lx, PANEL_Y + 8, color=COL['text_dim'], size=13)
        legend = [('■', COL['accent'], '我方'), ('■', COL['enemy'], '敌方'),
                  ('■', COL['green'], '移动/可点'), ('■', COL['warn'], '吞噬/选中')]
        xx = lx + 48
        for ch, col, name in legend:
            draw_text(scr, ch, xx, PANEL_Y + 8, color=col, size=15)
            draw_text(scr, name, xx + 15, PANEL_Y + 9, color=COL['text_dim'], size=12)
            xx += 72
        # 已选中单位：优先显示操作按键（任何阶段）
        if self.sel_unit is not None:
            self._draw_unit_actions(s, bx, by)
            return
        if s.get('spectator'):
            draw_text(scr, '观战中 · 等待对局结束', bx, by, color=COL['text_dim'], size=17)
            return
        if not self.my_turn():
            draw_text(scr, '对手回合中…', bx, by, color=COL['text_dim'], size=18)
            return
        if s['phase'] is None:
            draw_text(scr, '点击基地造兵 · 点击单位行动（点数用完自动过回合）', bx, by, color=COL['text'], size=17)
        elif s['phase'] == 'produce':
            draw_text(scr, f'造兵阶段 · 剩余 {s["produceLeft"]} 次 · 点击基地造兵', bx, by, color=COL['text'], size=17)
            draw_text(scr, '造兵点用完自动结束回合', bx, by + 34, color=COL['text_dim'], size=14)
        else:
            draw_text(scr, f'行动阶段 · 剩余 {s["points"]} 点：点单位选中，点目标格执行', bx, by, color=COL['text'], size=17)
        if self.over:
            self.buttons.append(Button((w - 170, 14, 150, 38), '返回大厅', self._back_to_menu))

    def _draw_unit_actions(self, s, bx, by):
        acts = self.legal_of_unit(self.sel_unit)
        x = bx
        # 选目标模式
        if self.sel_action in ('attack', 'devour'):
            draw_text(self.screen, f'点击目标执行（{"攻击" if self.sel_action == "attack" else "吞噬"}）',
                      bx, by, color=COL['warn'], size=16)
            self.buttons.append(Button((bx, by + 30, 110, 42), '取消',
                                       lambda: setattr(self, 'sel_action', None)))
            return
        # 操作按键（根据可用操作显示）
        shown = set()
        for a in acts:
            t = a['type']
            if t in ('move', 'attack', 'devour', 'split') and t not in shown:
                shown.add(t)
                label = {'move': '移动', 'attack': '攻击', 'devour': '吞噬', 'split': '拆分'}[t]
                self.buttons.append(Button((x, by, 110, 44), label, self._mk_action(t)))
                x += 122
        self.buttons.append(Button((x, by, 110, 44), '取消', lambda: setattr(self, 'sel_unit', None)))
        draw_text(self.screen, '或直接点击目标格执行 · 剩余行动点', bx, by + 58, color=COL['text_dim'], size=14)
        draw_text(self.screen, f'拆分需选择保留值 · 剩余 {s["points"]} 点', bx, by + 80, color=COL['text_dim'], size=14)

    def _mk_action(self, t):
        def cb():
            acts = self.legal_of_unit(self.sel_unit)
            if t == 'move':
                mv = next((a for a in acts if a['type'] == 'move'), None)
                if mv:
                    self.client.action(mv)
                    self.sel_unit = None
            elif t in ('attack', 'devour'):
                tgt_list = [a for a in acts if a['type'] == t]
                if len(tgt_list) == 1:
                    # 只有一个目标：直接执行
                    self.client.action(tgt_list[0])
                    self.sel_unit = None
                elif len(tgt_list) > 1:
                    # 多个目标：进入选目标模式
                    self.sel_action = t
            elif t == 'split':
                v = self.state['cells'][self.sel_unit]['v']
                self.split_slider = {'i': self.sel_unit, 'v': v, 'keep': 1}
        return cb

    def _pick_pending(self, t):
        def cb():
            act = next((a for a in self.pending if a['type'] == t), None)
            if act:
                self.client.action(act)
                self.sel_unit = None
                self.pending = None
        return cb

    def _open_split(self):
        acts = self.legal_of_unit(self.sel_unit)
        split_act = next((a for a in acts if a['type'] == 'split'), None)
        if split_act:
            self.split_options = self._split_opts(split_act)

    def _split_opts(self, act):
        opts = []
        seen = set()
        for a in self.state['legalActions']:
            if a['type'] == 'split' and a.get('i') == self.sel_unit:
                key = tuple(sorted((a['a'], a['b'])))
                if key not in seen:
                    seen.add(key)
                    opts.append(a)
        return opts

    def _draw_split_slider(self):
        scr = self.screen
        rect = self._slider_rect()
        pygame.draw.rect(scr, COL['bg_hi'], rect)
        pygame.draw.rect(scr, COL['warn'], rect, 2)
        v = self.split_slider['v']
        keep = self.split_slider['keep']
        draw_text(scr, f'拆分 {v}：保留', rect.x + 8, rect.y + 5, color=COL['text_on_dark'], size=13)
        # 滚动条轨道
        tx, ty = rect.x + 78, rect.y + 6
        tw = rect.w - 96
        pygame.draw.rect(scr, COL['btn_dark'], (tx, ty, tw, 16))
        # 可选值标记
        for k in range(1, v):
            x = tx + int((k - 1) / (v - 2) * (tw - 4)) + 2
            draw_text(scr, str(k), x, ty + 1, color=COL['text_dim'], size=11)
        # 当前值
        cx = tx + int((keep - 1) / max(1, v - 2) * (tw - 4)) + 2
        pygame.draw.rect(scr, COL['accent'], (cx - 8, ty - 2, 20, 20))
        draw_text(scr, str(keep), cx - 3, ty - 1, color=COL['text_on_dark'], size=13)
        draw_text(scr, f'→ {v - keep} 放右侧 · 滚轮选 · 左键确认 · 右键取消',
                  rect.x + 8, rect.y + 12, color=COL['text_dim'], size=11)

    def _draw_split_options(self):
        y = PANEL_Y + 110
        x = 28
        rects = []
        for a in self.split_options:
            r = pygame.Rect(x, y, 120, 38)
            pygame.draw.rect(self.screen, COL['btn'], r)
            pygame.draw.rect(self.screen, COL['border'], r, 2)
            draw_text(self.screen, f"{a['a']}+{a['b']}", r.centerx, r.centery - 10, color=COL['text_on_dark'], size=18, align='center')
            rects.append((a, r))
            x += 132
        self.split_options = [(o, r) for o, r in rects]

    def _draw_split_full(self):
        scr = self.screen
        w = scr.get_width()
        y = PANEL_Y + 90
        panel(scr, pygame.Rect(w // 2 - 210, y, 420, 96), title='地图已满：保大还是保小？')
        o = self.split_full
        big, small = max(o['a'], o['b']), min(o['a'], o['b'])

        def keep(k):
            def cb():
                kk = big if k == 'big' else small  # 服务端只认数字 keep
                self.client.action({'type': 'split', 'i': o['i'], 'keep': kk})
                self.split_full = None
                self.sel_unit = self.sel_action = None
            return cb

        self.buttons.append(Button((w // 2 - 180, y + 44, 150, 40), f'保大 {big}', keep('big')))
        self.buttons.append(Button((w // 2 + 30, y + 44, 150, 40), f'保小 {small}', keep('small')))

    def _draw_log(self):
        scr = self.screen
        w = scr.get_width()
        bar = pygame.Rect(12, LOG_Y, w - 24, 60)
        pygame.draw.rect(scr, COL['bg_hi'], bar)
        pygame.draw.rect(scr, COL['border'], bar, 2)
        draw_text(scr, 'LOG // 战报', bar.x + 14, bar.y + 8, color=COL['accent'], size=13)
        lines = self.log[-3:]
        for i, ln in enumerate(lines):
            draw_text(scr, '· ' + ln, bar.x + 14, bar.y + 30 + i * 15, color=COL['text_dim'], size=13)

    def _draw_over(self):
        scr = self.screen
        w, h = scr.get_size()
        s = pygame.Surface((w, h), pygame.SRCALPHA)
        s.fill((30, 22, 14, 180))
        scr.blit(s, (0, 0))
        bw, bh = 400, 220
        bx, by = (w - bw) // 2, (h - bh) // 2
        pygame.draw.rect(scr, COL['bg_hi'], (bx, by, bw, bh))
        pygame.draw.rect(scr, COL['panel'], (bx + 10, by + 10, bw - 20, bh - 20))
        pygame.draw.rect(scr, COL['border'], (bx, by, bw, bh), 3)
        draw_text(scr, '· 战 报 归 档 ·', w // 2, by + 10, color=COL['accent'], size=15, align='center')
        if self.state and self.state.get('hotseat'):
            # 热座：左边/右边获胜
            names = (self.state.get('names') or ['左边', '右边'])
            side = '左边' if self.over['winner'] == 0 else '右边'
            txt = f'{side} 获胜'
            col = COL['warn']
            sub = f'{names[self.over["winner"]]} 把对手的数字减到了零'
        else:
            win = self.over['winner'] == self.myIdx
            txt = '胜 利' if win else '败 北'
            col = COL['green'] if win else COL['enemy']
            sub = '敌方数字和归零' if win else '你的数字和归零了'
        draw_text(scr, txt, w // 2, by + 34, color=col, size=44, align='center')
        draw_text(scr, sub, w // 2, by + 102, color=COL['text'], size=17, align='center')
        self.buttons.append(Button((w // 2 - 80, by + 140, 160, 44), '返回大厅', self._back_to_menu))

    def _back_to_menu(self):
        self.state = None
        self.over = None
        self.sel_unit = None
        self.buttons = []
        try:
            self.client.sio.emit('leave_room')
        except Exception:
            pass
        self._back = True
