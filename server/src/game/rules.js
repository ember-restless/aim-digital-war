// AIM 数字大战 — 规则引擎（服务端权威）
// 纯逻辑，无 IO。双端客户端只发指令，一切判定在此。

'use strict';

// ---------- 常量 ----------
const DIR = [1, -1];        // 玩家0朝右(+1)，玩家1朝左(-1)
const RANGE = { 3: 2, 4: 3 }; // 3弓手射程2，4炮手射程3，其余1
const CAVALRY = new Set([2, 5]); // 骑兵
const BRIDGE_OK = new Set([1, 2, 3]); // 能过桥的轻单位（4炮手改重装，不可过桥）
const SPLIT_MIN = 5; // 可拆分的最小值

// ---------- 状态构建 ----------
// 格子身份 id：每个格子/单位创建时分配，移动/合并时 id 跟随元素，删除时 id 消失
// 客户端按 id 渲染元素（而不是数组索引），动画精准匹配元素身份
let cellId = 1;
function newCell(obj) {
  return { ...obj, id: cellId++ };
}
function freshEmpty() {
  return newCell({ v: 0, o: null });
}

function createGame({ limit = 16, allowOwnRollerAttack = true } = {}) {
  const init = Math.floor(limit / 2);
  const cells = [];
  for (let i = 0; i < init; i++) cells.push(freshEmpty()); // 空地
  cells[0] = newCell({ v: 8, o: 0 });           // 玩家0基地（左端）
  cells[init - 1] = newCell({ v: 8, o: 1 });    // 玩家1基地（右端）
  return {
    map: { limit, cells },
    allowOwnRollerAttack, // 规则开关：己方能否攻击己方滚木（默认可，保持「敌我皆可」）
    turn: 0,
    phase: null,          // 'action' | 'produce' | null(未选)
    points: 0,            // 行动阶段剩余行动点
    produceLeft: 0,       // 造兵阶段剩余次数
    winner: null,
    log: [],
    lastAction: null, // 最近一次行动剧本（客户端照此播放动画，不用 diff 猜）
    lastSeq: 0,       // 剧本序号（每次行动 +1，客户端只播新序号，防重复播放）
    // ── 滚木逐步驱动状态（对齐客户端 rules.dart，2026-08-21 联机对齐热座）──
    _rsOwner: null,
    _rsRollers: null,
    _rsIdx: 0,
    _rsPos: 0,
    _rsStep: 1,
    _rsRolled: new Set(),   // 本轮已碾过的单位 id
    _rsDone: new Set(),     // 本回合已滚完的滚木 id（防重新收集重复滚）
    _rsActive: false,
    _rsLogs: [],
    _rsSteps: [],
    _lastRollActs: null,    // 最近一步基础动作（客户端动画层逐步驱动用）
    _rollStepSeq: 0,
    _pendingRoll: false,    // deferRoll 模式：endTurn 后滚木还没滚
    // ── 对局统计（结算页用）──
    stats: {
      kills: [0, 0],   // 每方击杀（攻击/吞噬/造兵攻击致死）
      losses: [0, 0],  // 每方损失（含滚木碾死）
      produce: [0, 0], // 每方造兵数
    },
    turnCount: 0,       // 已过回合数
    // ── 重复操作判负（象棋式「三次重复」，牢大定）──
    // 指纹 = 玩家 | 操作签名 | 操作后棋盘快照；同一指纹第 3 次出现 → 制造循环者判负
    _opHistory: {},
  };
}

function isBridge(c) { return c && c.bridge === true; }
function isUnit(c) { return c && !c.bridge && c.v >= 1; }
function isOwnedUnit(c, owner) { return isUnit(c) && c.o === owner; }

// 数字和（胜利判定）
function sumOf(state, owner) {
  return state.map.cells.reduce((s, c) => {
    if (isOwnedUnit(c, owner)) s += c.v;
    // 滚木脚下压着的单位也算（棋盘不显示，但数值参与胜利判定）
    if (c.v === 6 && c.pressedV != null && c.pressedO === owner) s += c.pressedV;
    return s;
  }, 0);
}

// 基地数 / 指挥部数
function countOf(state, owner, v) {
  return state.map.cells.filter((c) => isOwnedUnit(c, owner) && c.v === v).length;
}

