# AIM 数字大战 — 规则引擎（Python PC 版）
# 与 client/lib/game/rules.dart 逐行对应移植（双端行为一致）
# 纯逻辑无 IO；输出 lastAction/rollActs 与联机服务端同格式

K_DIR = [1, -1]              # 玩家0朝右(+1)，玩家1朝左(-1)
K_RANGE = {3: 2, 4: 3}       # 3弓手射程2，4炮手射程3，其余1
K_CAVALRY = {2, 5}           # 骑兵
K_BRIDGE_OK = {1, 2, 3}   # 能过桥的轻单位（4炮手改重装，不可过桥）
K_SPLIT_MIN = 5              # 可拆分的最小值

_cell_id_counter = 0

def _next_cell_id():
    global _cell_id_counter
    _cell_id_counter += 1
    return _cell_id_counter


class AimCell:
    __slots__ = ('v', 'o', 'bridge', 'onBridge', 'auto', 'id', 'pressedV', 'pressedO')

    def __init__(self, v, o=None, bridge=False, onBridge=False, auto=False):
        self.v = v              # 0=空地, 1..9
        self.o = o              # 0=玩家0 1=玩家1 None=无人
        self.bridge = bridge
        self.onBridge = onBridge
        self.auto = auto        # 滚木已激活
        self.id = _next_cell_id()
        self.pressedV = None    # 滚木脚下压着的单位
        self.pressedO = None

    @property
    def is_unit(self):
        return not self.bridge and self.v >= 1

    def to_map(self):
        return {
            'v': self.v, 'o': self.o, 'bridge': self.bridge,
            'onBridge': self.onBridge, 'auto': self.auto, 'id': self.id,
            'pressedV': self.pressedV, 'pressedO': self.pressedO,
        }


