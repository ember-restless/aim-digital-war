#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIM 数字大战 · 友谊赛 封面 —— 与教程总封面（aim_cover_main）同款干净模板
大标题 + 数字 1~9 一行 + 副标题，1920x1080，无人物
"""
import os, shutil
from PIL import Image, ImageDraw, ImageFont

ASSETS = '/root/aim/client/assets/art/default'
OUTDIR = '/root/aim/covers'
FONT_CN = '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc'
FONT_PX = '/root/aim/client/assets/fonts/aim_pixel.ttf'
LOGO = Image.open('/root/aim/client/assets/images/logo.png').convert('RGBA')

W, H = 1920, 1080
C_PAPER  = (255, 245, 220)
C_ORANGE = (255, 211, 106)
C_RED    = (255, 78, 53)
C_DIM    = (216, 207, 184)

def cn(s): return ImageFont.truetype(FONT_CN, s)
def px(s): return ImageFont.truetype(FONT_PX, s)
def load_unit(n): return Image.open(f'{ASSETS}/units/{n}.png').convert('RGB')
def upscale(im, s): return im.resize((int(im.width * s), int(im.height * s)), Image.NEAREST)

def draw_bg(img):
    bg = Image.open(f'{ASSETS}/ui/bg.png').convert('RGB').resize((W, H), Image.NEAREST)
    grad = Image.new('L', (W, H), 0)
    gd = ImageDraw.Draw(grad)
    span = int(W * 0.5)
    for x in range(span):
        gd.line([(x, 0), (x, H)], fill=int(150 * (1 - x / span)))
    black = Image.new('RGB', (W, H), (0, 0, 0))
    img.paste(Image.composite(black, bg, grad), (0, 0))

img = Image.new('RGB', (W, H), (17, 17, 15))
draw_bg(img)
d = ImageDraw.Draw(img)

# ── 左上 logo ──
logo = upscale(LOGO, 2)
img.paste(logo, (56, 34), logo)
x = 396
d.text((x, 62), 'AIM', font=px(48), fill=C_PAPER)
x += d.textlength('AIM', font=px(48)) + 26
d.text((x, 58), '数字大战', font=cn(50), fill=C_PAPER)

# ── 右上红标：友谊对战 ──
tag_w, tag_h = 300, 88
x0, y0 = W - tag_w - 60, 48
d.rounded_rectangle([x0, y0, x0 + tag_w, y0 + tag_h], radius=8, fill=C_RED)
d.rounded_rectangle([x0 + 4, y0 + 4, x0 + tag_w - 4, y0 + tag_h - 4], radius=6,
                    outline=(255, 130, 100), width=2)
d.text((x0 + 20, y0 + 20), '友谊对战', font=cn(34), fill=(255, 255, 255))

# ── 大标题 ──
t = '友谊赛'
f = cn(140)
tw = d.textlength(t, font=f)
tx = (W - tw) / 2
d.text((tx + 6, 246 + 6), t, font=f, fill=(0, 0, 0))
d.text((tx, 240), t, font=f, fill=C_PAPER, stroke_width=8, stroke_fill=(0, 0, 0))

# ── 分隔线 + 副标题 ──
cx = W / 2
d.rectangle([cx - 260, 436, cx + 260, 442], fill=C_ORANGE)
sub = '以赛代练 · 战个痛快'
f2 = cn(40)
sw = d.textlength(sub, font=f2)
d.text(((W - sw) / 2, 466), sub, font=f2, fill=C_ORANGE)

# ── 数字 1~9 一行 ──
digits = ['1', '2', '3', '4', '5', '6', '7', '8', '9']
s = 128
gap = 24
total = len(digits) * s + (len(digits) - 1) * gap
x0 = (W - total) // 2
y0 = 600
for n in digits:
    u = upscale(load_unit(n), s // 32)
    img.paste(u, (x0, y0))
    x0 += s + gap

# ── 底部一行小字 ──
foot = '来战一场 · 胜负皆欢'
f3 = cn(30)
fw = d.textlength(foot, font=f3)
d.text(((W - fw) / 2, 820), foot, font=f3, fill=C_DIM)

out = os.path.join(OUTDIR, 'aim_cover_friendly.png')
img.save(out)
print('saved', out)

# 同步到服务器下载目录（可直接点击下载）
dst_dir = '/root/aim/server/public/downloads/covers_v3'
os.makedirs(dst_dir, exist_ok=True)
shutil.copy(out, os.path.join(dst_dir, 'aim_cover_friendly.png'))
print('copied to', dst_dir)
