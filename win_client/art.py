# AIM 资源包加载（Minecraft 式：art/<包名>/units|ui/map 下的图片）
import json
import os

import pygame

# 资源包目录（Win 端：exe 旁边的 art/）
ART_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'art')


def list_packs():
    """扫描 art/ 下所有资源包（含 pack.json 的目录）"""
    packs = []
    if not os.path.isdir(ART_DIR):
        return packs
    for name in sorted(os.listdir(ART_DIR)):
        d = os.path.join(ART_DIR, name)
        if os.path.isdir(d):
            meta = {'name': name, 'author': '?', 'version': '1.0'}
            pj = os.path.join(d, 'pack.json')
            if os.path.exists(pj):
                try:
                    meta.update(json.load(open(pj, encoding='utf-8')))
                except Exception:
                    pass
            packs.append({'dir': d, 'id': name, **meta})
    return packs


class Pack:
    """一个加载好的资源包"""

    def __init__(self, pack_dir):
        self.dir = pack_dir
        self.units = {}   # key -> Surface (32x32)
        self.ui = {}      # key -> Surface
        self._load_units()
        self._load_ui()

    def _load(self, sub, key, size=None):
        p = os.path.join(self.dir, sub, key + '.png')
        if not os.path.exists(p):
            return None
        img = pygame.image.load(p).convert_alpha()
        if size:
            img = pygame.transform.scale(img, size)
        return img

    def _load_units(self):
        # 数字包：0-9 + 独木桥；兼容旧版 _e 敌方图（有则加载，没有就用同一张）
        for n in range(10):
            s = self._load('units', str(n))
            if s:
                self.units[str(n)] = s
        for n in range(1, 10):
            s = self._load('units', f'{n}_e')
            if s:
                self.units[f'{n}_e'] = s
        s = self._load('units', 'dash')
        if s:
            self.units['dash'] = s

    def _load_ui(self):
        for key in ['bg', 'panel', 'button']:
            s = self._load('ui', key)
            if s:
                self.ui[key] = s

    def unit(self, v, owner=0, on_bridge=False):
        """取单位图标（默认数字包不分敌我，敌我靠边框色区分）"""
        if on_bridge:
            return self.units.get('dash')
        if v == 0:
            return self.units.get('0')
        key = f'{v}_e' if owner == 1 and f'{v}_e' in self.units else str(v)
        return self.units.get(key)

    def bridge(self):
        return self.units.get('dash')
