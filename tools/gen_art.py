#!/usr/bin/env python3
"""AIM 默认像素资源包生成器 v2
默认包 = 普通数字（牢大要求）：0空地 / 1-9大号白色数字 / -独木桥
敌我区分交给客户端画边框颜色，资源包只提供数字本体（可随意换皮）
"""
import os
import json
from PIL import Image

SIZE = 32
OUT = os.path.join(os.path.dirname(__file__), '..', 'art', 'default')

# 5x7 像素数字点阵（0-9）
DIGITS = {
    '0': ['01110', '10001', '10011', '10101', '11001', '10001', '01110'],
    '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
    '2': ['01110', '10001', '00001', '00010', '00100', '01000', '11111'],
    '3': ['11111', '00010', '00100', '00010', '00001', '10001', '01110'],
    '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'],
    '5': ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
    '6': ['00110', '01000', '10000', '11110', '10001', '10001', '01110'],
    '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
    '8': ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
    '9': ['01110', '10001', '10001', '01111', '00001', '00010', '01100'],
}

BG = (17, 17, 15)           # ink 近黑
GROUND = (30, 29, 26)        # 棋盘格（微差）
GROUND_HI = (24, 23, 20)
WHITE = (255, 245, 220)      # paper 米白数字
DIM = (119, 115, 107)        # 灰棕


def rect(img, x0, y0, x1, y1, color):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if 0 <= x < SIZE and 0 <= y < SIZE:
                img.putpixel((x, y), color)


def draw_digit(img, d, ox, oy, color, scale=4):
    glyph = DIGITS[d]
    for gy, row in enumerate(glyph):
        for gx, ch in enumerate(row):
            if ch == '1':
                rect(img, ox + gx * scale, oy + gy * scale,
                     ox + gx * scale + scale - 1, oy + gy * scale + scale - 1, color)


def new_img():
    return Image.new('RGB', (SIZE, SIZE), BG)


def icon_ground():
    img = new_img()
    for gy in range(4):
        for gx in range(4):
            c = GROUND if (gx + gy) % 2 == 0 else GROUND_HI
            rect(img, gx * 8, gy * 8, gx * 8 + 7, gy * 8 + 7, c)
    for i in range(5):
        rect(img, i * 8, 0, i * 8, SIZE - 1, BG)
        rect(img, 0, i * 8, SIZE - 1, i * 8, BG)
    return img


def icon_number(n):
    """大号白色数字，居中 32x32（5x7 点阵放大 4 倍 = 20x28）"""
    img = new_img()
    draw_digit(img, str(n), 6, 2, WHITE)
    return img


def icon_dash():
    """独木桥：粗减号"""
    img = new_img()
    rect(img, 3, 13, 28, 18, DIM)
    rect(img, 6, 15, 25, 16, WHITE)
    return img


def main():
    os.makedirs(os.path.join(OUT, 'units'), exist_ok=True)
    os.makedirs(os.path.join(OUT, 'ui'), exist_ok=True)
    # 空地：棋盘格底 + 米白数字 0（牢大要求写0）
    ground = icon_ground()
    draw_digit(ground, '0', 6, 2, (119, 115, 107))
    ground.save(os.path.join(OUT, 'units', '0.png'))
    for n in range(1, 10):
        icon_number(n).save(os.path.join(OUT, 'units', f'{n}.png'))
    icon_dash().save(os.path.join(OUT, 'units', 'dash.png'))

    # UI 素材（复古像素风：噪点背景/面板/按钮）
    import random
    random.seed(42)
    bg = Image.new('RGB', (320, 180), BG)
    for _ in range(1400):
        x, y = random.randint(0, 319), random.randint(0, 179)
        bg.putpixel((x, y), random.choice([(20, 20, 18), (15, 15, 13), (24, 23, 21)]))
    bg.save(os.path.join(OUT, 'ui', 'bg.png'))

    panel = Image.new('RGB', (64, 64), BG)
    rect(panel, 0, 0, 63, 63, (90, 85, 76))
    rect(panel, 2, 2, 61, 61, (255, 245, 220))
    rect(panel, 4, 4, 59, 59, (246, 232, 202))
    panel.save(os.path.join(OUT, 'ui', 'panel.png'))

    btn = Image.new('RGB', (64, 32), BG)
    rect(btn, 0, 0, 63, 31, (120, 32, 24))
    rect(btn, 2, 2, 61, 29, (255, 78, 53))
    rect(btn, 2, 2, 61, 5, (255, 130, 100))
    btn.save(os.path.join(OUT, 'ui', 'button.png'))

    with open(os.path.join(OUT, 'pack.json'), 'w') as f:
        json.dump({
            'name': '经典数字',
            'author': '离离',
            'version': '2.0',
            'description': 'AIM 默认资源包：朴素大数字',
        }, f, ensure_ascii=False, indent=2)
    print('默认资源包（数字版）生成完成:', OUT)


if __name__ == '__main__':
    main()