// ---------- 伤害 ----------
// 返回 { insertedAt: number|null }（插桥位置，供调用方修正索引）
// byOwner 非空时记录击杀（攻击/吞噬/造兵攻击）；滚木碾死不记击杀只记损失
function applyDamage(state, idx, dmg, byOwner) {
  const c = state.map.cells[idx];
  if (!isUnit(c) || c.v === 0) return { insertedAt: null };
  const killedOwner = c.o;
  c.v -= dmg;
  // 降级后不再是滚木 → 解锁（除非溢出恢复回6）
  if (c.v !== 6) c.auto = false;
  if (c.v > 0) return { insertedAt: null };
  if (c.v === 0) {
    // 阵亡统计
    if (killedOwner !== null && killedOwner !== undefined) {
      state.stats.losses[killedOwner]++;
      if (byOwner !== null && byOwner !== undefined) state.stats.kills[byOwner]++;
    }
    // 变空地；若单位站在桥上，桥保留
    if (c.onBridge === true) {
      state.map.cells[idx] = newCell({ bridge: true });
    } else {
      c.v = 0;
      c.o = null;
    }
    return { insertedAt: null };
  }
  // 溢出为负：数字变成绝对值（1受6伤 → -5 → 5）
  // 桥插在单位【位置】（在这一格和左边那一格中间新增，桥右边的单位下标全部+1）
  c.v = -c.v; // |原数字-伤害|
  if (c.v !== 6) c.auto = false;
  const cells = state.map.cells;
  if (cells.length < state.map.limit) {
    // 2026-08-19 修复：单位被新桥挤到 idx+1，onBridge 按新位置脚下重新判定——
    // 否则残留 onBridge=true，单位走开时原地凭空造桥（幽灵格子/多桥）
    const nextIsBridge = (idx + 1 < cells.length) && cells[idx + 1].bridge === true;
    cells.splice(idx, 0, newCell({ bridge: true }));
    c.onBridge = nextIsBridge;
    return { insertedAt: idx };
  }
  return { insertedAt: null };
}

// ---------- 合法性 ----------
// 单位能否通过目标格（移动用）
function canPass(state, idx, owner) {
  const c = state.map.cells[idx];
  if (!c) return false;
  if (isBridge(c)) return BRIDGE_OK.has(c.v); // 桥：轻单位可过（桥上本质像0）
  if (c.v === 0) return true; // 空地
  return false; // 有数字单位不能踩
}

// 某格是否可站（移动终点）：空地可站；桥只有轻单位(1-3)能站，
// 4/5/6/7 走桥 = 桥塌人亡（但 UI 上可选，后果自负）
function canStand(state, idx, unitV) {
  const c = state.map.cells[idx];
  if (!c) return false;
  if (c.v === 0 && !c.bridge) return true;
  if (isBridge(c)) return BRIDGE_OK.has(unitV);
  return false;
}

// 某方所有合法行动
function getLegalActions(state, owner) {
  if (state.winner || state.turn !== owner) return [];
  const acts = [];
  const { cells } = state.map;
  const dir = DIR[owner];
  if (state.phase === null) {
    // 未选阶段：返回选阶段选项 + 单位行动（供客户端选中/高亮；执行时自动选阶段）
    const out = [{ type: 'choosePhase', phase: 'action' }, { type: 'choosePhase', phase: 'produce' }];
    const tmpPoints = countOf(state, owner, 9) + 1;
    if (tmpPoints > 0) {
      genUnitActions(state, owner, acts);
      out.push(...acts);
    }
    return out;
  }
  if (state.phase === 'produce') {
    if (state.produceLeft <= 0) return [{ type: 'endTurn' }];
    cells.forEach((c, i) => {
      if (!isOwnedUnit(c, owner) || c.v !== 8) return; // 基地
      const j = i + dir;
      if (j < 0 || j >= cells.length) return;
      const t = cells[j];
      if (isBridge(t)) return; // 桥不能造
      acts.push({ type: 'produce', i, j });
    });
    return acts; // 造兵点未耗尽前不能结束回合
  }
  // action 阶段
  if (state.points <= 0) return [{ type: 'endTurn' }];
  genUnitActions(state, owner, acts);
  return acts; // 行动点未耗尽前不能结束回合
}

