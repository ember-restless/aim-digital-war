# 计算器液晶屏渲染（重做：90% 贴近牢大截图）
# 满幅灰绿液晶屏 + 顶部一排暗指示符 + 一整排暗 0 残影 + 亮的数字
# 色调：背光弱、对比低（截图那种淡淡的感觉）
import os

import pygame

_FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fonts', 'wqy-microhei.ttc')


def CJK(size):
    try:
        return pygame.font.Font(_FONT_PATH, size)
    except Exception:
        return pygame.font.Font(None, size)


# ── 液晶屏色板（对齐截图：灰绿、淡淡、低对比）──
SCR_BG_TOP = (188, 197, 178)      # 屏底色（上）
SCR_BG_BOT = (168, 179, 158)      # 屏底色（下，稍深）
OFF_SEG = (154, 163, 143)         # 未激活段残影（比底稍深，很淡）
OFF_SEG2 = (146, 155, 135)        # 残影略深（暗 0 用）
ON_SEG = (30, 36, 32)             # 激活段（深墨绿黑）
ON_GREEN = (66, 82, 68)           # 第二玩家段色（略偏绿，仍很"液晶"）
HINT = (104, 114, 98)            # 顶部指示符色（暗）
CASE = (38, 36, 32)               # 外壳窄边

# 7 段数码管：数字 → 段集合
SEG = {
    '0': 'abcdef', '1': 'bc', '2': 'abdeg', '3': 'abcdg', '4': 'bcfg',
    '5': 'acdfg', '6': 'acdefg', '7': 'abc', '8': 'abcdefg', '9': 'abcdfg',
    '-': 'g', '.': '',  # '.' 特殊处理
}


def _seg_points(ch, x, y, w, h):
    t = w * 0.055
    left = x + t
    right = x + w - t
    top = y + t
    mid = y + h * 0.5
    bot = y + h - t
    m = w * 0.13
    lx = left + m
    rx = right - m
    return {
        'a': (left, top, right, top),
        'g': (left, mid, right, mid),
        'd': (left, bot, right, bot),
        'f': (lx, top, lx, mid),
        'b': (rx, top, rx, mid),
        'e': (lx, mid, lx, bot),
        'c': (rx, mid, rx, bot),
    }.get(ch)


def _seg_rects(x, y, w, h, th):
    """7 段数码管每段矩形（(x,y,w,h)，方正像素风）。th = 笔画半厚。"""
    t = th
    cw = w - 2 * t     # 横段宽（左右留白）
    return {
        'a': (x + t, y, cw, 2 * t),                       # 顶横
        'g': (x + t, y + h * 0.5 - t, cw, 2 * t),         # 中横
        'd': (x + t, y + h - 2 * t, cw, 2 * t),           # 底横
        'f': (x, y + t, 2 * t, h * 0.5 - 2 * t),          # 左上竖
        'b': (x + w - 2 * t, y + t, 2 * t, h * 0.5 - 2 * t),  # 右上竖
        'e': (x, y + h * 0.5 + t, 2 * t, h * 0.5 - 2 * t),    # 左下竖
        'c': (x + w - 2 * t, y + h * 0.5 + t, 2 * t, h * 0.5 - 2 * t),  # 右下竖
    }


def draw_digit(surf, x, y, w, h, ch, color=ON_SEG, thickness=None, off_color=None, off_only=False):
    """画 7 段数码管（方正像素风：粗矩形段，标准计算器电子数字）。"""
    if thickness is None:
        thickness = max(3, int(w * 0.09))
    segs = SEG.get(ch, '')
    on_parts = set(segs)
    # 先画残影（该数字应有的段，淡色——如 0 只有 abcdef，无中横）
    if off_color is not None:
        for k, r in _seg_rects(x, y, w, h, thickness).items():
            if k in on_parts:
                pygame.draw.rect(surf, off_color, r)
    if off_only:
        return
    # 再叠激活段
    for k, r in _seg_rects(x, y, w, h, thickness).items():
        if k in on_parts:
            pygame.draw.rect(surf, color, r)


_BG_CACHE = None


def make_lcd_surface(size):
    """满幅灰绿液晶屏（渐变 + 纹理 + 四角暗角），静态缓存只生成一次，每帧 copy 复用。"""
    global _BG_CACHE
    if _BG_CACHE is not None and _BG_CACHE.get_size() == size:
        return _BG_CACHE.copy()
    w, h = size
    s = pygame.Surface((w, h))
    for yy in range(h):
        f = yy / h
        c = [int(SCR_BG_TOP[i] + (SCR_BG_BOT[i] - SCR_BG_TOP[i]) * f) for i in range(3)]
        pygame.draw.line(s, c, (0, yy), (w, yy))
    for xx in range(0, w, 3):
        pygame.draw.line(s, (178, 186, 168), (xx, 0), (xx, h), 1)
    # 四角暗角：生成小图再平滑放大（速度快，边缘略暗）
    vw, vh = max(8, w // 16), max(8, h // 16)
    vg = pygame.Surface((vw, vh), pygame.SRCALPHA)
    cx, cy = vw / 2, vh / 2
    for yy in range(vh):
        for xx in range(vw):
            d = ((xx - cx) / cx) ** 2 + ((yy - cy) / cy) ** 2
            if d > 1.3:
                k = min(150, int((d - 1.3) * 90))
                vg.set_at((xx, yy), (0, 0, 0, k))
    vg = pygame.transform.smoothscale(vg, (w, h))
    s.blit(vg, (0, 0))
    return s.copy()


def draw_top_indicators(surf, left, right):
    """顶部一排暗指示符（还原截图：M / 长串符号 / D 框）。"""
    y = 40
    f = CJK(26)
    # 左 M
    if left:
        t = f.render(left, True, HINT)
        surf.blit(t, (90, y))
    # 右 D（方框）
    if right:
        t = f.render(right, True, HINT)
        surf.blit(t, (surf.get_width() - 130, y))
    # 中间一长串小符号（仿 Casio 顶栏指示）
    glyphs = 'M   D   21^  S  1/x  π  ■  ←  →  %  √  x!'
    t2 = CJK(22).render(glyphs, True, HINT)
    surf.blit(t2, (surf.get_width() * 0.22, y + 6))
    # 分隔线
    pygame.draw.line(surf, (178, 186, 168), (60, y + 52), (surf.get_width() - 60, y + 52), 1)


def draw_ground(surf, width, y):
    """液晶屏中部一条暗横线排（截图里那排段码/分隔）。"""
    for i in range(width):
        x = 70 + i * (surf.get_width() - 140) // max(1, width - 1)
        pygame.draw.line(surf, (168, 176, 158), (x, y), (x + 40, y), 2)
