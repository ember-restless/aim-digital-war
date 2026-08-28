#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Python 版模型 AI（评估用）—— 与 client/lib/train/train_ai.dart 同构
- 加载 train_weights.json（MLP 101→128→128→193）
- 决策：阶段选择交给网络，已选阶段后行动用模型前向 + 合法动作 mask
- 视角归一化：我方（game.turn）恒为左方，flip 时棋盘镜像（先补零到 16 格再逆序）、
  槽位索引翻转（15-i，与训练端 rebuild 恒 16 格一致）
"""
import json
import sys

import numpy as np

sys.path.insert(0, '/root/aim/pc')
from ai import AimAi
from rules import AimCell

IN_DIM = 101
HIDDEN = 128
OUT = 193
MAX_CELLS = 16




class ModelAi:
    def __init__(self, weights_path, fallback_level='hard', seed=0, sample=False, temp=1.0):
        w = json.load(open(weights_path, 'r', encoding='utf-8'))
        # 维度从权重文件读取（64/128 单元都兼容）
        self.in_dim = int(w.get('in', IN_DIM))
        self.hidden = int(w.get('hidden', HIDDEN))
        self.out = int(w.get('out', OUT))
        self.w1 = np.array(w['w1'], dtype=np.float64).reshape(self.hidden, self.in_dim)
        self.b1 = np.array(w['b1'], dtype=np.float64)
        self.w2 = np.array(w['w2'], dtype=np.float64).reshape(self.hidden, self.hidden)
        self.b2 = np.array(w['b2'], dtype=np.float64)
        self.wo = np.array(w['wo'], dtype=np.float64).reshape(self.out, self.hidden)
        self.bo = np.array(w['bo'], dtype=np.float64)
        self.fallback = AimAi(fallback_level, seed=seed)
        # 采样模式（互搏评估用，与训练采样口径一致）；temp 从权重恢复（左右独立噪点）
        self.sample = sample
        self.temp = temp
        if sample and 'temp' in w:
            try:
                self.temp = float(w['temp'])
            except Exception:
                pass
        self.rng = np.random.default_rng(seed + 101)

    def _forward(self, x):
        h1 = np.maximum(0, x @ self.w1.T + self.b1)
        h2 = np.maximum(0, h1 @ self.w2.T + self.b2)
        return h2 @ self.wo.T + self.bo

    def _pick(self, logits, acts, flip, game):
        """argmax（默认）或 softmax 温度采样（sample=True，评估互搏用）"""
        best, best_a = -1e18, None
        kept = []
        logit_list = []
        for a in acts:
            slot = self._slot(a, flip, game)
            if slot is None or slot >= self.out:
                continue
            s = logits[slot]
            kept.append(a)
            logit_list.append(s)
            if s > best:
                best, best_a = s, a
        if not kept:
            return acts[0] if acts else None
        if self.sample:
            ls = np.array(logit_list, dtype=np.float64)
            e = np.exp((ls - ls.max()) / self.temp)
            p = e / e.sum()
            idx = int(self.rng.choice(len(kept), p=p))
            return kept[idx]
        return best_a if best_a is not None else kept[0]

    def _encode(self, game, me):
        flip = me == 1
        # 先补零到 16 格再逆序——与训练端 rebuild（恒 16 格）布局一致，
        # 翻转公式统一 15-i；真实棋盘不足 16 格时格子位置才不错位
        cells = list(game.cells)
        while len(cells) < MAX_CELLS:
            cells.append(AimCell(0))
        if flip:
            cells = list(reversed(cells))
        cells = cells[:MAX_CELLS]
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

    def _slot(self, action, flip, game=None):
        t = action.get('type')
        i = int(action.get('i', -1))
        if i < 0 or i >= MAX_CELLS:
            return None
        if flip:
            i = MAX_CELLS - 1 - i
        if t == 'move':
            steps = int(action.get('steps', 1))
            return i * 12 + (1 if steps >= 2 else 0)
        if t == 'attack':
            k = abs(int(action.get('j', -1)) - int(action.get('i', -1)))
            if k < 1 or k > 3:
                return None
            j = int(action.get('j', -1))
            is_enemy = 0 <= j < len(game.cells) and game.cells[j].o is not None and game.cells[j].o != game.turn
            return i * 12 + (2 + (k - 1) if is_enemy else 5 + (k - 1))
        if t == 'devour':
            j = int(action.get('j', -1))
            is_enemy = 0 <= j < len(game.cells) and game.cells[j].o is not None and game.cells[j].o != game.turn
            return i * 12 + (8 if is_enemy else 9)
        if t == 'split':
            return i * 12 + 10
        if t == 'produce':
            return i * 12 + 11
        if t == 'endTurn':
            return 16 * 12
        return None

    def decide(self, game):
        if game.phase is None:
            # 2026-08-28 阶段选择交给网络（与训练端一致）：候选 = 行动类 + 造兵类并集，
            # 编码 phase=null（two-hot 全 0），动作类型隐含阶段选择
            acts = []
            # 行动类：phase=null 时 get_legal_actions 返回 choosePhase×2 + 行动类，过滤掉前两者
            acts.extend(a for a in game.get_legal_actions(game.turn)
                        if a['type'] not in ('choosePhase', 'endTurn'))
            # 造兵类：手动枚举（与规则 produce 分支一致）
            me = game.turn
            d = 1 if me == 0 else -1
            for i, c in enumerate(game.cells):
                if c.o == me and c.v == 8:
                    j = i + d
                    if 0 <= j < len(game.cells) and not game.cells[j].bridge:
                        acts.append({'type': 'produce', 'i': i, 'j': j})
            if not acts:
                return {'type': 'choosePhase', 'phase': 'action'}
            flip = me == 1
            x = self._encode(game, me)
            logits = self._forward(x)
            if logits is None:
                return self.fallback.decide(game)
            return self._pick(logits, acts, flip, game)
        acts = game.get_legal_actions(game.turn)
        playable = [a for a in acts if a['type'] != 'endTurn']
        if not playable:
            return {'type': 'endTurn'}
        me = game.turn
        flip = me == 1
        x = self._encode(game, me)
        logits = self._forward(x)
        return self._pick(logits, playable, flip, game)