// 生成单位行动（移动/攻击/拆分/吞噬）
function genUnitActions(state, owner, acts) {
  const { cells } = state.map;
  const dir = DIR[owner];
  cells.forEach((c, i) => {
    if (!isOwnedUnit(c, owner)) return;
    const v = c.v;
    if (v === 6 && c.auto) return; // 滚木已开始自动滚动，不可操控（除非被打成其它数字）
    if (v === 8 || v === 9) {
      // 建筑：不可移动/攻击/吞噬，只能拆分（keep=保留值，a/b 供客户端展示顺序）
      for (let keep = 1; keep < v; keep++) {
        acts.push({ type: 'split', i, keep, a: keep, b: v - keep });
      }
      return;
    }
    // --- 移动 ---
    if (CAVALRY.has(v)) {
      // 骑兵固定2格；第2格有数字单位可停1格
      const s1 = i + dir, s2 = i + 2 * dir;
      if (s1 >= 0 && s1 < cells.length && isBridge(cells[s1])) {
        // 桥：轻骑兵(2)正常过；重骑兵(5)走=桥塌人亡（可选，后果自负）
        if (BRIDGE_OK.has(v)) acts.push({ type: 'move', i, steps: 1 });
        else acts.push({ type: 'move', i, steps: 1, fatal: true });
      } else if (canStand(state, s1, v)) {
        if (s2 >= 0 && s2 < cells.length && isUnit(cells[s2]) && !isBridge(cells[s2])) {
          acts.push({ type: 'move', i, steps: 1 });
        } else if (s2 >= 0 && s2 < cells.length && isBridge(cells[s2]) && !BRIDGE_OK.has(v)) {
          acts.push({ type: 'move', i, steps: 2, fatal: true });
        } else if (canStand(state, s2, v)) {
          acts.push({ type: 'move', i, steps: 2 });
        }
      }
    } else {
      const s1 = i + dir;
      if (s1 >= 0 && s1 < cells.length && isBridge(cells[s1])) {
        // 桥：轻单位正常过；5/7 走=桥塌人亡（可选，后果自负）
        if (BRIDGE_OK.has(v)) acts.push({ type: 'move', i, steps: 1 });
        else if (v === 5 || v === 7 || v === 4) acts.push({ type: 'move', i, steps: 1, fatal: true });
      } else if (canStand(state, s1, v)) {
        acts.push({ type: 'move', i, steps: 1 });
      }
    }
    // --- 攻击（敌我皆可，规则开关可禁止己方攻击己方滚木）---
    const r = RANGE[v] || 1;
    for (let k = 1; k <= r; k++) {
      const j = i + dir * k;
      if (j < 0 || j >= cells.length) break;
      const t = cells[j];
      if (!isUnit(t)) continue;
      if (!state.allowOwnRollerAttack && t.v === 6 && t.o === owner) continue;
      acts.push({ type: 'attack', i, j });
    }
    // --- 拆分（keep=保留值 1..v-1，a/b 供客户端展示顺序）---
    if (v >= SPLIT_MIN) {
      for (let keep = 1; keep < v; keep++) {
        acts.push({ type: 'split', i, keep, a: keep, b: v - keep });
      }
    }
    // --- 吞噬 ---
    const j = i + dir;
    if (j >= 0 && j < cells.length && isUnit(cells[j]) && cells[j].v <= v) {
      acts.push({ type: 'devour', i, j });
    }
  });
}

// ---------- 执行 ----------
function doMove(state, owner, i, steps) {
  const { cells } = state.map;
  const dir = DIR[owner];
  const unit = cells[i];
  if (unit.auto && unit.v === 6) return false; // 只有激活滚木不可操控（滚木滚出来的非6单位可正常行动）
  const v = unit.v;
  const path = [];
  for (let k = 1; k <= steps; k++) path.push(i + dir * k);
  // 重单位走桥：桥塌人亡（同归于尽）
  for (const p of path) {
    if (p < 0 || p >= cells.length) return false;
    if (isBridge(cells[p]) && !BRIDGE_OK.has(v)) {
      // 桥塌人亡（牢大 2026-08-19）：单位原地变空（不是删格），桥格删除——棋盘只少 1 格
      const ui = cells.indexOf(unit);
      if (ui >= 0) cells[ui] = newCell({ v: 0 });
      cells.splice(p, 1);
      state.log.push(`单位${v}走桥：桥塌人亡`);
      state.lastSeq++;
      state.lastAction = { type: 'move', i, steps, bridgeCollapse: p, owner };
      return true;
    }
    if (!canStand(state, p, v)) return false;
  }
  // 正常移动
  const target = path[path.length - 1];
  const startIsBridge = cells[i].onBridge === true || isBridge(cells[i]);
  if (isBridge(cells[target])) {
    // 走到桥上：单位站上桥（桥地形保留在脚下）
    cells[target] = newCell({ v, o: owner, onBridge: true });
  } else {
    // 目标不是桥：单位已离开桥，清掉残留的 onBridge，避免离桥后仍被判“在桥上”
    // （否则桥正前方吞噬>=5 会误触发桥毁人亡）
    cells[target] = cells[i];
    cells[target].onBridge = false;
  }
  if (startIsBridge) {
    // 小兵1离开桥 → 桥变空地（拆桥）；其他轻单位过桥 → 桥保留
    cells[i] = v === 1 ? freshEmpty() : newCell({ bridge: true });
    if (v === 1) state.log.push('小兵拆掉了独木桥');
  } else {
    cells[i] = freshEmpty();
  }
  state.lastSeq++;
  state.lastAction = { type: 'move', i, steps, bridgeCollapse: null, owner };
  return true;
}

// 盾兵屏障：目标本身是7，或目标朝敌方方向有己方盾兵7挡在箭路上 → 免疫弓兵3/炮兵4远程伤害
function isShieldCovered(cells, j, i, t) {
  const defDir = DIR[t.o]; // 被攻击方朝敌方向（= 朝攻击者方向）
  for (let k = j; k !== i; k += defDir) {
    if (k < 0 || k >= cells.length) break;
    const c = cells[k];
    if (c && isOwnedUnit(c, t.o) && c.v === 7) return true;
  }
  return false;
}

