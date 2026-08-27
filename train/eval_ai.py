#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Python 版模型 AI（评估用）—— 与 client/lib/train/train_ai.dart 同构
- 加载 train_weights.json（MLP 53→64→64→49）
- 决策：阶段选择回退启发式（AimAi hard），已选阶段后行动用模型前向 + 合法动作 mask
- 视角归一化：我方（game.turn）恒为左方，flip 时棋盘镜像、槽位索引翻转（与训练一致）
"""
import json
import sys

import numpy as np

sys.path.insert(0, '/root/aim/pc')
from ai import AimAi

IN_DIM = 53
HIDDEN = 64
OUT = 49
MAX_CELLS = 8




class ModelAi:
    def __init__(self, weights_path, fallback_level='hard', seed=0):
        w = json.load(open(weights_path, 'r', encoding='utf-8'))
        self.w1 = np.array(w['w1'], dtype=np.float64).reshape(HIDDEN, IN_DIM)
        self.b1 = np.array(w['b1'], dtype=np.float64)
        self.w2 = np.array(w['w2'], dtype=np.float64).reshape(HIDDEN, HIDDEN)
        self.b2 = np.array(w['b2'], dtype=np.float64)
        self.wo = np.array(w['wo'], dtype=np.float64).reshape(OUT, HIDDEN)
        self.bo = np.array(w['bo'], dtype=np.float64)
        self.fallback = AimAi(fallback_level, seed=seed)

    def _forward(self, x):
        h1 = np.maximum(0, x @ self.w1.T + self.b1)
        h2 = np.maximum(0, h1 @ self.w2.T + self.b2)
        return h2 @ self.wo.T + self.bo

    def _encode(self, game, me):
        flip = me == 1
        # 格子数可能因插桥/吞噬变化，固定取前 8 格（与训练一致）
        cells = list(reversed(game.cells))[:MAX_CELLS] if flip else game.cells[:MAX_CELLS]
        x = []
        for c in cells:
            x += [c.v / 9.0,
                  1.0 if c.o == me else 0.0,
                  1.0 if (c.o is not None and c.o != me) else 0.0,
                  1.0 if c.bridge else 0.0,
                  1.0 if c.onBridge else 0.0,
                  1.0 if c.auto else 0.0]
        while len(x) < MAX_CELLS * 6:
            x += [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        x += [0.0,  # 归一化视角下我方恒为玩家0
              1.0 if game.phase == 'action' else 0.0,
              1.0 if game.phase == 'produce' else 0.0,
              game.points / 10.0, game.produce_left / 8.0]
        return np.array(x, dtype=np.float64)

    def _slot(self, action, flip):
        t = action.get('type')
        i = int(action.get('i', -1))
        if i < 0 or i >= MAX_CELLS:
            return None
        if flip:
            i = MAX_CELLS - 1 - i
        if t == 'move':
            steps = int(action.get('steps', 1))
            return i * 6 + (1 if steps >= 2 else 0)
        if t == 'attack':
            return i * 6 + 2
        if t == 'devour':
            return i * 6 + 3
        if t == 'split':
            return i * 6 + 4
        if t == 'produce':
            return i * 6 + 5
        if t == 'endTurn':
            return 48
        return None

    def decide(self, game):
        if game.phase is None:
            # 阶段选择：启发式兜底（训练未覆盖阶段选择）
            return self.fallback.decide(game)
        acts = game.get_legal_actions(game.turn)
        playable = [a for a in acts if a['type'] != 'endTurn']
        if not playable:
            return {'type': 'endTurn'}
        me = game.turn
        flip = me == 1
        x = self._encode(game, me)
        logits = self._forward(x)
        best, best_a = -1e18, None
        for a in playable:
            slot = self._slot(a, flip)
            if slot is None or slot >= OUT:
                continue
            s = logits[slot]
            if s > best:
                best, best_a = s, a
        return best_a if best_a is not None else playable[0]
