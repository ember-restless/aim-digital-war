#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIM 数字大战 · 新手教程 9 章封面生成器 v2
输出：1920x1080 PNG（B 站封面尺寸）
v2：人物部分只保留立绘 + 旁边对应数字，去掉相框/投影/公式/英文花字等装饰
"""
import os
from PIL import Image, ImageDraw, ImageFont

ASSETS = '/root/aim/client/assets/art/default'
OUTDIR = '/root/aim/covers'
FONT_CN = '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc'
FONT_PX = '/root/aim/client/assets/fonts/aim_pixel.ttf'
LOGO = Image.open('/root/aim/client/assets/images/logo.png').convert('RGBA')

W, H = 1920, 1080

C_PAPER   = (255, 245, 220)  # #FFF5DC
C_ORANGE  = (255, 211, 106)  # #FFD36A
C_RED     = (255, 78, 53)    # #FF4E35
C_DIM     = (216, 207, 184)

def cn(size):
    return ImageFont.truetype(FONT_CN, size)

def px(size):
    return ImageFont.truetype(FONT_PX, size)

def load_unit(n):
    return Image.open(f'{ASSETS}/units/{n}.png').convert('RGB')

def load_portrait(n):
    return Image.open(f'{ASSETS}/portraits/{n}.png').convert('RGBA')

def upscale(im, s):
    return im.resize((im.width * s, im.height * s), Image.NEAREST)

def draw_bg(img):
    bg = Image.open(f'{ASSETS}/ui/bg.png').convert('RGB')
    bg = bg.resize((W, H), Image.NEAREST)
    grad = Image.new('L', (W, H), 0)
    gd = ImageDraw.Draw(grad)
    span = int(W * 0.55)
    for x in range(span):
        gd.line([(x, 0), (x, H)], fill=int(150 * (1 - x / span)))
    black = Image.new('RGB', (W, H), (0, 0, 0))
    img.paste(Image.composite(black, bg, grad), (0, 0))
    grad2 = Image.new('L', (W, H), 0)
    gd2 = ImageDraw.Draw(grad2)
    for x in range(int(W * 0.5), W):
        gd2.line([(x, 0), (x, H)], fill=int(70 * (x - W * 0.5) / (W * 0.5)))
    img.paste(Image.composite(black, img, grad2), (0, 0))

def draw_logo(img, d):
    logo = upscale(LOGO, 2)
    img.paste(logo, (56, 34), logo)
    # AIM 用像素字体，中文部分单独用中文字体（避免像素字体渲染中文变方块）
    x = 396
    d.text((x, 62), 'AIM', font=px(48), fill=C_PAPER)
    x += d.textlength('AIM', font=px(48)) + 26
    d.text((x, 58), '数字大战', font=cn(50), fill=C_PAPER)
    d.text((400, 126), '新手教程 · 九章全解', font=cn(26), fill=C_DIM)

def draw_ep_tag(img, d, idx):
    tag_w, tag_h = 320, 96
    x0, y0 = W - tag_w - 60, 44
    d.rounded_rectangle([x0, y0, x0 + tag_w, y0 + tag_h], radius=8, fill=C_RED)
    d.rounded_rectangle([x0 + 4, y0 + 4, x0 + tag_w - 4, y0 + tag_h - 4], radius=6,
                        outline=(255, 130, 100), width=2)
    d.text((x0 + 22, y0 + 20), f'EP.{idx:02d}', font=px(44), fill=(255, 255, 255))
    d.text((x0 + 22, y0 + 62), f'第 {idx} 集 / 共 9 集', font=cn(24), fill=(255, 220, 210))

def draw_title(img, d, cfg, idx):
    x = 92
    d.text((x, 300), f"CHAPTER {idx:02d} · {cfg['en']}", font=px(32), fill=C_ORANGE)
    t = cfg['title']
    f = cn(104)
    d.text((x + 5, 385 + 5), t, font=f, fill=(0, 0, 0))
    d.text((x, 385), t, font=f, fill=C_PAPER, stroke_width=6, stroke_fill=(0, 0, 0))
    d.rectangle([x, 560, x + 420, 566], fill=C_ORANGE)
    d.rectangle([x + 428, 555, x + 448, 571], fill=C_RED)
    d.text((x, 596), cfg['sub'], font=cn(36), fill=C_DIM)

def draw_progress(img, d, idx):
    total = 9
    n = 40
    gap = 16
    x0 = 92
    y0 = 1012
    for i in range(total):
        x = x0 + i * (n + gap)
        if i == idx - 1:
            d.rectangle([x, y0, x + n, y0 + n], fill=C_ORANGE)
            d.rectangle([x + 6, y0 + 6, x + n - 6, y0 + n - 6], fill=C_RED)
        else:
            d.rectangle([x, y0, x + n, y0 + n], fill=(58, 55, 48))
            d.rectangle([x + 6, y0 + 6, x + n - 6, y0 + n - 6], fill=(28, 27, 24))
    d.text((x0 + total * (n + gap) + 12, y0 + 4), f'{idx} / {total}', font=px(30), fill=C_DIM)

# ── 人物区：立绘 + 旁边对应数字，干干净净 ──
def draw_portrait(img, name, pos=(1360, 230), scale=3):
    """立绘直接贴，无相框无投影；前指挥官是黑剪影，垫米白底衬才看得见"""
    p = upscale(load_portrait(name), scale)   # 480x639
    x, y = pos
    if name == 'excommander':
        pad = 10
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([x - pad, y - pad, x + p.width + pad, y + p.height + pad],
                            radius=14, fill=(246, 232, 202))  # #F6E8CA
        d.rounded_rectangle([x - pad, y - pad, x + p.width + pad, y + p.height + pad],
                            radius=14, outline=(58, 54, 47), width=3)
    img.paste(p, (x, y), p)

def draw_unit(img, n, pos, size=256):
    """单位数字图直接贴，无边框"""
    u = upscale(load_unit(n), size // 32)
    img.paste(u, pos)

def render(cfg, idx):
    img = Image.new('RGB', (W, H), (17, 17, 15))
    draw_bg(img)
    d = ImageDraw.Draw(img)
    draw_logo(img, d)
    draw_ep_tag(img, d, idx)
    draw_title(img, d, cfg, idx)
    draw_progress(img, d, idx)

    if idx == 7:
        # 滚木：没有人物立绘，只放一个数字 6
        draw_unit(img, '6', (1370, 300), size=352)
    elif idx == 9:
        # 终章 动员：前指挥官立绘 + 全员数字横排
        draw_portrait(img, 'excommander', pos=(1400, 250), scale=3)
        units = ['1', '2', '3', '4', '5', '7']
        s = 128
        gap = 18
        total_w = len(units) * s + (len(units) - 1) * gap
        x = W - total_w - 60
        for n in units:
            draw_unit(img, n, (x, 100), size=s)
            x += s + gap
    else:
        # 常规：立绘 + 旁边对应数字（第一章前指挥官无数字，只放立绘）
        draw_portrait(img, cfg['portrait'], pos=(1360, 230), scale=3)
        if cfg['num'] is not None:
            draw_unit(img, cfg['num'], (1050, 300), size=256)

    os.makedirs(OUTDIR, exist_ok=True)
    out = os.path.join(OUTDIR, f'aim_cover_{idx:02d}.png')
    img.save(out)
    print(f'saved {out}')

CHAPTERS = [
    dict(title='造兵',       en='RECRUIT', sub='兵营前的第一课：数字就是兵力', portrait='excommander', num=None),
    dict(title='攻击与胜利', en='VICTORY', sub='打光对面的数字，战争才会结束', portrait='primus',      num='1'),
    dict(title='移动',       en='ADVANCE', sub='只能前进，战场没有回头路',     portrait='secundus',   num='2'),
    dict(title='攻击',       en='ATTACK',  sub='射程与溢出——打过头会砸出桥',   portrait='tertius',    num='3'),
    dict(title='拆分',       en='SPLIT',   sub='过不去的桥，就拆成两个轻的',     portrait='quintus',    num='5'),
    dict(title='吞噬',       en='DEVOUR',  sub='合二为一：吞出基地，吞出指挥',   portrait='quartus',    num='4'),
    dict(title='滚木',       en='ROLLER',  sub='那个老兵留下的位置，碾过一切',   portrait=None,         num='6'),
    dict(title='盾卫与独木桥', en='SHIELD', sub='轻的上桥，重的桥塌人亡',         portrait='septimus',   num='7'),
    dict(title='终章 · 动员', en='LEGIO',  sub='军团集结完毕，只等您一声令下',   portrait='excommander', num=None),
]

def build_sheet():
    """9 张缩略图拼成 3x3 总览"""
    imgs = [Image.open(f'{OUTDIR}/aim_cover_{i:02d}.png').resize((480, 270), Image.LANCZOS) for i in range(1, 10)]
    sheet = Image.new('RGB', (1440, 810), (17, 17, 15))
    for i, im in enumerate(imgs):
        sheet.paste(im, ((i % 3) * 480, (i // 3) * 270))
    sheet.save(f'{OUTDIR}/contact_sheet.png')
    print('contact_sheet rebuilt')

if __name__ == '__main__':
    for i, cfg in enumerate(CHAPTERS, 1):
        render(cfg, i)
    build_sheet()
    print('done')