function doAttack(state, owner, i, j) {
  const { cells } = state.map;
  const att = cells[i];
  if (att.auto && att.v === 6) return false;
  const dmg = RANGE[att.v] !== undefined ? 1 : att.v; // 3、4恒1
  const t = cells[j];
  if (!isUnit(t)) return false;
  // 规则开关：己方滚木不可被己方攻击（服务端权威校验，防伪造操作）
  if (!state.allowOwnRollerAttack && t.v === 6 && t.o === owner) return false;
  const old = t.v;
  // 盾兵7免疫：弓兵3/炮兵4 打不到 7 及其身后单位（0伤害，行动点照扣，无提示）
  if (RANGE[att.v] !== undefined && isShieldCovered(cells, j, i, t)) {
    state.log.push(`${att.v}的攻击被盾兵7挡下`);
    state.lastSeq++;
    state.lastAction = { type: 'attack', i, j, shielded: true, owner };
    return true;
  }
  const r = applyDamage(state, j, dmg, owner);
  // 溢出插桥时目标右移一格（splice(j,0)），否则原位
  const tj = r.insertedAt !== null ? j + 1 : j;
  const tc = cells[tj];
  const newV = tc && isUnit(tc) ? tc.v : 0;
  state.log.push(`${att.v}攻击${old}，造成${dmg}伤害`);
  state.lastAction = { type: 'attack', i, j, old, newV, insertedAt: r.insertedAt, owner };
  return true;
}

// 拆分（新协议）：{keep} 保留值留在原格，另一半插到前方（右边）；满员只保留所选
function doSplit(state, owner, i, keep) {
  const { cells } = state.map;
  const unit = cells[i];
  if (unit.auto && unit.v === 6) return false;
  const v = unit.v;
  if (v < SPLIT_MIN) return false;
  if (typeof keep !== 'number' || !Number.isInteger(keep) || keep < 1 || keep >= v) return false;
  const other = v - keep;
  if (cells.length >= state.map.limit) {
    // 满员：只保留所选，另一半丢弃
    unit.v = keep;
    state.log.push(`满员拆分：${v} → 只保留${keep}`);
    state.lastSeq++;
    state.lastAction = { type: 'split', i, keep, other, full: true, owner };
    return true;
  }
  const dir = DIR[owner];
  // 产物固定插到保留值右侧（索引+1，不随阵营方向）——牢大规则：保留值在左、产物在右，桥被顶到产物后面
  const ins = i + 1;
  if (ins < 0 || ins > cells.length) return false;
  cells.splice(ins, 0, newCell({ v: other, o: owner }));
  unit.v = keep;
  state.log.push(`拆分${v} → ${keep}+${other}`);
  state.lastAction = { type: 'split', i, keep, other, full: false, owner };
  return true;
}

function doDevour(state, owner, i, j) {
  const { cells } = state.map;
  const me = cells[i];
  if (me.auto && me.v === 6) return false;
  const t = cells[j];
  if (!isUnit(t) || t.v > me.v) return false;
  const sum = me.v + t.v;
  let spliced = false;
  let collapsed = false;
  if (sum <= 9) {
    // 吞噬统计：目标阵亡
    if (t.o !== null && t.o !== undefined) {
      state.stats.losses[t.o]++;
      state.stats.kills[owner]++;
    }
    me.v = sum;
    cells.splice(j, 1); // 目标格消失，地图-1
    spliced = true;
    state.log.push(`吞噬：${sum - t.v}+${t.v}=${sum}`);
  } else {
    // 超9：按十进制字符拆。10 → [1][0]
    // 拆出来的两个数，棋盘从左到右读 = 十进制（十位在左、个位在右）
    // 左方(0)吞噬：me 在左保留十位，目标在右放个位；右方(1)相反
    const tens = Math.floor(sum / 10);
    const ones = sum % 10;
    if (owner === 0) {
      me.v = tens;
      cells[j] = newCell({ v: ones, o: ones === 0 ? null : owner });
    } else {
      me.v = ones;
      cells[j] = newCell({ v: tens, o: owner });
      if (me.v === 0) {
        // 10/20…：吞噬者这一位是 0，清成空地
        me.o = null;
        me.auto = false;
      }
    }
    state.log.push(`吞噬超9：${sum} → ${tens}+${ones}（变拉了）`);
  }
  // 桥上吞噬：合并后数字 >= 5 → 桥毁人亡（与重单位踩桥塌一致；5 也是重单位）
  if (me.onBridge === true && me.v >= 5) {
    const idx = cells.indexOf(me);
    if (idx >= 0) cells.splice(idx, 1); // 桥毁人亡：连桥带人一起删格（-1格），非仅清空
    state.log.push(`桥上吞噬后${me.v}≥5：桥毁人亡`);
    collapsed = true;
  }
  state.lastSeq++;
  state.lastAction = { type: 'devour', i, j, sum, spliced, collapsed, owner };
  return true;
}

