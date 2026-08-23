# AIM 数字大战 · 计算器液晶屏导演版（结构对齐牢大截图）
# 超宽计算器液晶屏：顶栏(M/D) + 输入栏(对局在此玩，光标可编辑) + 输出栏(固定显示 0.)
import os
import subprocess
import sys

import pygame

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lcd import ON_SEG, ON_GREEN, CASE, draw_digit, make_lcd_surface

W, H = 1920, 1080
FPS = 30
FRAMES_DIR = '/tmp/aim_casio_frames'
OUT_MP4 = '/root/aim/casio/aim_casio.mp4'
COLS = 12  # 输入栏 1×12 数字位

# 超宽计算器（外壳 + 屏），居中
SHELL = pygame.Rect((W - 1760) // 2, (H - 640) // 2, 1760, 640)
SCREEN = SHELL.inflate(-40, -40)  # 屏内
TOP_H = 74
INPUT_TOP = TOP_H + 24
INPUT_H = 190
DIV_Y = INPUT_TOP + INPUT_H + 12
OUT_TOP = DIV_Y + 16
OUT_H = SCREEN.bottom - OUT_TOP - 30

STEPS = [
    '800008', '810008', '810018', '6210018', '6210108',
    '0-4-55108', '0-4-54108', '0-4-5508', '0-4-55071',
    '0-0455071', '0-0455701', '0-0455201', '0-0453201',
    '0-045501', '0-045510', '0-04560',
]


def _lcs(a, b):
    m, n = len(a), len(b)
    dp = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(m - 1, -1, -1):
        for j in range(n - 1, -1, -1):
            dp[i][j] = dp[i + 1][j + 1] + 1 if a[i] == b[j] else max(dp[i + 1][j], dp[i][j + 1])
    return dp


def diff(a, b):
    dp = _lcs(a, b)
    ops = []
    i = j = 0
    while i < len(a) and j < len(b):
        if a[i] == b[j]:
            ops.append(('eq', i, j)); i += 1; j += 1
        elif dp[i + 1][j] >= dp[i][j + 1]:
            ops.append(('del', i)); i += 1
        else:
            ops.append(('ins', j)); j += 1
    while i < len(a):
        ops.append(('del', i)); i += 1
    while j < len(b):
        ops.append(('ins', j)); j += 1
    return ops


class LcdBoard:
    """计算器液晶屏：顶栏 + 输入栏(对局) + 输出栏(0.)。"""

    def __init__(self, screen, cells, cursor=0, cursor_f=None):
        self.screen = screen
        self.cur = list(cells)
        self.cursor = cursor      # 目标格（int）
        self.cursor_f = cursor_f if cursor_f is not None else float(cursor)  # 实际显示位置（float，可插值）

    def _cell_rect(self, i):
        # 格宽固定 12 位（像计算器显示位，数字大小恒定）；只画地图内的格，地图外空
        n = COLS
        gap = 16
        pad_x = SCREEN.x + 60
        avail = SCREEN.w - 120
        cw = (avail - gap * (n - 1)) / n
        return pygame.Rect(int(pad_x + i * (cw + gap)), SCREEN.y + INPUT_TOP, int(cw), INPUT_H)

    def draw(self, surf, blink=True):
        # 背景壳 + 屏
        surf.fill((20, 19, 17))
        pygame.draw.rect(surf, (52, 50, 46), SHELL, border_radius=14)
        pygame.draw.rect(surf, (30, 29, 27), SHELL, 4, border_radius=14)
        lcd = make_lcd_surface((SCREEN.w, SCREEN.h))
        surf.blit(lcd, SCREEN.topleft)
        # 顶栏 M/D
        f = pygame.font.Font(None, 30)
        surf.blit(f.render('M', True, (90, 100, 88)), (SCREEN.x + 40, SCREEN.y + 22))
        surf.blit(f.render('D', True, (90, 100, 88)), (SCREEN.right - 60, SCREEN.y + 22))
        pygame.draw.line(surf, (150, 158, 142), (SCREEN.x + 24, SCREEN.y + TOP_H), (SCREEN.right - 24, SCREEN.y + TOP_H), 1)
        # 输入栏：只显示地图内的格（格子数=当前战局串长度）；地图内 0 打印，其余不显示
        for i in range(len(self.cur)):
            r = self._cell_rect(i)
            ch = self.cur[i]
            if ch == '0':
                # 空格：深色 0（跟其它数字一致）
                draw_digit(surf, r.x, r.y, r.w, r.h, '0', ON_SEG,
                           thickness=max(3, int(r.w * 0.08)), off_color=None)
            elif ch == '-':
                pygame.draw.rect(surf, ON_SEG, (r.x + r.w * 0.08, r.centery - max(3, int(r.h * 0.06)),
                                                r.w * 0.84, max(6, int(r.h * 0.12))))
            else:
                draw_digit(surf, r.x, r.y, r.w, r.h, ch, ON_SEG, thickness=max(3, int(r.w * 0.09)),
                           off_color=(170, 178, 158))
        # 输入栏光标（编辑位下方亮条，直接显示在编辑位置）
        if blink and 0 <= self.cursor < len(self.cur):
            r = self._cell_rect(self.cursor)
            pygame.draw.rect(surf, (46, 56, 46), (r.x + 4, r.bottom + 8, r.w - 8, 8))
        # 分隔线
        pygame.draw.line(surf, (150, 158, 142), (SCREEN.x + 24, SCREEN.y + DIV_Y), (SCREEN.right - 24, SCREEN.y + DIV_Y), 1)
        # 输出栏：正常大小的 "0."（跟截图的输出位数一致，不占大块）
        oww, ohh = 78, OUT_H * 0.42
        out_r = pygame.Rect(int(SCREEN.right - oww - 40), int(SCREEN.y + OUT_TOP + OUT_H * 0.05), int(oww), int(ohh))
        draw_digit(surf, out_r.x, out_r.y, out_r.w, out_r.h, '0', ON_SEG,
                   thickness=max(3, int(out_r.w * 0.12)), off_color=(128, 136, 118))
        # 小数点
        pygame.draw.rect(surf, ON_SEG, (out_r.right - out_r.w * 0.2, out_r.bottom - out_r.h * 0.12,
                                        out_r.w * 0.12, out_r.h * 0.12))


def main():
    os.makedirs(FRAMES_DIR, exist_ok=True)
    for f in os.listdir(FRAMES_DIR):
        os.remove(os.path.join(FRAMES_DIR, f))
    pygame.init()
    screen = pygame.display.set_mode((W, H), pygame.HIDDEN)
    frame = 0

    def save():
        nonlocal frame
        frame += 1
        pygame.image.save(screen, os.path.join(FRAMES_DIR, 'f%05d.png' % frame))

    def render(board, blink=True):
        board.draw(screen, blink=blink)
        pygame.display.flip()
        save()

    # 开场待机
    for i in range(int(FPS * 1.5)):
        render(LcdBoard(screen, [], cursor=0), blink=(i % 30) < 18)

    pos = 0
    for rnd in range(len(STEPS)):
        cur = STEPS[rnd]
        for _ in range(int(FPS * 1.0)):
            render(LcdBoard(screen, list(cur), cursor=min(pos, len(cur))))
        if rnd == len(STEPS) - 1:
            break
        nxt = STEPS[rnd + 1]
        pos = 0
        cur_list = list(cur)
        for op in diff(cur, nxt):
            kind = op[0]
            if kind == 'eq':
                for _ in range(3):
                    render(LcdBoard(screen, cur_list, cursor=pos))
                pos += 1
            elif kind == 'ins':
                ch = nxt[op[1]]
                for _ in range(6):
                    render(LcdBoard(screen, cur_list, cursor=pos), blink=(_ % 12) < 6)
                cur_list.insert(pos, ch)
                for _ in range(6):
                    render(LcdBoard(screen, cur_list, cursor=pos))
                pos += 1
            elif kind == 'del':
                for _ in range(6):
                    render(LcdBoard(screen, cur_list, cursor=pos), blink=(_ % 12) < 6)
                cur_list.pop(pos)
                for _ in range(6):
                    render(LcdBoard(screen, cur_list, cursor=min(pos, len(cur_list))))

    for i in range(int(FPS * 3)):
        render(LcdBoard(screen, list(STEPS[-1]), cursor=len(STEPS[-1]) - 1), blink=(i % 30) < 20)

    pygame.quit()
    print('帧数:', frame)
    cmd = ['ffmpeg', '-y', '-framerate', str(FPS), '-i',
           os.path.join(FRAMES_DIR, 'f%05d.png'),
           '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', OUT_MP4]
    subprocess.run(cmd, check=True)
    print('完成:', OUT_MP4)


if __name__ == '__main__':
    main()
