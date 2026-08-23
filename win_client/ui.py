# 像素 UI 组件：按钮、面板、文本
# 复古棋盘风配色：米黄 / 咖啡 / 木色
import os
import pygame

COL = {
    'bg': (17, 17, 15),           # ink 近黑
    'bg_hi': (26, 25, 22),        # 卡片深底
    'panel': (255, 245, 220),     # paper 米白
    'panel_dim': (240, 228, 200),
    'border': (90, 85, 76),       # 灰棕
    'border_hi': (150, 145, 132),
    'text': (62, 54, 42),         # 纸上深字
    'text_dim': (119, 115, 107),  # 灰棕
    'text_on_dark': (255, 245, 220),  # 深底米白
    'accent': (255, 78, 53),      # signal 橙红
    'accent_dark': (177, 39, 24), # 深红
    'enemy': (177, 39, 24),       # 敌方深红
    'atk': (255, 107, 82),        # 可攻击目标高亮（亮橙红）
    'warn': (255, 211, 106),      # 橙黄
    'green': (97, 211, 158),      # 亮绿
    'cell_even': (30, 29, 26),    # 深底棋盘
    'cell_odd': (24, 23, 20),
    'btn': (255, 78, 53),         # 橙红主按钮
    'btn_hi': (255, 120, 90),
    'btn_dark': (40, 39, 35),     # 深灰次按钮
    'wood': (150, 110, 66),
    'wood_dark': (100, 72, 42),
}

FONT_CACHE = {}
_FONT_PATH = None


def _find_font():
    """找中文字体：优先打包字体，其次系统字体"""
    global _FONT_PATH
    if _FONT_PATH is not None:
        return _FONT_PATH or None
    base = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(base, 'fonts', 'wqy-microhei.ttc'),
        'C:/Windows/Fonts/msyh.ttc',
        'C:/Windows/Fonts/msyh.ttf',
        'C:/Windows/Fonts/simhei.ttf',
        'C:/Windows/Fonts/simsun.ttc',
        '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
        '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
        '/System/Library/Fonts/PingFang.ttc',
        '/System/Library/Fonts/STHeiti Light.ttc',
    ]
    for p in candidates:
        if os.path.exists(p):
            _FONT_PATH = p
            return p
    _FONT_PATH = ''
    return None


def font(size, bold=False):
    key = (size, bold)
    if key not in FONT_CACHE:
        fp = _find_font()
        if fp:
            try:
                FONT_CACHE[key] = pygame.font.Font(fp, size)
            except Exception:
                FONT_CACHE[key] = pygame.font.Font(None, size)
        else:
            FONT_CACHE[key] = pygame.font.Font(None, size)
    return FONT_CACHE[key]


def draw_text(surf, text, x, y, color=COL['text'], size=20, align='left'):
    f = font(size)
    img = f.render(text, True, color)
    if align == 'center':
        x -= img.get_width() // 2
    elif align == 'right':
        x -= img.get_width()
    surf.blit(img, (x, y))
    return img.get_width()


class Button:
    def __init__(self, rect, text, cb=None, color=None, size=18, on_dark=False):
        self.rect = pygame.Rect(rect)
        self.text = text
        self.cb = cb
        self.color = color or COL['btn']
        self.size = size
        self.on_dark = on_dark
        self.hover = False
        self.disabled = False

    def draw(self, surf):
        if self.disabled:
            c = (108, 90, 62)
        elif self.hover:
            c = COL['btn_hi']
        else:
            c = self.color
        # 木质按钮：底 + 边框 + 顶部高光 + 底部阴影
        pygame.draw.rect(surf, c, self.rect)
        pygame.draw.rect(surf, COL['border'], self.rect, 2)
        pygame.draw.line(surf, (min(c[0] + 34, 255), min(c[1] + 30, 255), min(c[2] + 24, 255)),
                         (self.rect.x + 2, self.rect.y + 2), (self.rect.right - 3, self.rect.y + 2))
        pygame.draw.line(surf, COL['wood_dark'],
                         (self.rect.x + 2, self.rect.bottom - 2), (self.rect.right - 3, self.rect.bottom - 2))
        tc = COL['text_dim'] if self.disabled else (COL['text_on_dark'] if self.on_dark else COL['text'])
        draw_text(surf, self.text, self.rect.centerx, self.rect.centery - self.size // 2 + 1,
                  color=tc, size=self.size, align='center')

    def handle(self, event):
        if self.disabled or not self.cb:
            return False
        if event.type == pygame.MOUSEMOTION:
            self.hover = self.rect.collidepoint(event.pos)
        if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            if self.rect.collidepoint(event.pos):
                self.cb()
                return True
        return False


def panel(surf, rect, title=None):
    """复古木面板：米黄底 + 咖啡双边框 + 标题"""
    pygame.draw.rect(surf, COL['panel'], rect)
    pygame.draw.rect(surf, COL['border_hi'], rect, 2)
    pygame.draw.rect(surf, COL['border'], (rect.x + 4, rect.y + 4, rect.w - 8, rect.h - 8), 1)
    # 顶部标题条
    pygame.draw.line(surf, COL['wood'], (rect.x + 8, rect.y + 26), (rect.right - 8, rect.y + 26), 1)
    if title:
        draw_text(surf, title, rect.x + 12, rect.y + 7, color=COL['accent_dark'], size=16)