function doProduce(state, owner, i) {
  const { cells } = state.map;
  const base = cells[i];
  if (!isOwnedUnit(base, owner) || base.v !== 8) return false;
  const dir = DIR[owner];
  const j = i + dir;
  if (j < 0 || j >= cells.length) return false;
  const t = cells[j];
  if (isBridge(t)) return false;
  if (isUnit(t) && t.o !== owner) {
    // 敌方单位 → 减一（攻击）
    applyDamage(state, j, 1, owner);
    state.log.push(`造兵攻击：敌方单位-1`);
    state.lastSeq++;
    state.lastAction = { type: 'produce', j, attacked: true, owner };
  } else {
    // 空地/我方单位 → +1
    if (t.v === 9) {
      // 9+1=10 → [1][0]
      t.v = 1;
      t.o = owner;
      if (j + dir < cells.length) {
        // 个位0空地放前方？这里简化：10占两格需要+1格
        // —— 简化处理：9+1 变成 1，前方不插（待定）
      }
    } else {
      t.v += 1;
      t.o = owner;
    }
    state.log.push(`造兵：基地前${t.v - 1} → ${t.v}`);
    state.lastSeq++;
    state.lastAction = { type: 'produce', j, attacked: false, newV: t.v, owner };
  }
  state.stats.produce[owner]++;
  return true;
}

function doChoosePhase(state, owner, phase) {
  if (state.phase !== null || state.turn !== owner) return false;
  if (phase !== 'action' && phase !== 'produce') return false;
  state.phase = phase;
  if (phase === 'action') {
    state.points = countOf(state, owner, 9) + 1;
  } else {
    state.produceLeft = countOf(state, owner, 8);
  }
  return true;
}

// ── 滚木自动阶段（逐步驱动，对齐客户端 rules.dart 2026-08-16 重构）──
// rollStepOnce 每次只滚一步（供动画层"规则算一步 → 动画播一步"嵌套驱动）
// autoRoll 循环调用 rollStepOnce——行为与旧全量版完全一致，只是可逐步执行
function autoRoll(state, owner) {
  beginRoll(state, owner);
  while (rollStepOnce(state, owner) != null) {}
}

function beginRoll(state, owner) {
  state._rsActive = false;
  state._rsOwner = null;
  state._rsDone = new Set();
}

// 滚木单步：调用一次滚一步，返回该步的【基础动作序列】；全部滚完返回 null
// 基础动作：{op:'move',from,to} 滚木移动 ｜ {op:'crush',from,to,at,oldV,newV,bridge} 压单位（含插桥）
// ｜ {op:'kill',from,to,at,oldV} 抹杀 ｜ {op:'dead',from,reason} 死亡（撞桥/建筑/滚出/掉桥）
function rollStepOnce(state, owner) {
  const result = _rollStepOnceInner(state, owner);
  if (result == null) {
    state._lastRollActs = null;
  } else {
    state._lastRollActs = result;
    state._rollStepSeq = (state._rollStepSeq || 0) + 1;
  }
  return result;
}

function _rollStepOnceInner(state, owner) {
  const { cells } = state.map;
  if (!state._rsActive) {
    if (state._rsOwner !== owner) state._rsDone = new Set();
    state._rsOwner = owner;
    state._rsRollers = [];
    const seen = new Set();
    for (const c of cells) {
      if (isOwnedUnit(c, owner) && c.v === 6 && !seen.has(c.id) && !state._rsDone.has(c.id)) {
        seen.add(c.id);
        state._rsRollers.push(c);
      }
    }
    state._rsIdx = 0;
    state._rsPos = state._rsRollers.length === 0 ? -1 : cells.indexOf(state._rsRollers[0]);
    state._rsStep = 1;
    state._rsRolled = new Set();
    state._rsLogs = [];
    state._rsSteps = [];
    state._rsActive = true;
    if (state._rsRollers.length === 0) {
      state._rsActive = false;
      return null;
    }
  }
  const dir = DIR[owner];
  // 定位当前活着的滚木（可能已死亡/被清）
  while (state._rsIdx < state._rsRollers.length && !cells.includes(state._rsRollers[state._rsIdx])) {
    state._rsIdx++;
  }
  if (state._rsIdx >= state._rsRollers.length) {
    _finishRoll(state);
    return null;
  }
  const roller = state._rsRollers[state._rsIdx];
  if (state._rsStep > 3) {
    // 当前滚木 3 步完成：收尾（滚木已在最终位置，由 _rollOneStep 精确放置）
    roller.auto = true;
    state._rsDone.add(roller.id);
    state._rsIdx++;
    state._rsStep = 1;
    if (state._rsIdx < state._rsRollers.length) {
      state._rsPos = cells.indexOf(state._rsRollers[state._rsIdx]);
      return rollStepOnce(state, owner); // 继续下一个滚木的第一步
    }
    _finishRoll(state);
    return null;
  }
  const res = _rollOneStep(state, roller, dir);
  state._rsStep++;
  const acts = res.acts;
  if (res.finished) {
    // 该滚木结束（死亡或抹杀）：滚木已消失或停在终点
    roller.auto = true;
    state._rsDone.add(roller.id);
    state._rsIdx++;
    state._rsStep = 1;
    if (state._rsIdx < state._rsRollers.length) {
      state._rsPos = cells.indexOf(state._rsRollers[state._rsIdx]);
      // 2026-08-18 修复：当前滚木有死亡/抹杀动画（acts 非空）时先返回这步，
      // 让客户端播完再请求下一步——否则下一个滚木的 acts 会覆盖吞掉这步动画
      if (acts.length > 0) return acts;
      const next = rollStepOnce(state, owner);
      return next;
    }
    _finishRoll(state);
    return acts.length === 0 ? null : acts;
  }
  return acts;
}

