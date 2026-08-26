# AIM PC 对局界面（pygame）
# 对齐手机版 GameScreen：棋盘渲染 / 选中行动 / 轻量动画 / 滚木逐步 / 结算统计 / 快捷键
import math
import os
import random
import sys
import time

import pygame

from rules import AimGame, AimCell, K_RANGE, K_BRIDGE_OK, K_CAVALRY

# ── 配色（对齐手机版）──
INK = (17, 17, 15)
PAPER = (255, 245, 220)
SIGNAL = (255, 78, 53)
ENEMY = (177, 39, 24)
DIM = (119, 115, 107)
WARN = (255, 211, 106)
ORANGE = (232, 163, 61)
BORDER = (90, 85, 76)
GREEN = (97, 211, 158)
CELL_EVEN = (30, 29, 26)
CELL_ODD = (24, 23, 21)
BRIDGE_C = (120, 88, 52)
BRIDGE_DARK = (84, 60, 36)

CELL = 56          # 格子大小
MARGIN_X = 60
BOARD_Y = 210

# 字体：用随包通用中文字体（手机端文字是普通字体，仅数字/单位用像素 PNG 图）
FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fonts', 'wqy-microhei.ttc')


def _font(size):
    try:
        return pygame.font.Font(FONT_PATH, size)
    except Exception:
        return pygame.font.SysFont('microsoftyahei,simhei,arial,wenquanyimicrohei', size)


# ── 单位像素图（与手机端同款 assets/art/default/units/*.png）──
_UNIT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'assets', 'art', 'default', 'units')
_UI_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'assets', 'art', 'default', 'ui')
_img_cache = {}


def _load_png(subdir, name, size):
    key = (subdir, name, size)
    if key not in _img_cache:
        p = os.path.join(_UNIT_DIR if subdir == 'units' else _UI_DIR, name + '.png')
        try:
            img = pygame.image.load(p).convert_alpha()
            if img.get_width() != size:
                img = pygame.transform.smoothscale(img, (size, size))
        except Exception:
            img = None
        _img_cache[key] = img
    return _img_cache[key]