class AimGame:
    def __init__(self, limit=16, allow_own_roller_attack=True):
        self.limit = limit
        self.allow_own_roller_attack = allow_own_roller_attack
        init = limit // 2
        self.cells = [AimCell(0) for _ in range(init)]
        self.cells[0] = AimCell(8, o=0)                 # 玩家0基地（左端）
        self.cells[init - 1] = AimCell(8, o=1)          # 玩家1基地（右端）
        self.turn = 0
        self.phase = None          # 'action' | 'produce' | None
        self.points = 0
        self.produce_left = 0
        self.winner = None
        self.log = []
        self.last_action = None
        self.last_seq = 0
        self.roll_seq = 0
        self.roll_steps = None
        # ── 对局统计 ──
        self.stats = {'kills': [0, 0], 'losses': [0, 0], 'produce': [0, 0]}
        self.turn_count = 0
        # ── 滚木逐步状态 ──
        self._rs_owner = None
        self._rs_rollers = None
        self._rs_idx = 0
        self._rs_pos = 0
        self._rs_step = 1
        self._rs_rolled = set()
        self._rs_done = set()
        self._rs_active = False
        self._rs_logs = []
        self._rs_steps = []
        self._last_roll_acts = None
        self._roll_step_seq = 0
        self._pending_roll = False
        # ── 重复操作判负（象棋式「三次重复」，牢大定）──
        # 指纹 = 玩家 | 操作签名 | 操作后棋盘快照；同一指纹第 3 次出现 → 制造循环者判负
        self._op_history = {}
        self._last_op_repeat_warn = False  # 本次操作是否触发第 2 次重复警告

    # ── 基础 ──
    def dir_of(self, owner):
        return K_DIR[owner]

    def is_bridge(self, c):
        return c is not None and c.bridge

    def is_unit(self, c):
        return c is not None and not c.bridge and c.v >= 1

    def is_owned_unit(self, c, owner):
        return self.is_unit(c) and c.o == owner

    def sum_of(self, owner):
        s = 0
        for c in self.cells:
            if self.is_owned_unit(c, owner):
                s += c.v
            if c.v == 6 and c.pressedV is not None and c.pressedO == owner:
                s += c.pressedV
        return s

    def count_of(self, owner, v):
        return sum(1 for c in self.cells if self.is_owned_unit(c, owner) and c.v == v)

    def _stats_list(self, key):
        return self.stats[key]

    # ── 伤害 ──
    def apply_damage(self, idx, dmg, by_owner=None):
        c = self.cells[idx]
        if not self.is_unit(c) or c.v == 0:
            return {'insertedAt': None}
        killed_owner = c.o
        c.v -= dmg
        if c.v != 6:
            c.auto = False
        if c.v > 0:
            return {'insertedAt': None}
        if c.v == 0:
            if killed_owner is not None:
                self._stats_list('losses')[killed_owner] += 1
                if by_owner is not None:
                    self._stats_list('kills')[by_owner] += 1
            if c.onBridge:
                self.cells[idx] = AimCell(0, bridge=True)
            else:
                c.v = 0
                c.o = None
            return {'insertedAt': None}
        # 溢出：数字变绝对值，桥插在单位位置
        c.v = -c.v
        if c.v != 6:
            c.auto = False
        if len(self.cells) < self.limit:
            next_is_bridge = (idx + 1 < len(self.cells)) and self.cells[idx + 1].bridge
            self.cells.insert(idx, AimCell(0, bridge=True))
            c.onBridge = next_is_bridge
            return {'insertedAt': idx}
        return {'insertedAt': None}

    # ── 合法性 ──
    def can_pass(self, idx, owner):
        if idx < 0 or idx >= len(self.cells):
            return False
        c = self.cells[idx]
        if self.is_bridge(c):
            return c.v in K_BRIDGE_OK
        if c.v == 0:
            return True
        return False

    def can_stand(self, idx, unit_v):
        if idx < 0 or idx >= len(self.cells):
            return False
        c = self.cells[idx]
        if c.v == 0 and not c.bridge:
            return True
        if self.is_bridge(c):
            return unit_v in K_BRIDGE_OK
        return False

    # ── 合法行动 ──
    def get_legal_actions(self, owner):
        if self.winner is not None or self.turn != owner:
            return []
        acts = []
        d = self.dir_of(owner)
        if self.phase is None:
            out = [
                {'type': 'choosePhase', 'phase': 'action'},
                {'type': 'choosePhase', 'phase': 'produce'},
            ]
            if self.count_of(owner, 9) + 1 > 0:
                self.gen_unit_actions(owner, acts)
                out.extend(acts)
            return out
        if self.phase == 'produce':
            if self.produce_left <= 0:
                return [{'type': 'endTurn'}]
            for i, c in enumerate(self.cells):
                if not self.is_owned_unit(c, owner) or c.v != 8:
                    continue
                j = i + d
                if j < 0 or j >= len(self.cells):
                    continue
                if self.is_bridge(self.cells[j]):
                    continue
                acts.append({'type': 'produce', 'i': i, 'j': j})
            return acts
        if self.points <= 0:
            return [{'type': 'endTurn'}]
        self.gen_unit_actions(owner, acts)
        return acts

    def gen_unit_actions(self, owner, acts):
        d = self.dir_of(owner)
        for i, c in enumerate(self.cells):
            if not self.is_owned_unit(c, owner):
                continue
            v = c.v
            if v == 6 and c.auto:
                continue
            if v == 8 or v == 9:
                for keep in range(1, v):
                    acts.append({'type': 'split', 'i': i, 'keep': keep, 'a': keep, 'b': v - keep})
                continue
            # 移动
            if v in K_CAVALRY:
                s1, s2 = i + d, i + 2 * d
                if 0 <= s1 < len(self.cells) and self.is_bridge(self.cells[s1]):
                    if v in K_BRIDGE_OK:
                        acts.append({'type': 'move', 'i': i, 'steps': 1})
                    else:
                        acts.append({'type': 'move', 'i': i, 'steps': 1, 'fatal': True})
                elif self.can_stand(s1, v):
                    if 0 <= s2 < len(self.cells) and self.is_unit(self.cells[s2]) and not self.is_bridge(self.cells[s2]):
                        acts.append({'type': 'move', 'i': i, 'steps': 1})
                    elif 0 <= s2 < len(self.cells) and self.is_bridge(self.cells[s2]) and v not in K_BRIDGE_OK:
                        acts.append({'type': 'move', 'i': i, 'steps': 2, 'fatal': True})
                    elif self.can_stand(s2, v):
                        acts.append({'type': 'move', 'i': i, 'steps': 2})
            else:
                s1 = i + d
                if 0 <= s1 < len(self.cells) and self.is_bridge(self.cells[s1]):
                    if v in K_BRIDGE_OK:
                        acts.append({'type': 'move', 'i': i, 'steps': 1})
                    elif v == 5 or v == 7 or v == 4:
                        acts.append({'type': 'move', 'i': i, 'steps': 1, 'fatal': True})
                elif self.can_stand(s1, v):
                    acts.append({'type': 'move', 'i': i, 'steps': 1})
            # 攻击
            r = K_RANGE.get(v, 1)
            for k in range(1, r + 1):
                j = i + d * k
                if j < 0 or j >= len(self.cells):
                    break
                if not self.is_unit(self.cells[j]):
                    continue
                if not self.allow_own_roller_attack and self.cells[j].v == 6 and self.cells[j].o == owner:
                    continue
                acts.append({'type': 'attack', 'i': i, 'j': j})
            # 拆分
            if v >= K_SPLIT_MIN:
                for keep in range(1, v):
                    acts.append({'type': 'split', 'i': i, 'keep': keep, 'a': keep, 'b': v - keep})
            # 吞噬
            j = i + d
            if 0 <= j < len(self.cells) and self.is_unit(self.cells[j]) and self.cells[j].v <= v:
                acts.append({'type': 'devour', 'i': i, 'j': j})

    # ── 执行 ──
    def do_move(self, owner, i, steps):
        d = self.dir_of(owner)
        unit = self.cells[i]
        if unit.auto and unit.v == 6:
            return False
        v = unit.v
        path = [i + d * k for k in range(1, steps + 1)]
        for p in path:
            if p < 0 or p >= len(self.cells):
                return False
            if self.is_bridge(self.cells[p]) and v not in K_BRIDGE_OK:
                ui = self.cells.index(unit) if unit in self.cells else -1
                if ui >= 0:
                    self.cells[ui] = AimCell(0)
                self.cells.pop(p)
                self.log.append(f'单位{v}走桥：桥塌人亡')
                self.last_seq += 1
                self.last_action = {'type': 'move', 'i': i, 'steps': steps, 'bridgeCollapse': p, 'owner': owner}
                return True
            if not self.can_stand(p, v):
                return False
        target = path[-1]
        start_is_bridge = self.cells[i].onBridge or self.is_bridge(self.cells[i])
        if self.is_bridge(self.cells[target]):
            self.cells[target] = AimCell(v, o=owner, onBridge=True)
        else:
            # 目标不是桥：单位已离开桥，清掉残留的 onBridge，避免离桥后仍被判“在桥上”
            # （否则桥正前方吞噬>=5 会误触发桥毁人亡）
            self.cells[target] = self.cells[i]
            self.cells[target].onBridge = False
        if start_is_bridge:
            self.cells[i] = AimCell(0) if v == 1 else AimCell(0, bridge=True)
            if v == 1:
                self.log.append('小兵拆掉了独木桥')
        else:
            self.cells[i] = AimCell(0)
        self.last_seq += 1
        self.last_action = {'type': 'move', 'i': i, 'steps': steps, 'bridgeCollapse': None, 'owner': owner}
        return True

    def is_shield_covered(self, j, i, t):
        def_dir = K_DIR[t.o]
        k = j
        while k != i:
            if k < 0 or k >= len(self.cells):
                break
            c = self.cells[k]
            if self.is_owned_unit(c, t.o) and c.v == 7:
                return True
            k += def_dir
        return False

    def do_attack(self, owner, i, j):
        att = self.cells[i]
        if att.auto and att.v == 6:
            return False
        dmg = 1 if att.v in K_RANGE else att.v
        t = self.cells[j]
        if not self.is_unit(t):
            return False
        if not self.allow_own_roller_attack and t.v == 6 and t.o == owner:
            return False
        old = t.v
        if att.v in K_RANGE and self.is_shield_covered(j, i, t):
            self.log.append(f'{att.v}的攻击被盾兵7挡下')
            self.last_seq += 1
            self.last_action = {'type': 'attack', 'i': i, 'j': j, 'shielded': True, 'owner': owner}
            return True
        r = self.apply_damage(j, dmg, by_owner=owner)
        tj = j + 1 if r['insertedAt'] is not None else j
        tc = self.cells[tj] if tj < len(self.cells) else None
        new_v = tc.v if self.is_unit(tc) else 0
        self.log.append(f'{att.v}攻击{old}，造成{dmg}伤害')
        self.last_seq += 1
        self.last_action = {'type': 'attack', 'i': i, 'j': j, 'old': old, 'newV': new_v,
                            'insertedAt': r['insertedAt'], 'owner': owner}
        return True

    def do_split(self, owner, i, keep):
        unit = self.cells[i]
        if unit.auto and unit.v == 6:
            return False
        v = unit.v
        if v < K_SPLIT_MIN:
            return False
        if keep is None or keep < 1 or keep >= v:
            return False
        other = v - keep
        if len(self.cells) >= self.limit:
            unit.v = keep
            self.log.append(f'满员拆分：{v} → 只保留{keep}')
            self.last_seq += 1
            self.last_action = {'type': 'split', 'i': i, 'keep': keep, 'other': other, 'full': True, 'owner': owner}
            return True
        ins = i + 1
        if ins < 0 or ins > len(self.cells):
            return False
        self.cells.insert(ins, AimCell(other, o=owner))
        unit.v = keep
        self.log.append(f'拆分{v} → {keep}+{other}')
        self.last_seq += 1
        self.last_action = {'type': 'split', 'i': i, 'keep': keep, 'other': other, 'full': False, 'owner': owner}
        return True

    def do_devour(self, owner, i, j):
        me = self.cells[i]
        if me.auto and me.v == 6:
            return False
        t = self.cells[j]
        if not self.is_unit(t) or t.v > me.v:
            return False
        total = me.v + t.v
        spliced = False
        collapsed = False
        if total <= 9:
            me.v = total
            if t.o is not None:
                self._stats_list('losses')[t.o] += 1
                self._stats_list('kills')[owner] += 1
            self.cells.pop(j)
            spliced = True
            self.log.append(f'吞噬：{total - t.v}+{t.v}={total}')
        else:
            tens = total // 10
            ones = total % 10
            # 拆出来的两个数，棋盘从左到右读 = 十进制（十位在左、个位在右）
            # 左方(0)吞噬：me 在左保留十位，目标在右放个位；右方(1)相反
            if owner == 0:
                me.v = tens
                self.cells[j] = AimCell(ones, o=None if ones == 0 else owner)
            else:
                me.v = ones
                self.cells[j] = AimCell(tens, o=owner)
                if me.v == 0:
                    me.o = None
                    me.auto = False
            self.log.append(f'吞噬超9：{total} → {tens}+{ones}（变拉了）')
        if me.onBridge and me.v >= 5:
            idx = self.cells.index(me) if me in self.cells else -1
            if idx >= 0:
                # 桥毁人亡：连同桥与人一起从棋盘上消失（pop 删格，而非只清空）
                self.cells.pop(idx)
            self.log.append(f'桥上吞噬后{me.v}≥5：桥毁人亡')
            collapsed = True
        self.last_seq += 1
        self.last_action = {'type': 'devour', 'i': i, 'j': j, 'sum': total,
                            'spliced': spliced, 'collapsed': collapsed, 'owner': owner}
        return True

    def do_produce(self, owner, i):
        base = self.cells[i]
        if not self.is_owned_unit(base, owner) or base.v != 8:
            return False
        d = self.dir_of(owner)
        j = i + d
        if j < 0 or j >= len(self.cells):
            return False
        t = self.cells[j]
        if self.is_bridge(t):
            return False
        if self.is_unit(t) and t.o != owner:
            self.apply_damage(j, 1, by_owner=owner)
            self.log.append('造兵攻击：敌方单位-1')
            self.last_seq += 1
            self.last_action = {'type': 'produce', 'j': j, 'attacked': True, 'owner': owner}
        else:
            if t.v == 9:
                t.v = 1
                t.o = owner
            else:
                t.v += 1
                t.o = owner
            self.log.append(f'造兵：基地前{t.v - 1} → {t.v}')
            self.last_seq += 1
            self.last_action = {'type': 'produce', 'j': j, 'attacked': False, 'newV': t.v, 'owner': owner}
        self._stats_list('produce')[owner] += 1
        return True

    def do_choose_phase(self, owner, phase):
        if self.phase is not None or self.turn != owner:
            return False
        if phase != 'action' and phase != 'produce':
            return False
        self.phase = phase
        if phase == 'action':
            self.points = self.count_of(owner, 9) + 1
        else:
            self.produce_left = self.count_of(owner, 8)
        return True

    # ── 滚木自动/逐步 ──
    def auto_roll(self, owner):
        self.begin_roll(owner)
        while self.roll_step_once(owner) is not None:
            pass

    def begin_roll(self, owner):
        self._rs_active = False
        self._rs_owner = None
        self._rs_done.clear()

    def roll_step_once(self, owner):
        result = self._roll_step_once_inner(owner)
        if result is None:
            self._last_roll_acts = None
        else:
            self._last_roll_acts = result
            self._roll_step_seq += 1
        return result

    def _roll_step_once_inner(self, owner):
        if not self._rs_active:
            if self._rs_owner != owner:
                self._rs_done.clear()
            self._rs_owner = owner
            self._rs_rollers = []
            seen = set()
            for c in self.cells:
                if self.is_owned_unit(c, owner) and c.v == 6 and c.id not in seen and c.id not in self._rs_done:
                    seen.add(c.id)
                    self._rs_rollers.append(c)
            self._rs_idx = 0
            self._rs_pos = -1 if not self._rs_rollers else self.cells.index(self._rs_rollers[0])
            self._rs_step = 1
            self._rs_rolled.clear()
            self._rs_logs.clear()
            self._rs_steps.clear()
            self._rs_active = True
            if not self._rs_rollers:
                self._rs_active = False
                return None
        d = self.dir_of(owner)
        while self._rs_idx < len(self._rs_rollers) and self._rs_rollers[self._rs_idx] not in self.cells:
            self._rs_idx += 1
        if self._rs_idx >= len(self._rs_rollers):
            self._finish_roll()
            return None
        roller = self._rs_rollers[self._rs_idx]
        if self._rs_step > 3:
            roller.auto = True
            self._rs_done.add(roller.id)
            self._rs_idx += 1
            self._rs_step = 1
            if self._rs_idx < len(self._rs_rollers):
                self._rs_pos = self.cells.index(self._rs_rollers[self._rs_idx])
                return self.roll_step_once(owner)
            self._finish_roll()
            return None
        res = self._roll_one_step(roller, d)
        self._rs_step += 1
        acts = res['acts']
        if res['finished']:
            roller.auto = True
            self._rs_done.add(roller.id)
            self._rs_idx += 1
            self._rs_step = 1
            if self._rs_idx < len(self._rs_rollers):
                self._rs_pos = self.cells.index(self._rs_rollers[self._rs_idx])
                if acts:
                    return acts
                return self.roll_step_once(owner)
            self._finish_roll()
            return acts if acts else None
        return acts

    def _finish_roll(self):
        self._rs_active = False
        self._pending_roll = False
        self.log.extend(self._rs_logs)
        if self._rs_steps:
            self.roll_seq += 1
            self.roll_steps = list(self._rs_steps)
        self._rs_logs.clear()
        self._rs_steps.clear()

    def _unpress(self, roller):
        if 0 <= self._rs_pos < len(self.cells) and self.cells[self._rs_pos] is roller:
            if roller.pressedV is not None:
                self.cells[self._rs_pos] = AimCell(roller.pressedV, o=roller.pressedO,
                                                   auto=(roller.pressedV == 6))
            else:
                self.cells[self._rs_pos] = AimCell(0)
        roller.pressedV = None
        roller.pressedO = None

    def _place(self, roller, idx, pressed_v=None, pressed_o=None):
        if 0 <= idx < len(self.cells):
            self.cells[idx] = roller
            roller.pressedV = pressed_v
            roller.pressedO = pressed_o

    def _roll_one_step(self, roller, d):
        acts = []
        pos = self._rs_pos
        p = pos + d
        self._unpress(roller)
        if p < 0 or p >= len(self.cells):
            self._rs_steps.append({'dead': True})
            self._rs_logs.append('滚木滚出地图')
            acts.append({'op': 'dead', 'reason': 'edge', 'from': pos})
            roller.auto = True
            return {'acts': acts, 'finished': True}
        t = self.cells[p]
        if self.is_bridge(t):
            self._rs_steps.append({'dead': True, 'bridgeCollapse': True})
            self._rs_logs.append('滚木砸塌独木桥')
            self.cells.pop(p)
            acts.append({'op': 'dead', 'reason': 'bridge', 'from': pos})
            roller.auto = True
            return {'acts': acts, 'finished': True}
        if t.v == 8 or t.v == 9:
            self._rs_steps.append({'dead': True, 'building': True})
            self._rs_logs.append('滚木撞上建筑消失')
            acts.append({'op': 'dead', 'reason': 'building', 'from': pos})
            roller.auto = True
            return {'acts': acts, 'finished': True}
        if self.is_unit(t):
            if t.id in self._rs_rolled:
                self._rs_pos = p
                self._rs_steps.append({'crush': False})
                acts.append({'op': 'move', 'from': pos, 'to': p})
                self._place(roller, p, pressed_v=t.v, pressed_o=t.o)
                return {'acts': acts, 'finished': False}
            self._rs_rolled.add(t.id)
            if self._rs_step == 3:
                self._rs_steps.append({'crush': True, 'kill': True, 'owner': t.o, 'oldV': t.v})
                self._rs_logs.append(f'滚木抹杀{t.v}')
                self.cells[p] = AimCell(0)
                self._place(roller, p)
                self._rs_pos = p
                acts.append({'op': 'kill', 'from': pos, 'to': p, 'at': p, 'oldV': t.v})
                return {'acts': acts, 'finished': True}
            old_v = t.v
            r = self.apply_damage(p, 6)
            self._rs_steps.append({'crush': True, 'owner': t.o, 'oldV': old_v,
                                   'newV': t.v, 'bridge': r['insertedAt'] is not None})
            self._rs_logs.append(f'滚木碾过：{old_v}受6伤')
            if r['insertedAt'] is not None:
                self._rs_steps.append({'bump': True})
                self._rs_pos = p + 1
                acts.append({'op': 'crush', 'from': pos, 'to': p + 1, 'at': p,
                             'oldV': old_v, 'newV': t.v, 'bridge': True})
                if 0 <= self._rs_pos < len(self.cells):
                    self._place(roller, self._rs_pos, pressed_v=t.v, pressed_o=t.o)
                    return {'acts': acts, 'finished': False}
                self._rs_steps.append({'dead': True})
                acts.append({'op': 'dead', 'reason': 'edge', 'from': self._rs_pos})
                roller.auto = True
                return {'acts': acts, 'finished': True}
            self._rs_pos = p
            self._place(roller, p, pressed_v=t.v, pressed_o=t.o)
            acts.append({'op': 'crush', 'from': pos, 'to': p, 'at': p,
                         'oldV': old_v, 'newV': t.v, 'bridge': False})
            return {'acts': acts, 'finished': False}
        self._rs_pos = p
        self._place(roller, p)
        self._rs_steps.append({'crush': False})
        acts.append({'op': 'move', 'from': pos, 'to': p})
        return {'acts': acts, 'finished': False}

    def end_turn(self, owner, defer_roll=False):
        if self.turn != owner:
            return False
        self.turn = 1 - owner
        self.phase = None
        self.points = 0
        self.produce_left = 0
        self.turn_count += 1
        if defer_roll:
            self._pending_roll = any(
                self.is_owned_unit(c, self.turn) and c.v == 6 and c.id not in self._rs_done
                for c in self.cells)
        else:
            self.auto_roll(self.turn)
        self.check_win()
        return True

    @property
    def has_pending_roll(self):
        return self._pending_roll

    def clear_pending_roll(self):
        self._pending_roll = False

    def check_win(self):
        for o in (0, 1):
            if self.sum_of(o) == 0:
                self.winner = 1 - o
                self.log.append(f'玩家{1 - o}获胜！')
                continue
            # 只剩激活滚木（无任何可操控单位）→ 直接判负（牢大定）
            has_controllable = any(
                self.is_owned_unit(c, o) and not (c.v == 6 and c.auto)
                for c in self.cells)
            if not has_controllable:
                self.winner = 1 - o
                self.log.append(f'玩家{o}只剩滚木，无法行动，判负')

    # ── 重复操作判负（象棋式「三次重复」，与 server rules.js 逐行对应）──
    def _board_hash(self):
        return ';'.join(
            f"{c.v},{c.o if c.o is not None else ''},{1 if c.bridge else 0},"
            f"{1 if c.onBridge else 0},{1 if c.auto else 0},"
            f"{c.pressedV if c.pressedV is not None else ''},"
            f"{c.pressedO if c.pressedO is not None else ''}"
            for c in self.cells)

    def _op_sig(self, action):
        t = action.get('type')
        if t == 'move':
            return f"move:{action['i']}:{action.get('steps', 1)}"
        if t == 'attack':
            return f"attack:{action['i']}:{action['j']}"
        if t == 'split':
            return f"split:{action['i']}:{action.get('keep', 0)}"
        if t == 'devour':
            return f"devour:{action['i']}:{action['j']}"
        if t == 'produce':
            return f"produce:{action['i']}"
        return t or ''

    def _record_op(self, owner, action):
        fp = f"{owner}|{self._op_sig(action)}|{self._board_hash()}"
        n = self._op_history.get(fp, 0) + 1
        self._op_history[fp] = n
        if n >= 3:
            self.winner = 1 - owner
            self.log.append(f'玩家{owner}重复完全相同操作三次（循环），判负')
            self._last_op_repeat_warn = False
        elif n == 2:
            # 第二次重复：提示「再重复一次就判负」（牢大定）
            self._last_op_repeat_warn = True
            self.log.append(f'玩家{owner}注意：再重复一次相同操作将直接判负')
        else:
            self._last_op_repeat_warn = False
        return n

    # ── 统一入口 ──
    def apply_action(self, owner, action, defer_roll=False):
        if self.winner is not None:
            return {'ok': False, 'reason': '游戏已结束'}
        if self.turn != owner:
            return {'ok': False, 'reason': '还没轮到你'}
        t = action.get('type')
        if self.phase is None:
            if t == 'produce':
                self.do_choose_phase(owner, 'produce')
            elif t in ('move', 'attack', 'split', 'devour'):
                self.do_choose_phase(owner, 'action')
        if t == 'choosePhase':
            if not self.do_choose_phase(owner, action.get('phase', '')):
                return {'ok': False, 'reason': '无效阶段选择'}
            self.maybe_auto_end()
            return {'ok': True}
        if t == 'move':
            if self.phase != 'action' or self.points <= 0:
                return {'ok': False, 'reason': '非行动阶段'}
            if not self.do_move(owner, action['i'], action.get('steps', 1)):
                return {'ok': False, 'reason': '移动不合法'}
            self.points -= 1
            self.check_win()
            if self.winner is None:
                self._record_op(owner, action)  # 重复操作三次判负（象棋式）
            self.maybe_auto_end()
            return {'ok': True, 'repeatWarn': self._last_op_repeat_warn}
            return {'ok': True}
        if t == 'attack':
            if self.phase != 'action' or self.points <= 0:
                return {'ok': False, 'reason': '非行动阶段'}
            if not self.do_attack(owner, action['i'], action['j']):
                return {'ok': False, 'reason': '攻击不合法'}
            self.points -= 1
            self.check_win()
            if self.winner is None:
                self._record_op(owner, action)  # 重复操作三次判负（象棋式）
            self.maybe_auto_end()
            return {'ok': True, 'repeatWarn': self._last_op_repeat_warn}
            return {'ok': True}
        if t == 'split':
            if self.phase != 'action' or self.points <= 0:
                return {'ok': False, 'reason': '非行动阶段'}
            if not self.do_split(owner, action['i'], action.get('keep', 0)):
                return {'ok': False, 'reason': '拆分不合法'}
            self.points -= 1
            self.check_win()
            if self.winner is None:
                self._record_op(owner, action)  # 重复操作三次判负（象棋式）
            self.maybe_auto_end()
            return {'ok': True, 'repeatWarn': self._last_op_repeat_warn}
            return {'ok': True}
        if t == 'devour':
            if self.phase != 'action' or self.points <= 0:
                return {'ok': False, 'reason': '非行动阶段'}
            if not self.do_devour(owner, action['i'], action['j']):
                return {'ok': False, 'reason': '吞噬不合法'}
            self.points -= 1
            self.check_win()
            if self.winner is None:
                self._record_op(owner, action)  # 重复操作三次判负（象棋式）
            self.maybe_auto_end()
            return {'ok': True, 'repeatWarn': self._last_op_repeat_warn}
            return {'ok': True}
        if t == 'produce':
            if self.phase != 'produce' or self.produce_left <= 0:
                return {'ok': False, 'reason': '非造兵阶段'}
            if not self.do_produce(owner, action['i']):
                return {'ok': False, 'reason': '造兵不合法'}
            self.produce_left -= 1
            self.check_win()
            if self.winner is None:
                self._record_op(owner, action)  # 重复操作三次判负（象棋式）
            self.maybe_auto_end()
            return {'ok': True, 'repeatWarn': self._last_op_repeat_warn}
            return {'ok': True}
        if t == 'endTurn':
            if self.phase == 'action' and self.points > 0:
                return {'ok': False, 'reason': '行动点未耗尽，不能结束回合'}
            if self.phase == 'produce' and self.produce_left > 0:
                return {'ok': False, 'reason': '造兵点未耗尽，不能结束回合'}
            self.end_turn(owner, defer_roll=defer_roll)
            return {'ok': True}
        return {'ok': False, 'reason': '未知行动'}

    def maybe_auto_end(self):
        if self.winner is not None:
            return
        if self.phase == 'action' and self.points <= 0:
            self.end_turn(self.turn)
            return
        if self.phase == 'produce' and self.produce_left <= 0:
            self.end_turn(self.turn)
            return
        acts = self.get_legal_actions(self.turn)
        playable = [a for a in acts if a['type'] != 'endTurn' and a['type'] != 'choosePhase']
        if self.phase is not None and not playable:
            self.log.append(f'玩家{self.turn}无任何可执行行动，判负')
            self.winner = 1 - self.turn

    # ── 玩家视角快照 ──
    def view_for(self, player_idx):
        mine = player_idx == self.turn
        return {
            'cells': [c.to_map() for c in self.cells],
            'mapLen': len(self.cells),
            'limit': self.limit,
            'turn': self.turn,
            'phase': self.phase,
            'points': self.points,
            'produceLeft': self.produce_left,
            'winner': self.winner,
            'yourIdx': player_idx,
            'names': ['玩家1', '玩家2'],
            'hotseat': True,
            'mySum': self.sum_of(player_idx),
            'enemySum': self.sum_of(1 - player_idx),
            'myBases': self.count_of(player_idx, 8),
            'myHqs': self.count_of(player_idx, 9),
            'legalActions': self.get_legal_actions(player_idx) if mine else [],
            'log': self.log[-8:] if len(self.log) > 8 else list(self.log),
            'lastAction': self.last_action,
            'lastSeq': self.last_seq,
            'rollSteps': self.roll_steps,
            'rollSeq': self.roll_seq,
            'rollPending': self._pending_roll or self._rs_active,
            'rollActs': self._last_roll_acts,
            'rollStepSeq': self._roll_step_seq,
            'stats': self.stats,
            'turnCount': self.turn_count,
        }