function _finishRoll(state) {
  state._rsActive = false;
  state._pendingRoll = false;
  state.log.push(...state._rsLogs);
  if (state._rsSteps.length > 0) {
    state.rollSeq = (state.rollSeq || 0) + 1;
    state.rollSteps = [...state._rsSteps];
  }
  state._rsLogs = [];
  state._rsSteps = [];
}

// 滚木走开：当前位置清空（露出脚下压着的单位，或空地），滚木暂离棋盘
function _unpress(state, roller) {
  const { cells } = state.map;
  if (state._rsPos >= 0 && state._rsPos < cells.length && cells[state._rsPos] === roller) {
    cells[state._rsPos] = roller.pressedV != null
      ? newCell({ v: roller.pressedV, o: roller.pressedO, auto: roller.pressedV === 6 })
      : freshEmpty();
  }
  roller.pressedV = null;
  roller.pressedO = null;
}

// 滚木放置到 [idx]：覆盖目标格（原单位值存入 pressed = 滚木脚下压着）
function _place(state, roller, idx, pressedV, pressedO) {
  const { cells } = state.map;
  if (idx >= 0 && idx < cells.length) {
    cells[idx] = roller;
    roller.pressedV = pressedV ?? null;
    roller.pressedO = pressedO ?? null;
  }
}

// 滚木单步执行：返回 {acts: 基础动作序列, finished: 该滚木是否结束}
function _rollOneStep(state, roller, dir) {
  const { cells } = state.map;
  const acts = [];
  const pos = state._rsPos;
  const p = pos + dir;
  // 步开头：脚下压着的单位转正（滚木走开，露出——牢大：压到单位后棋盘只显示滚木，走开才露出）
  _unpress(state, roller);
  if (p < 0 || p >= cells.length) {
    // 滚出地图
    state._rsSteps.push({ dead: true });
    state._rsLogs.push('滚木滚出地图');
    acts.push({ op: 'dead', reason: 'edge', from: pos });
    roller.auto = true;
    return { acts, finished: true };
  }
  const t = cells[p];
  if (isBridge(t)) {
    // 撞桥：桥塌，滚木消失（脚下单位已转正，splice 后自动补位）
    state._rsSteps.push({ dead: true, bridgeCollapse: true });
    state._rsLogs.push('滚木砸塌独木桥');
    cells.splice(p, 1);
    acts.push({ op: 'dead', reason: 'bridge', from: pos });
    roller.auto = true;
    return { acts, finished: true };
  }
  if (t.v === 8 || t.v === 9) {
    // 撞建筑：滚木消失
    state._rsSteps.push({ dead: true, building: true });
    state._rsLogs.push('滚木撞上建筑消失');
    acts.push({ op: 'dead', reason: 'building', from: pos });
    roller.auto = true;
    return { acts, finished: true };
  }
  if (isUnit(t)) {
    if (state._rsRolled.has(t.id)) {
      // 已被推挤到前方，不再碾：滚木站上去（脚下压着）
      state._rsPos = p;
      state._rsSteps.push({ crush: false });
      acts.push({ op: 'move', from: pos, to: p });
      _place(state, roller, p, t.v, t.o);
      return { acts, finished: false };
    }
    state._rsRolled.add(t.id);
    if (state._rsStep === 3) {
      // 第三格：抹杀（单位死，滚木站上去）
      state._rsSteps.push({ crush: true, kill: true, owner: t.o, oldV: t.v });
      state._rsLogs.push(`滚木抹杀${t.v}`);
      cells[p] = freshEmpty();
      _place(state, roller, p);
      state._rsPos = p;
      acts.push({ op: 'kill', from: pos, to: p, at: p, oldV: t.v });
      return { acts, finished: true };
    }
    // 第一、二格：压到单位，受6伤
    const oldV = t.v;
    const r = applyDamage(state, p, 6);
    state._rsSteps.push({ crush: true, owner: t.o, oldV, newV: t.v, bridge: r.insertedAt !== null });
    state._rsLogs.push(`滚木碾过：${oldV}受6伤`);
    if (r.insertedAt !== null) {
      // 溢出插桥：桥插单位位置（splice），变值单位被顶到桥右（p+1），滚木站到桥右压着它
      state._rsSteps.push({ bump: true });
      state._rsPos = p + 1; // 桥右边（splice 后变值单位所在）
      acts.push({ op: 'crush', from: pos, to: p + 1, at: p, oldV, newV: t.v, bridge: true });
      if (state._rsPos >= 0 && state._rsPos < cells.length) {
        _place(state, roller, state._rsPos, t.v, t.o);
        return { acts, finished: false };
      }
      // 被顶出地图（尽头插桥）
      state._rsSteps.push({ dead: true });
      acts.push({ op: 'dead', reason: 'edge', from: state._rsPos });
      roller.auto = true;
      return { acts, finished: true };
    }
    // 非溢出：单位原地变值，滚木站到单位上（脚下压着）
    state._rsPos = p;
    _place(state, roller, p, t.v, t.o);
    acts.push({ op: 'crush', from: pos, to: p, at: p, oldV, newV: t.v, bridge: false });
    return { acts, finished: false };
  }
  // 空地：滚木前进一格
  state._rsPos = p;
  _place(state, roller, p);
  state._rsSteps.push({ crush: false });
  acts.push({ op: 'move', from: pos, to: p });
  return { acts, finished: false };
}