class GameUI:
    def __init__(self, screen, game, ai=None, audio=None, player_name='玩家1', ai_label=None):
        self.screen = screen
        self.w, self.h = screen.get_size()
        self.game = game
        self.ai = ai            # None=双人热座；非 None=玩家0 vs AI(玩家1)
        self.ai_level_label = ai_label
        self.audio = audio
        self.player_name = player_name
        # ── 交互状态 ──
        self.sel = None          # 选中的格子索引
        self.sel_actions = []    # 当前选中单位的可行行动（display 用）
        self.split_keep = 1
        self.split_track = None   # 拆分滑块轨道 rect
        self.split_v0 = 0         # 拆分单位当前值
        self.split_drag = False   # 是否正在拖滑块
        self.layout = 'classic'   # 'classic' | 'compact' | 'side'
        self.phase_buttons = []  # 阶段选择按钮 rect
        self.action_buttons = [] # 行动按钮 rect
        self.log_lines = []
        self.anim = None         # 当前动画 {type, t0, dur, ...}
        self.anim_lock = False
        self.over_panel = None   # 结算数据
        self.warn_msg = None     # 浮动警告（重复操作提示等）
        self.warn_t0 = 0.0
        self.exit_request = False
        self.bgm_which = 'battle'
        # ── 定时 ──
        self.ai_timer = None     # (deadline) AI 决策延迟
        self.clock = pygame.time.Clock()
        self.t0 = time.time()
        self.rand = random.Random()
        self.sfx_lock_until = 0
        self.voice_lock_until = 0
        self._refresh_log()
        if audio:
            audio.play_bgm('battle', asset_dir=self._asset_dir())

    def _asset_dir(self):
        return os.path.dirname(os.path.abspath(__file__))

    # ═══ 状态查询 ═══
    def _my_turn(self):
        if self.game.winner is not None:
            return False
        if self.ai is not None and self.game.turn == 1:
            return False  # AI 回合
        return True

    def _view(self):
        return self.game.view_for(0)

    def _refresh_log(self):
        self.log_lines = list(self.game.log[-6:]) if self.game.log else ['']

    # ═══ 主循环 ═══
    def run(self):
        if self.audio:
            self.audio.play_bgm('battle', asset_dir=self._asset_dir())
        while not self.exit_request:
            dt = self.clock.tick(60) / 1000.0
            for e in pygame.event.get():
                if e.type == pygame.QUIT:
                    self.exit_request = True
                else:
                    self.handle_event(e)
            self._update(dt)
            self._draw()
            pygame.display.flip()
        return 'menu'

    def _update(self, dt):
        # 动画推进
        if self.anim and time.time() - self.anim['t0'] >= self.anim['dur']:
            self.anim = None
            self.anim_lock = False
            self._after_anim()
        # AI 决策延迟
        if self.ai_timer is not None:
            if time.time() >= self.ai_timer:
                self.ai_timer = None
                self._ai_step()
        # 动画期间锁输入
        if self.anim_lock:
            return
        if self.game.winner is not None:
            return
        if not self._my_turn():
            if self.ai_timer is None:
                self.ai_timer = time.time() + 0.7
            return
        # 无阶段 → 等选阶段（玩家点按钮或快捷键）
        if self.game.phase is None:
            return
        # 回合结束检查（不该发生，兜底）
        if self.game.phase == 'action' and self.game.points <= 0:
            self._end_turn()
        elif self.game.phase == 'produce' and self.game.produce_left <= 0:
            self._end_turn()

    def _after_anim(self):
        # 动画播完后的连锁：滚木逐步驱动 / AI 下一步 / 胜负检查
        if self.game.winner is not None:
            self._build_over_panel()
            return
        if self.game.has_pending_roll:
            self.game.clear_pending_roll()
            self._drive_roll()
            return
        if self.ai is not None and self.game.turn == 1 and self.game.winner is None:
            self.ai_timer = time.time() + 0.7

    # ═══ 行动执行（统一入口：先播动画，动画完再解锁）═══
    def _do_action(self, action):
        v = self._view()
        cells_before = [dict(c) for c in v['cells']]
        r = self.game.apply_action(self.game.turn, action, defer_roll=True)
        if not r.get('ok'):
            return False
        if r.get('repeatWarn'):
            # 第 2 次重复：提示「再重复一次将判负」（象棋式规则）
            self.warn_msg = '⚠ 再重复一次相同操作将直接判负！'
            self.warn_t0 = time.time()
        self._refresh_log()
        # 音效/语音
        self._play_action_fx(action)
        # 生成动画
        la = self.game.last_action
        if la:
            self.anim = self._build_anim(la, cells_before)
            self.anim_lock = True
        else:
            self._after_anim()
        return True

    def _play_action_fx(self, action):
        if not self.audio:
            return
        t = action.get('type')
        if t == 'move':
            i = action.get('i', 0)
            v = self.game.cells[i].v if i < len(self.game.cells) else 1
            self.audio.play_sfx('move')
            self.audio.play_voice('move', v)
        elif t == 'attack':
            i = action.get('i', 0)
            v = self.game.cells[i].v if i < len(self.game.cells) else 1
            self.audio.play_sfx('shoot' if v in (3, 4) else 'attack')
            self.audio.play_voice('attack', v)
        elif t == 'devour':
            self.audio.play_sfx('devour')
        elif t == 'split':
            self.audio.play_sfx('split')
        elif t == 'produce':
            self.audio.play_sfx('produce')
        elif t == 'choosePhase':
            pass

    def _play_select_voice(self, idx):
        if not self.audio or idx >= len(self.game.cells):
            return
        v = self.game.cells[idx].v
        self.audio.play_voice('select', v)

    # ═══ 滚木逐步驱动 ═══
    def _drive_roll(self):
        owner = self.game.turn
        acts = self.game.roll_step_once(owner)
        if self.audio:
            self.audio.play_sfx('roll')
        if acts is None:
            self._after_roll_done()
            return
        # 渲染滚木动画（每步 0.32s）
        self.anim = {'type': 'roll', 't0': time.time(), 'dur': 0.32, 'acts': acts}
        self.anim_lock = True

    def _after_roll_done(self):
        self._refresh_log()
        # 滚木滚完：若还有 pendingRoll（多滚木）继续；否则查胜负/AI
        if self.game.has_pending_roll:
            self._drive_roll()
            return
        self._check_after_turn()

    def _check_after_turn(self):
        self._refresh_log()
        if self.game.winner is not None:
            self._build_over_panel()
            return
        if self.ai is not None and self.game.turn == 1:
            self.ai_timer = time.time() + 0.7

    # ═══ 回合控制 ═══
    def _end_turn(self):
        self.sel = None
        self.sel_actions = []
        ok = self.game.end_turn(self.game.turn, defer_roll=True)
        if not ok:
            return
        self._refresh_log()
        if self.game.has_pending_roll:
            self._drive_roll()
        else:
            self._check_after_turn()

    # ═══ AI 一步 ═══
    def _ai_step(self):
        if self.game.winner is not None:
            return
        if not (self.ai is not None and self.game.turn == 1):
            return
        action = self.ai.decide(self.game)
        if action is None:
            return
        # AI 行动同样走动画
        self._do_action(action)

    # ═══ 动画生成（轻量：插值/闪烁/特效）═══
    def _build_anim(self, la, cells_before):
        t = la.get('type')
        if t == 'move':
            steps = la.get('steps', 1)
            return {'type': 'move', 't0': time.time(), 'dur': 0.18 * steps,
                    'i': la['i'], 'steps': steps, 'owner': la['owner'],
                    'bridge_collapse': la.get('bridgeCollapse')}
        if t == 'attack':
            return {'type': 'attack', 't0': time.time(), 'dur': 0.28,
                    'i': la['i'], 'j': la['j'], 'shielded': la.get('shielded'),
                    'old': la.get('old'), 'newV': la.get('newV'),
                    'insertedAt': la.get('insertedAt')}
        if t == 'devour':
            return {'type': 'devour', 't0': time.time(), 'dur': 0.3,
                    'i': la['i'], 'j': la['j'], 'sum': la.get('sum'),
                    'spliced': la.get('spliced'), 'collapsed': la.get('collapsed')}
        if t == 'split':
            return {'type': 'split', 't0': time.time(), 'dur': 0.24, 'i': la['i']}
        if t == 'produce':
            return {'type': 'produce', 't0': time.time(), 'dur': 0.2,
                    'j': la.get('j'), 'attacked': la.get('attacked')}
        return None

    # ═══ 输入 ═══
    def handle_event(self, e):
        if e.type == pygame.QUIT:
            self.exit_request = True
            return
        if e.type == pygame.KEYDOWN:
            self._on_key(e.key)
            return
        if e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
            # 拆分滑块点/拖
            if self.split_track is not None and self.split_track.collidepoint(e.pos):
                self._set_split_from_x(e.pos[0])
                self.split_drag = True
                return
            self._on_click(e.pos)
            return
        if e.type == pygame.MOUSEMOTION:
            if self.split_drag and self.split_track is not None:
                self._set_split_from_x(e.pos[0])
            return
        if e.type == pygame.MOUSEBUTTONUP and e.button == 1:
            self.split_drag = False
            return

    def _on_key(self, key):
        if self.game.winner is not None:
            if key in (pygame.K_ESCAPE, pygame.K_RETURN, pygame.K_SPACE):
                self.exit_request = True
            return
        if self.anim_lock:
            return
        # ESC：取消选中 / 回菜单
        if key == pygame.K_ESCAPE:
            if self.sel is not None:
                self.sel = None
                self.sel_actions = []
            else:
                self.exit_request = True
            return
        if not self._my_turn():
            return
        # 布局切换（F2 循环：经典 / 简洁 / 侧栏）
        if key == pygame.K_F2:
            self.layout = {'classic': 'compact', 'compact': 'side', 'side': 'classic'}[self.layout]
            return
        if key == pygame.K_m:
            self._open_settings()
            return
        # 阶段选择
        if self.game.phase is None:
            if key == pygame.K_a:
                self._do_action({'type': 'choosePhase', 'phase': 'action'})
            elif key == pygame.K_p:
                self._do_action({'type': 'choosePhase', 'phase': 'produce'})
            return
        # 数字键：选中数字 n 的己方单位
        if pygame.K_1 <= key <= pygame.K_9:
            n = key - pygame.K_0
            idx = self._find_unit(n, self.sel)
            if idx is not None:
                self._select(idx)
            return
        # 方向键：移动选中
        if key == pygame.K_LEFT or key == pygame.K_RIGHT:
            self._move_sel(-1 if key == pygame.K_LEFT else 1)
            return
        # 拆分 keep 调整
        if key == pygame.K_UP or key == pygame.K_DOWN:
            if self.sel is not None:
                max_keep = self.game.cells[self.sel].v
                if max_keep > 1:
                    self.split_keep += 1 if key == pygame.K_UP else -1
                    self.split_keep = max(1, min(max_keep - 1, self.split_keep))
            return
        # Enter：执行推荐行动 / 结束回合
        if key in (pygame.K_RETURN, pygame.K_SPACE):
            if self.sel is not None and self.sel_actions:
                # 第一个可选行动（按手机版排序近似：移动>攻击>吞噬>拆分 由引擎顺序决定）
                self._exec_action(self.sel_actions[0])
            elif self.game.phase == 'action':
                self._end_turn()
            return
        # E：结束回合
        if key == pygame.K_e:
            if self.game.phase is not None:
                self._end_turn()

    def _find_unit(self, n, from_sel):
        cells = self.game.cells
        start = (from_sel + 1) if from_sel is not None else 0
        for k in range(len(cells)):
            idx = (start + k) % len(cells)
            c = cells[idx]
            if c.o == self.game.turn and c.v == n and not (c.v == 6 and c.auto):
                return idx
        # 没找到数字 n，退化为选任意己方单位
        for k in range(len(cells)):
            c = cells[k]
            if c.o == self.game.turn and c.v >= 1 and not (c.v == 6 and c.auto):
                return k
        return None

    def _move_sel(self, delta):
        if self.sel is None:
            return
        n = len(self.game.cells)
        idx = (self.sel + delta) % n
        self.sel = idx
        self._select(idx, play_voice=False)

    def _on_click(self, pos):
        if self.game.winner is not None:
            if self.over_panel and self._rect_in(pos, self.over_panel.get('btn')):
                self.exit_request = True
            return
        if self.anim_lock:
            return
        if not self._my_turn():
            return
        # 结算/设置按钮先于棋盘
        # 阶段选择按钮
        if self.game.phase is None:
            for rect, act in self.phase_buttons:
                if self._rect_in(pos, rect):
                    self._do_action(act)
                    return
            return
        # 行动按钮（选中单位时）
        for rect, act in self.action_buttons:
            if self._rect_in(pos, rect):
                self._exec_action(act)
                return
        # 棋盘格点击
        idx = self._cell_at(pos)
        if idx is None:
            if self.sel is not None:
                self.sel = None
                self.sel_actions = []
            return
        c = self.game.cells[idx]
        owner = self.game.turn
        # 造兵阶段：点基地前格造兵
        if self.game.phase == 'produce':
            acts = self.game.get_legal_actions(owner)
            for a in acts:
                if a['type'] == 'produce' and a['j'] == idx:
                    self._do_action(a)
                    return
            return
        # 行动阶段：点击可行目标直接执行
        if self.sel is not None:
            for a in self.sel_actions:
                if a['type'] == 'attack' and a['j'] == idx:
                    self._exec_action(a)
                    return
                if a['type'] == 'devour' and a['j'] == idx:
                    self._exec_action(a)
                    return
                if a['type'] == 'move' and a['i'] == self.sel and self._move_target_idx(a) == idx:
                    self._exec_action(a)
                    return
        # 点击己方可动单位 → 选中
        if c.o == owner and c.v >= 1 and not (c.v == 6 and c.auto):
            self._select(idx)

    def _select(self, idx, play_voice=True):
        self.sel = idx
        self.split_keep = 1
        owner = self.game.turn
        acts = self.game.get_legal_actions(owner)
        self.sel_actions = [a for a in acts if a['type'] in ('move', 'attack', 'devour', 'split') and a['i'] == idx]
        if play_voice:
            self._play_select_voice(idx)
        if self.audio:
            self.audio.play_sfx('select')

    def _move_target_idx(self, a):
        d = 1 if self.game.turn == 0 else -1
        return a['i'] + d * a.get('steps', 1)

    def _exec_action(self, a):
        # 拆分 keep 用滑块值
        if a['type'] == 'split':
            a = dict(a)
            a['keep'] = self.split_keep
        self.sel = None
        self.sel_actions = []
        self._do_action(a)

    # ═══ 几何 ═══
    def _board_rects(self):
        n = len(self.game.cells)
        total = n * CELL
        x0 = (self.w - total) // 2
        return x0, [pygame.Rect(x0 + i * CELL, BOARD_Y, CELL, CELL) for i in range(n)]

    def _cell_at(self, pos):
        x0, rects = self._board_rects()
        for i, r in enumerate(rects):
            if r.collidepoint(pos):
                return i
        return None

    def _rect_in(self, pos, rect):
        if rect is None:
            return False
        return rect.collidepoint(pos)

    # ═══ 渲染 ═══
    def _draw(self):
        self.screen.fill(INK)
        v = self._view()
        cells = self.game.cells
        if self.layout == 'side':
            self._draw_side(v, cells)
            return
        if self.layout == 'compact':
            self._draw_topbar_compact(v)
        else:
            self._draw_topbar(v)
        x0, rects = self._board_rects()
        for i, r in enumerate(rects):
            self._draw_cell(i, r, cells[i])
        if self.anim:
            self._draw_anim(v)
        self._draw_interaction(rects)
        self._draw_action_panel(rects)
        self._draw_log()
        self._draw_warn()
        if self.game.winner is not None and self.over_panel:
            self._draw_over()
        elif self.anim_lock is False and self.game.winner is None:
            self._draw_hint()

    def _draw_topbar_compact(self, v):
        # 简洁：状态压成一行（回合·阶段·地图·数字和），地图最大化
        p0 = self.player_name if self.ai is None else self.player_name
        p1 = self.ai_level_label or '玩家2'
        f = _font(15)
        parts = [f'回合 {self.game.turn_count + 1}']
        if self.game.winner is not None:
            parts.append('对局结束')
        elif self.game.phase is None:
            parts.append(f'{p0}：行动 or 造兵')
        elif self.game.phase == 'produce':
            parts.append(f'{p0}造兵剩{self.game.produce_left}次')
        else:
            parts.append(f'{p0}行动剩{self.game.points}点')
        parts.append(f'地图 {len(self.game.cells)}/{self.game.limit}')
        parts.append(f'和 {self.game.sum_of(0)}/{self.game.sum_of(1)}')
        t = f.render('  ·  '.join(parts), True, (255, 255, 255))
        self.screen.blit(t, ((self.w - t.get_width()) // 2, 12))
        # 布局提示
        h = _font(12)
        th = h.render('F2 切换布局（简洁）', True, DIM)
        self.screen.blit(th, (16, 12))

    def _draw_side(self, v, cells):
        # 侧栏：左竖排状态 + 战报，右侧大棋盘 + 行动面板
        sidew = 200
        # 左栏状态
        p0 = self.player_name if self.ai is None else self.player_name
        p1 = self.ai_level_label or '玩家2'
        f = _font(17)
        lf = _font(14)
        t = f.render(p0, True, SIGNAL)
        self.screen.blit(t, (16, 20))
        t = lf.render(f'和 {self.game.sum_of(0)}  基地{self.game.count_of(0, 8)}', True, DIM)
        self.screen.blit(t, (16, 48))
        t = f.render(p1, True, ENEMY)
        self.screen.blit(t, (16, 82))
        t = lf.render(f'和 {self.game.sum_of(1)}', True, DIM)
        self.screen.blit(t, (16, 110))
        t = lf.render(f'回合 {self.game.turn_count + 1}', True, WARN)
        self.screen.blit(t, (16, 144))
        mid_txt = self._mid_text(p0, p1)
        t = lf.render(mid_txt, True, (255, 255, 255))
        self.screen.blit(t, (16, 168))
        t = lf.render(f'地图 {len(self.game.cells)}/{self.game.limit}', True, DIM)
        self.screen.blit(t, (16, 190))
        t = _font(12).render('F2 切换布局', True, DIM)
        self.screen.blit(t, (16, 214))
        # 左栏战报
        y = 250
        t = _font(13).render('战报', True, DIM)
        self.screen.blit(t, (16, y))
        yy = y + 20
        for line in self.log_lines:
            t = lf.render(f'· {line}', True, DIM)
            self.screen.blit(t, (16, yy))
            yy += 15
        # 右：地图 + 行动面板
        x0 = sidew
        n = len(cells)
        total = n * CELL
        mx = max(sidew + 20, (self.w + sidew - total) // 2)
        rects = [pygame.Rect(mx + i * CELL, BOARD_Y, CELL, CELL) for i in range(n)]
        for i, r in enumerate(rects):
            self._draw_cell(i, r, cells[i])
        if self.anim:
            self._draw_anim(v or self._view())
        self._draw_interaction(rects)
        self._draw_action_panel(rects)

    def _draw_topbar(self, v):
        p0 = self.player_name if self.ai is None else self.player_name
        p1 = self.ai_level_label or '玩家2'
        limit = self.game.limit
        lf, tf = _font(18), _font(14)
        # 左：我方（基地数 + 数字和）
        b0 = self.game.count_of(0, 8)
        t0 = lf.render(f'{p0}  基地×{b0}', True, SIGNAL)
        self.screen.blit(t0, (16, 12))
        s0 = tf.render(f'数字和 {self.game.sum_of(0)}', True, DIM)
        self.screen.blit(s0, (16, 40))
        # 右：敌方
        t1 = lf.render(p1, True, ENEMY)
        self.screen.blit(t1, (self.w - 16 - t1.get_width(), 12))
        s1 = tf.render(f'数字和 {self.game.sum_of(1)}', True, DIM)
        self.screen.blit(s1, (self.w - 16 - s1.get_width(), 40))
        # 中：回合 · 阶段 + 地图
        mid = f'回合 {self.game.turn_count + 1} · ' + self._mid_text(p0, p1)
        m = lf.render(mid, True, (255, 255, 255))
        self.screen.blit(m, ((self.w - m.get_width()) // 2, 12))
        mapt = tf.render(f'地图 {len(self.game.cells)}/{limit}', True, DIM)
        self.screen.blit(mapt, ((self.w - mapt.get_width()) // 2, 42))

    def _mid_text(self, p0, p1):
        if self.game.winner is not None:
            return '对局结束'
        if self.game.phase is None:
            return f'{p0}：行动 or 造兵'
        if self.game.phase == 'produce':
            return f'{p0}造兵（剩{self.game.produce_left}次）'
        if self.game.turn == 1 and self.ai is not None:
            return f'等待 {p1}…'
        return f'{p0}行动（剩{self.game.points}点）'

    # ── 手机端同款格子视觉 ──
    def _cell_bg(self, i, c):
        if c.bridge:
            return (42, 40, 36)                              # 0x2A2824 桥
        if c.v <= 0:
            return CELL_EVEN if i % 2 == 0 else CELL_ODD
        if c.o == 0:                                         # 我方
            return (38, 34, 32) if i % 2 == 0 else (32, 28, 26)
        return (36, 28, 26) if i % 2 == 0 else (30, 22, 20)  # 敌方

    def _target_type(self, i):
        d = 1 if self.game.turn == 0 else -1
        for a in (self.sel_actions or []):
            tp = a.get('type')
            if tp == 'move':
                for st in range(1, int(a.get('steps', 1)) + 1):
                    if i == a['i'] + d * st:
                        return 'move'
            elif tp in ('attack', 'devour') and a.get('j') == i:
                return tp
        return None

    def _can_click(self, i):
        c = self.game.cells[i]
        return c.v >= 1 and not c.bridge

    def _border_color(self, i, c):
        if self.sel == i:
            return WARN
        tt = self._target_type(i)
        if tt == 'move':
            return GREEN
        if tt == 'attack':
            return ENEMY
        if tt == 'devour':
            return WARN
        if c.v >= 1 and not c.bridge:
            return SIGNAL if c.o == 0 else ENEMY
        return BORDER

    def _draw_cell(self, i, r, c):
        pygame.draw.rect(self.screen, self._cell_bg(i, c), r)
        pygame.draw.rect(self.screen, self._border_color(i, c), r,
                         3 if self.sel == i else 2)
        # 单位像素图（数字/0/桥），与手机端同批素材
        size = int(r.w * 0.9)
        if c.bridge and not c.onBridge:
            img = _load_png('units', 'dash', size)
        elif c.v <= 0:
            img = _load_png('units', '0', size)
        else:
            img = _load_png('units', str(c.v), size)
        if img is not None:
            self.screen.blit(img, (r.centerx - img.get_width() // 2,
                                   r.centery - img.get_height() // 2))
        # 基地方向标 ▶（随归属左右）
        if c.v == 8 and c.o is not None:
            f = _font(12)
            t = f.render('▶', True, DIM)
            if c.o == 0:
                self.screen.blit(t, (r.left + 2, r.top + 2))
            else:
                self.screen.blit(t, (r.right - t.get_width() - 2, r.top + 2))
        # 滚木压着的单位（底部小字）
        if c.v == 6 and c.pressedV:
            fp = _font(12)
            tp = fp.render(f'压:{c.pressedV}', True, DIM)
            self.screen.blit(tp, (r.centerx - tp.get_width() // 2, r.bottom - 16))

    def _draw_anim(self, v):
        a = self.anim
        prog = min(1.0, (time.time() - a['t0']) / a['dur'])
        t = a['type']
        if t == 'move':
            # 单位平移插值
            i, steps = a['i'], a['steps']
            d = 1 if a['owner'] == 0 else -1
            x0, rects = self._board_rects()
            from_x = rects[i].centerx
            to_x = rects[i + d * steps].centerx
            cx = from_x + (to_x - from_x) * prog
            cy = rects[i].centery
            col = SIGNAL if a['owner'] == 0 else ENEMY
            pygame.draw.circle(self.screen, col, (int(cx), int(cy)), 20)
            f = _font(24)
            ttxt = f.render('●', True, col)
            self.screen.blit(ttxt, (int(cx) - 12, int(cy) - 12))
        elif t == 'attack':
            x0, rects = self._board_rects()
            i, j = a['i'], a['j']
            if 0 <= i < len(rects) and 0 <= j < len(rects):
                p1 = rects[i].center
                p2 = rects[j].center
                if a.get('shielded'):
                    pygame.draw.line(self.screen, WARN, p1, p2, 3)
                    f = _font(16)
                    ts = f.render('挡!', True, WARN)
                    self.screen.blit(ts, (rects[j].centerx - 14, rects[j].y - 22))
                else:
                    pygame.draw.line(self.screen, SIGNAL, p1, p2, 3)
                    # 伤害数字
                    old = a.get('old')
                    nv = a.get('newV')
                    if old is not None:
                        txt = f'{old}→{nv}' if nv is not None else f'-{old}'
                        fd = _font(18)
                        td = fd.render(txt, True, WARN)
                        self.screen.blit(td, (rects[j].centerx - td.get_width() // 2, rects[j].y - 24))
        elif t == 'devour':
            x0, rects = self._board_rects()
            i, j = a['i'], a['j']
            if 0 <= j < len(rects):
                r = rects[j]
                if a.get('spliced'):
                    f = _font(16)
                    ts = f.render(f'={a.get("sum")}', True, GREEN)
                    self.screen.blit(ts, (r.centerx - 20, r.centery - 8))
                else:
                    f = _font(16)
                    ts = f.render(f'{a.get("sum")}→拉', True, WARN)
                    self.screen.blit(ts, (r.centerx - 24, r.centery - 8))
        elif t == 'split':
            x0, rects = self._board_rects()
            i = a['i']
            if 0 <= i < len(rects):
                f = _font(16)
                ts = f.render('分!', True, ORANGE)
                self.screen.blit(ts, (rects[i].centerx - 14, rects[i].y - 22))
        elif t == 'produce':
            x0, rects = self._board_rects()
            j = a.get('j')
            if j is not None and 0 <= j < len(rects):
                f = _font(16)
                txt = '攻!' if a.get('attacked') else '造!'
                ts = f.render(txt, True, GREEN)
                self.screen.blit(ts, (rects[j].centerx - 14, rects[j].y - 22))
        elif t == 'roll':
            # 滚木滚动：描边推进
            acts = a.get('acts') or []
            for step in acts:
                op = step.get('op')
                if op in ('move', 'crush', 'kill'):
                    x0, rects = self._board_rects()
                    frm = step.get('from')
                    to = step.get('to')
                    if frm is not None and to is not None and 0 <= to < len(rects):
                        r = rects[to]
                        pygame.draw.rect(self.screen, (160, 160, 170), r.inflate(-14, -14), 3)
                elif op == 'dead':
                    frm = step.get('from')
                    if frm is not None:
                        x0, rects = self._board_rects()
                        if 0 <= frm < len(rects):
                            f = _font(18)
                            ts = f.render('✕', True, SIGNAL)
                            self.screen.blit(ts, (rects[frm].centerx - 10, rects[frm].centery - 12))

    def _draw_interaction(self, rects):
        # 目标高亮（移动箭头 + 攻击/吞噬描边）——画在地图上
        for a in (self.sel_actions or []):
            if a['type'] == 'move':
                tj = self._move_target_idx(a)
                if 0 <= tj < len(rects):
                    pygame.draw.circle(self.screen, GREEN, rects[tj].center, 10, 2)
            elif a['type'] in ('attack', 'devour') and 0 <= a['j'] < len(rects):
                pygame.draw.rect(self.screen, SIGNAL if a['type'] == 'attack' else GREEN, rects[a['j']], 2)

    # ── 底部行动面板（图例 + 阶段提示/选中按钮），对齐手机端 ──
    def _draw_action_panel(self, rects):
        y = BOARD_Y + CELL + 22
        # 1) 边框图例
        self._draw_legend(y)
        # 2) 阶段选择 / 阶段提示 / 选中单位按钮
        self._draw_action_zone(y + 34, rects)

    def _draw_legend(self, y):
        f = _font(15)
        fx = _font(13)
        t = f.render('边框:', True, DIM)
        self.screen.blit(t, (16, y))
        x = 16 + t.get_width() + 6
        for name, col in [('我方', SIGNAL), ('敌方', ENEMY),
                          ('移动/可点', GREEN), ('吞噬/选中', WARN)]:
            pygame.draw.rect(self.screen, col, (x, y + 3, 14, 14))
            tx = fx.render(name, True, DIM)
            self.screen.blit(tx, (x + 18, y + 2))
            x += 18 + tx.get_width() + 14

    def _draw_action_zone(self, y, rects):
        if self.anim_lock:
            return
        # 阶段选择按钮（phase 未选）
        self.phase_buttons = []
        self.action_buttons = []
        self.split_track = None
        self.split_v0 = 0
        if self.game.phase is None and self._my_turn():
            labels = [('行动 (A)', 'action', SIGNAL), ('造兵 (P)', 'produce', GREEN)]
            x = 16
            for label, ph, col in labels:
                f = _font(20)
                w = f.size(label)[0]
                r = pygame.Rect(x, y, w + 34, 36)
                pygame.draw.rect(self.screen, (26, 25, 22), r)
                pygame.draw.rect(self.screen, col, r, 2)
                self.screen.blit(f.render(label, True, col), (r.x + 17, r.y + 8))
                self.phase_buttons.append((r, {'type': 'choosePhase', 'phase': ph}))
                x += r.w + 12
            return
        # 选中单位 → 操作按钮
        if self.sel is not None and self.sel_actions:
            has = {}
            for a in self.sel_actions:
                has.setdefault(a['type'], a)
            order = [('move', '移动'), ('attack', '攻击'), ('devour', '吞噬'), ('split', '拆分')]
            x = 16
            for k, label in order:
                if k in has:
                    col = ORANGE if k == 'split' else WARN
                    f = _font(20)
                    w = f.size(label)[0]
                    r = pygame.Rect(x, y, w + 34, 36)
                    pygame.draw.rect(self.screen, (26, 25, 22), r)
                    pygame.draw.rect(self.screen, col, r, 2)
                    self.screen.blit(f.render(label, True, col), (r.x + 17, r.y + 8))
                    self.action_buttons.append((r, has[k]))
                    x += r.w + 10
            if 'split' in has:
                self.split_v0 = self.game.cells[has['split']['i']].v
                ny = y + 44
                f = _font(16)
                ts = f.render(f'拆分 {self.split_v0}：保留 {self.split_keep} → {self.split_v0 - self.split_keep} 放右侧（拖滑块/点轨道，↑↓）',
                              True, ORANGE)
                self.screen.blit(ts, (16, ny))
                track = pygame.Rect(16, ny + 30, 260, 10)
                pygame.draw.rect(self.screen, (42, 40, 36), track)
                pygame.draw.rect(self.screen, ORANGE, track, 1)
                span = max(1, self.split_v0 - 2)
                fpos = (self.split_keep - 1) / span
                hx = track.x + int(fpos * (track.w - 14))
                pygame.draw.rect(self.screen, WARN, (hx, ny + 22, 14, 26))
                self.split_track = track
            f2 = _font(15)
            py = (y + 88) if 'split' in has else (y + 44)
            tt = f2.render(f'或直接点目标格 · 剩余{self.game.points}点', True, DIM)
            self.screen.blit(tt, (16, py))
            return

    def _set_split_from_x(self, x):
        if self.split_track is None:
            return
        span = max(1, self.split_v0 - 2)
        p = (x - self.split_track.x) / max(1, self.split_track.w)
        self.split_keep = max(1, min(max(1, self.split_v0 - 1), 1 + int(p * span)))
        # 阶段提示（未选中）
        self._draw_phase_hint(y)

    def _draw_phase_hint(self, y):
        f = _font(16)
        if not self._my_turn():
            t = f.render('对手回合中…', True, DIM)
            self.screen.blit(t, (16, y))
            return
        if self.game.phase == 'produce':
            t = f.render(f'造兵阶段 · 剩 {self.game.produce_left} 次 · 点基地造兵', True, (62, 54, 40))
            self.screen.blit(t, (16, y))
        elif self.game.phase == 'action':
            t = f.render(f'行动阶段 · 剩 {self.game.points} 点：点单位选中，点目标执行', True, (62, 54, 40))
            self.screen.blit(t, (16, y))
        else:
            t = f.render('点基地造兵 · 点单位行动（点数用完自动过回合）', True, (62, 54, 40))
            self.screen.blit(t, (16, y))

    def _draw_log(self):
        # 底部战报（对齐手机端“战报”栏）
        y = 430
        ft = _font(13)
        t = ft.render('战报', True, DIM)
        self.screen.blit(t, (24, y))
        f = _font(13)
        yy = y + 20
        for line in self.log_lines:
            t = f.render(f'· {line}', True, DIM)
            self.screen.blit(t, (24, yy))
            yy += 16

    def _draw_warn(self):
        # 浮动警告（重复操作第 2 次提示），显示 3 秒淡出
        if not self.warn_msg:
            return
        elap = time.time() - self.warn_t0
        if elap > 3.2:
            self.warn_msg = None
            return
        alpha = 255 if elap < 2.5 else max(0, int(255 * (3.2 - elap) / 0.7))
        f = _font(18)
        t = f.render(self.warn_msg, True, (255, 120, 110))
        t.set_alpha(alpha)
        x = (self.w - t.get_width()) // 2
        pygame.draw.rect(self.screen, (30, 12, 12), (x - 16, 118, t.get_width() + 32, t.get_height() + 12),
                         border_radius=6)
        pygame.draw.rect(self.screen, (140, 60, 55), (x - 16, 118, t.get_width() + 32, t.get_height() + 12), 1,
                         border_radius=6)
        self.screen.blit(t, (x, 124))

    def _draw_hint(self):
        if self.game.winner is not None:
            return
        f = _font(14)
        if self.game.phase == 'action' and self.sel is None and self._my_turn():
            t = f.render('点击己方单位或按 1-9 选择；E/Enter 结束回合', True, DIM)
            self.screen.blit(t, ((self.w - t.get_width()) // 2, self.h - 40))

    # ═══ 结算统计页 ═══
    def _build_over_panel(self):
        w = self.game.winner
        stats = self.game.stats
        self.over_panel = {
            'winner': w,
            'turnCount': self.game.turn_count,
            'stats': stats,
            'btn': None,
        }
        self._over_t0 = time.time()

    def _over_sub_reason(self):
        """从对局 log 推导判负原因（重复操作/死局/只剩滚木/掉线），无则空串（默认数字和归零）。"""
        if not self.game.log:
            return ''
        last = self.game.log[-1]
        if '重复完全相同操作三次' in last:
            return '重复完全相同操作三次（循环），判负'
        if '无任何可执行行动' in last:
            return '无任何可执行行动，判负'
        if '只剩滚木' in last:
            return '只剩滚木，无法行动，判负'
        if '掉线' in last:
            return last
        return ''

    def _draw_over(self):
        elap = time.time() - self._over_t0
        # 遮罩淡入
        ma = min(200, int(200 * elap / 0.4)) if elap < 0.4 else 200
        ov = pygame.Surface((self.w, self.h), pygame.SRCALPHA)
        ov.fill((10, 10, 12, ma))
        self.screen.blit(ov, (0, 0))
        p = self.over_panel
        w = p['winner']
        p0 = self.player_name if self.ai is None else self.player_name
        p1 = self.ai_level_label or '玩家2'
        win_name = p0 if w == 0 else p1
        col = WARN if w == 0 else SIGNAL
        # 标题缩放淡入
        f = _font(48)
        title = f.render(f'{win_name} 获胜！', True, col)
        if elap < 0.6:
            pp = max(0.0, elap / 0.6)
            scale = 0.7 + 0.3 * pp
            talpha = int(255 * pp)
        else:
            scale, talpha = 1.0, 255
        tw, th = title.get_size()
        ts = pygame.transform.smoothscale(title, (max(1, int(tw * scale)), max(1, int(th * scale))))
        ts.set_alpha(talpha)
        self.screen.blit(ts, ((self.w - tw * scale) // 2, 120))
        # 副文本
        if elap > 0.3:
            sa = min(255, int(255 * (elap - 0.3) / 0.4))
            fs = _font(18)
            reason = self._over_sub_reason()
            sub = fs.render(reason or f'{win_name} 把对手的数字减到了零', True, DIM)
            sub.set_alpha(sa)
            self.screen.blit(sub, ((self.w - sub.get_width()) // 2, 190))
        # 统计（逐行淡入）
        stats = p['stats']
        f2, f3 = _font(20), _font(16)
        rows = [
            ('回合数', str(p['turnCount'])),
            ('击杀', f"{stats['kills'][0]}  vs  {stats['kills'][1]}"),
            ('损失', f"{stats['losses'][0]}  vs  {stats['losses'][1]}"),
            ('造兵', f"{stats['produce'][0]}  vs  {stats['produce'][1]}"),
        ]
        y = 250
        for row_i, (k, vv) in enumerate(rows):
            if elap < 0.6 + row_i * 0.15:
                break
            t1 = f2.render(k, True, PAPER)
            t2 = f3.render(vv, True, DIM)
            self.screen.blit(t1, ((self.w - t1.get_width()) // 2 - 80, y))
            self.screen.blit(t2, ((self.w - t2.get_width()) // 2 + 90, y + 3))
            y += 40
        # 返回按钮（动画后出现）
        if elap > 1.6:
            f4 = _font(20)
            btn = pygame.Rect((self.w - 180) // 2, y + 30, 180, 46)
            pygame.draw.rect(self.screen, (26, 25, 22), btn)
            pygame.draw.rect(self.screen, SIGNAL, btn, 2)
            bt = f4.render('返回主菜单 (ESC)', True, PAPER)
            self.screen.blit(bt, (btn.centerx - bt.get_width() // 2, btn.centery - bt.get_height() // 2))
            p['btn'] = btn
        else:
            p['btn'] = None

    # ═══ 设置弹窗（音量）═══
    def _open_settings(self):
        # 简单音量调节：BGM/语音/音效 三个滑块（用 ↑↓ 选择，←→ 调节）
        items = [
            ('BGM 音量', 'bgm', self.audio.bgm_vol if self.audio else 0.5),
            ('语音音量', 'voice', self.audio.voice_vol if self.audio else 1.0),
            ('音效音量', 'sfx', self.audio.sfx_vol if self.audio else 0.35),
        ]
        sel_i = 0
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
                        sel_i = (sel_i - 1) % len(items)
                    elif e.key == pygame.K_DOWN:
                        sel_i = (sel_i + 1) % len(items)
                    elif e.key == pygame.K_LEFT:
                        items[sel_i][2] = max(0.0, items[sel_i][2] - 0.05)
                    elif e.key == pygame.K_RIGHT:
                        items[sel_i][2] = min(1.0, items[sel_i][2] + 0.05)
                    elif e.key in (pygame.K_RETURN, pygame.K_SPACE):
                        done = True
                elif e.type == pygame.MOUSEBUTTONDOWN:
                    for i, (label, key, val) in enumerate(items):
                        pass
            # 应用
            if self.audio:
                self.audio.bgm_vol = items[0][2]
                self.audio.voice_vol = items[1][2]
                self.audio.sfx_vol = items[2][2]
                self.audio.play_bgm('battle', asset_dir=self._asset_dir())
            # 画
            self.screen.fill(INK)
            f = _font(26)
            t = f.render('设置（↑↓选择  ←→调节  ESC返回）', True, WARN)
            self.screen.blit(t, ((self.w - t.get_width()) // 2, 120))
            f2 = _font(22)
            y = 200
            for i, (label, key, val) in enumerate(items):
                col = SIGNAL if i == sel_i else PAPER
                t1 = f2.render(f'{label}: {int(val * 100)}%', True, col)
                self.screen.blit(t1, ((self.w - t1.get_width()) // 2, y))
                y += 48
            pygame.display.flip()
            self.clock.tick(30)
