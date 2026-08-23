# AIM AI 对手（PC 版）：决策层（只从合法行动里选，不碰规则引擎）
# 与 client/lib/game/ai.dart 对齐：easy 随机 / normal 启发式 / hard 加强（防守+远程规避+滚木战术）
import random

from rules import AimGame, K_RANGE, K_BRIDGE_OK

EASY = 'easy'
NORMAL = 'normal'
HARD = 'hard'


class AimAi:
    def __init__(self, level, seed=None):
        self.level = level
        self.rand = random.Random(seed)

    # AI 回合决策：返回一个要执行的 action
    def decide(self, game):
        if game.winner is not None:
            return None
        owner = game.turn
        if game.phase is None:
            if self.level == EASY:
                return {'type': 'choosePhase', 'phase': 'action' if self.rand.random() < 0.5 else 'produce'}
            return {'type': 'choosePhase', 'phase': 'action' if self._want_action(game, owner) else 'produce'}
        if game.phase == 'produce':
            acts = game.get_legal_actions(owner)
            prod = [a for a in acts if a['type'] == 'produce']
            if not prod:
                return {'type': 'endTurn'}
            if self.level == EASY:
                return prod[self.rand.randrange(len(prod))]
            return self._pick_produce(game, owner, prod)
        acts = game.get_legal_actions(owner)
        playable = [a for a in acts if a['type'] != 'endTurn']
        if not playable:
            return {'type': 'endTurn'}
        if self.level == EASY:
            return playable[self.rand.randrange(len(playable))]
        playable.sort(key=lambda a: self._score(game, owner, a), reverse=True)
        return playable[0]

    def _want_action(self, game, owner):
        acts = game.get_legal_actions(owner)
        best = 0
        for a in acts:
            s = self._score(game, owner, a)
            if s > best:
                best = s
        if best >= 60:
            return True
        p = 0.55 if self.level == HARD else 0.38
        return self.rand.random() < p

    def _pick_produce(self, game, owner, prod):
        for p in prod:
            j = p['j']
            c = game.cells[j]
            if c.o is not None and c.o != owner:
                return p
        return prod[self.rand.randrange(len(prod))]

    def _score(self, game, owner, a):
        t = a['type']
        if t == 'attack':
            return self._score_attack(game, owner, a)
        if t == 'devour':
            return self._score_devour(game, owner, a)
        if t == 'move':
            return self._score_move(game, owner, a)
        if t == 'split':
            return self._score_split(game, owner, a)
        return 0

    def _score_attack(self, game, owner, a):
        cells = game.cells
        i, j = a['i'], a['j']
        att, t = cells[i], cells[j]
        if t.o == owner:
            return -100
        dmg = 1 if att.v in K_RANGE else att.v
        if att.v in K_RANGE and game.is_shield_covered(j, i, t):
            return -1
        score = t.v * 2
        if t.v == 7:
            score += 60
        if t.v == 8:
            score += 120
        if t.v == 9:
            score += 200
        if t.v <= dmg:
            score += 150
        if t.v < dmg:
            score += 40
        if self.level == HARD:
            my_base = self._my_base(game, owner)
            if my_base is not None:
                dist = abs(j - my_base)
                if dist <= 3:
                    score += (4 - dist) * 25
        return score

    def _score_devour(self, game, owner, a):
        cells = game.cells
        i, j = a['i'], a['j']
        me, t = cells[i], cells[j]
        total = me.v + t.v
        score = 0
        if t.o != owner:
            score += t.v * 4
        if total >= 9:
            score += 400
        elif total == 8:
            score += 250
        elif total >= 6:
            score += 120
        elif t.o == owner:
            score += 15
        return score

    def _score_move(self, game, owner, a):
        cells = game.cells
        i = a['i']
        v = cells[i].v
        steps = a.get('steps', 1)
        d = 1 if owner == 0 else -1
        new_idx = i + d * steps
        score = 10
        score += (new_idx if owner == 0 else len(cells) - 1 - new_idx) * 2
        if 0 <= new_idx < len(cells) and cells[new_idx].bridge:
            if v == 1:
                score += 20
            elif v in K_BRIDGE_OK:
                score += 5
            else:
                score -= 800
        if a.get('fatal'):
            score -= 800
        if self.level == HARD:
            for k in range(1, 4):
                p = new_idx + d * k
                if p < 0 or p >= len(cells):
                    break
                c = cells[p]
                if c.o is not None and c.o != owner and c.v >= 1:
                    r = K_RANGE.get(c.v, 1)
                    if r >= k:
                        score -= 12 * (r - k + 1)
            score += self._roller_score(game, owner, i, v, new_idx)
        return score

    def _roller_score(self, game, owner, i, v, new_idx):
        cells = game.cells
        d = 1 if owner == 0 else -1
        roller = None
        for k, c in enumerate(cells):
            if c.o == owner and c.v == 6 and c.auto:
                roller = k
                break
        if roller is None:
            return 0

        def clear_to(target):
            q = roller + d
            while q != target:
                if q < 0 or q >= len(cells):
                    return False
                c = cells[q]
                if c.bridge or (c.o is not None and c.v >= 8):
                    return False
                q += d
            if target < 0 or target >= len(cells):
                return False
            return not cells[target].bridge

        score = 0
        for k in range(1, 4):
            p = roller + d * k
            if p < 0 or p >= len(cells):
                continue
            if p == new_idx:
                if not clear_to(p):
                    continue
                if k <= 2:
                    if v == 1:
                        score += 110
                    elif v == 2:
                        score += 55
                    elif v == 3:
                        score -= 10
                    else:
                        score -= 160
                else:
                    score -= 200
            if p == i and k <= 2 and v >= 4 and clear_to(p):
                score += 90
        return score

    def _score_split(self, game, owner, a):
        cells = game.cells
        i = a['i']
        d = 1 if owner == 0 else -1
        j = i + d
        keep = a.get('keep', 1)
        if 0 <= j < len(cells) and cells[j].bridge and keep in K_BRIDGE_OK:
            return 60
        if cells[i].v >= 8:
            return -40
        return 0

    def _my_base(self, game, owner):
        for k, c in enumerate(game.cells):
            if c.o == owner and c.v == 8:
                return k
        return None