function hasPendingRoll(state) {
  return !!state._pendingRoll;
}

function clearPendingRoll(state) {
  state._pendingRoll = false;
}

function endTurn(state, owner, deferRoll) {
  if (state.turn !== owner) return false;
  state.turn = 1 - owner;
  state.phase = null;
  state.points = 0;
  state.produceLeft = 0;
  state.turnCount++;
  if (deferRoll) {
    // 延后滚木：动画层逐步驱动（规则算一步 → 动画播一步）
    // 只在真有滚木待滚时标记（没滚木的回合不产生多余的 roll_step 请求）
    state._pendingRoll = state.map.cells.some(
      (c) => isOwnedUnit(c, state.turn) && c.v === 6 && !state._rsDone.has(c.id));
  } else {
    autoRoll(state, state.turn);
  }
  checkWin(state);
  return true;
}

function checkWin(state) {
  for (const o of [0, 1]) {
    if (sumOf(state, o) === 0) {
      state.winner = 1 - o;
      state.log.push(`玩家${1 - o}获胜！`);
      continue;
    }
    // 只剩激活滚木（无任何可操控单位）→ 直接判负（牢大定）
    const hasControllable = state.map.cells.some(
      (c) => isOwnedUnit(c, o) && !(c.v === 6 && c.auto));
    if (!hasControllable) {
      state.winner = 1 - o;
      state.log.push(`玩家${o}只剩滚木，无法行动，判负`);
    }
  }
}

// ── 重复操作判负（象棋式「三次重复」，牢大定）──
// 操作指纹 = 玩家 | 操作签名 | 操作后棋盘快照（含桥/滚木压着/轮到谁）
// 同一指纹第 3 次出现 → 制造循环的玩家直接判负
function boardHash(state) {
  return state.map.cells
    .map((c) => `${c.v},${c.o ?? ''},${c.bridge ? 1 : 0},${c.onBridge ? 1 : 0},${c.auto ? 1 : 0},${c.pressedV ?? ''},${c.pressedO ?? ''}`)
    .join(';');
}

function opSig(action) {
  switch (action.type) {
    case 'move': return `move:${action.i}:${action.steps}`;
    case 'attack': return `attack:${action.i}:${action.j}`;
    case 'split': return `split:${action.i}:${action.keep}`;
    case 'devour': return `devour:${action.i}:${action.j}`;
    case 'produce': return `produce:${action.i}`;
    default: return String(action.type);
  }
}

function recordOp(state, owner, action) {
  const fp = `${owner}|${opSig(action)}|${boardHash(state)}`;
  const n = (state._opHistory[fp] || 0) + 1;
  state._opHistory[fp] = n;
  if (n >= 3) {
    state.winner = 1 - owner;
    state.log.push(`玩家${owner}重复完全相同操作三次（循环），判负`);
  } else if (n === 2) {
    // 第二次重复：提示「再重复一次就判负」（牢大定）
    state.log.push(`玩家${owner}注意：再重复一次相同操作将直接判负`);
  }
  return n;
}

// 统一入口：执行一个行动（支持自动选阶段 + 点数耗尽自动过回合）
// [deferRoll] 手动 endTurn 时延后滚木（动画层逐步驱动，对齐热座）
function applyAction(state, owner, action, deferRoll) {
  if (state.winner) return { ok: false, reason: '游戏已结束' };
  if (state.turn !== owner) return { ok: false, reason: '还没轮到你' };
  // 自动选阶段：直接行动/造兵时隐式选择本回合类型
  if (state.phase === null) {
    if (action.type === 'produce') doChoosePhase(state, owner, 'produce');
    else if (['move', 'attack', 'split', 'devour'].includes(action.type)) doChoosePhase(state, owner, 'action');
  }
  switch (action.type) {
    case 'choosePhase':
      if (!doChoosePhase(state, owner, action.phase)) return { ok: false, reason: '无效阶段选择' };
      maybeAutoEnd(state); // 选完阶段立即检查（防死局卡死）
      return { ok: true };
    case 'move': {
      if (state.phase !== 'action' || state.points <= 0) return { ok: false, reason: '非行动阶段' };
      if (!doMove(state, owner, action.i, action.steps)) return { ok: false, reason: '移动不合法' };
      state.points--;
      checkWin(state);
      let _rw = false;
      if (!state.winner) _rw = recordOp(state, owner, action) === 2; // 重复操作三次判负（象棋式）
      maybeAutoEnd(state);
      return { ok: true, repeatWarn: _rw };
    }
    case 'attack': {
      if (state.phase !== 'action' || state.points <= 0) return { ok: false, reason: '非行动阶段' };
      if (!doAttack(state, owner, action.i, action.j)) return { ok: false, reason: '攻击不合法' };
      state.points--;
      checkWin(state);
      let _rw = false;
      if (!state.winner) _rw = recordOp(state, owner, action) === 2; // 重复操作三次判负（象棋式）
      maybeAutoEnd(state);
      return { ok: true, repeatWarn: _rw };
    }
    case 'split': {
      if (state.phase !== 'action' || state.points <= 0) return { ok: false, reason: '非行动阶段' };
      if (!doSplit(state, owner, action.i, action.keep)) return { ok: false, reason: '拆分不合法' };
      state.points--;
      checkWin(state);
      let _rw = false;
      if (!state.winner) _rw = recordOp(state, owner, action) === 2; // 重复操作三次判负（象棋式）
      maybeAutoEnd(state);
      return { ok: true, repeatWarn: _rw };
    }
    case 'devour': {
      if (state.phase !== 'action' || state.points <= 0) return { ok: false, reason: '非行动阶段' };
      if (!doDevour(state, owner, action.i, action.j)) return { ok: false, reason: '吞噬不合法' };
      state.points--;
      checkWin(state);
      let _rw = false;
      if (!state.winner) _rw = recordOp(state, owner, action) === 2; // 重复操作三次判负（象棋式）
      maybeAutoEnd(state);
      return { ok: true, repeatWarn: _rw };
    }
    case 'produce': {
      if (state.phase !== 'produce' || state.produceLeft <= 0) return { ok: false, reason: '非造兵阶段' };
      if (!doProduce(state, owner, action.i)) return { ok: false, reason: '造兵不合法' };
      state.produceLeft--;
      checkWin(state);
      let _rw = false;
      if (!state.winner) _rw = recordOp(state, owner, action) === 2; // 重复操作三次判负（象棋式）
      maybeAutoEnd(state);
      return { ok: true, repeatWarn: _rw };
    }
    case 'endTurn':
      if (state.phase === 'action' && state.points > 0) return { ok: false, reason: '行动点未耗尽，不能结束回合' };
      if (state.phase === 'produce' && state.produceLeft > 0) return { ok: false, reason: '造兵点未耗尽，不能结束回合' };
      endTurn(state, owner, deferRoll);
      return { ok: true };
    default:
      return { ok: false, reason: '未知行动' };
  }
}

// 点数耗尽 → 自动过回合；无任何可执行行动（如只剩锁定滚木）→ 直接判负（牢大 08-22）
function maybeAutoEnd(state) {
  if (state.winner) return;
  if (state.phase === 'action' && state.points <= 0) { endTurn(state, state.turn); return; }
  if (state.phase === 'produce' && state.produceLeft <= 0) { endTurn(state, state.turn); return; }
  // 防死局：剩余点数>0 但没有任何可执行行动（endTurn/choosePhase 除外）→ 判负
  const acts = getLegalActions(state, state.turn);
  const playable = acts.filter(a => a.type !== 'endTurn' && a.type !== 'choosePhase');
  if (state.phase && playable.length === 0) {
    state.log.push(`玩家${state.turn}无任何可执行行动，判负`);
    state.winner = 1 - state.turn;
  }
}

module.exports = {
  createGame, getLegalActions, applyAction, sumOf, countOf, DIR, RANGE, CAVALRY,
  beginRoll, rollStepOnce, hasPendingRoll, clearPendingRoll,
};
