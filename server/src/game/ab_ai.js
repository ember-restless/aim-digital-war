// αβ 剪枝 AI（Node/JS 版）—— 与 Python 原型/Dart 版逐行同构
// 依赖 ./rules.js 的函数式引擎。评估 = 牢大价值表 + 六特征加权。
'use strict';

const R = require('./rules');

function isOwnedUnit(c, owner) {
  return c && !c.bridge && c.v >= 1 && c.o === owner;
}

// ── 牢大价值表：1有1分，2有3分，3有6分，4有10分，5有16分，6没分，7有17分，8有30分，9有30分 ──
const V_TABLE = { 0: 0, 1: 1, 2: 3, 3: 6, 4: 10, 5: 16, 6: 0, 7: 17, 8: 30, 9: 30 };

// ── 评估权重（牢大拍板 + 价值表修正）──
const W_VAL = 0.35, W_MAX = 0.20, W_UNITS = 0.15, W_AP = 0.15, W_PP = 0.05, W_DIST = 0.10;
const WIN_V = 1000.0;

// ── 状态深拷贝（rules.js 无 clone；Set/对象全复制）──
function cloneState(s) {
  const c = {
    map: { limit: s.map.limit, cells: s.map.cells.map((x) => ({ ...x })) },
    allowOwnRollerAttack: s.allowOwnRollerAttack,
    turn: s.turn, phase: s.phase, points: s.points, produceLeft: s.produceLeft,
    winner: s.winner, turnCount: s.turnCount,
    log: [], lastAction: null, lastSeq: s.lastSeq,
    _rsOwner: s._rsOwner, _rsRollers: s._rsRollers ? [...s._rsRollers] : null,
    _rsIdx: s._rsIdx, _rsPos: s._rsPos, _rsStep: s._rsStep,
    _rsRolled: new Set(s._rsRolled), _rsDone: new Set(s._rsDone),
    _rsActive: s._rsActive, _rsLogs: [], _rsSteps: [],
    _lastRollActs: null, _rollStepSeq: 0, _pendingRoll: s._pendingRoll,
    stats: { kills: [...s.stats.kills], losses: [...s.stats.losses], produce: [...s.stats.produce] },
    _opHistory: { ...s._opHistory },
  };
  return c;
}

function sideValue(state, owner) {
  let s = 0;
  for (const c of state.map.cells) {
    if (isOwnedUnit(c, owner)) s += V_TABLE[c.v] !== undefined ? V_TABLE[c.v] : c.v;
  }
  return s;
}

function nearestToBase(state, owner) {
  const eBase = owner === 0 ? state.map.cells.length - 1 : 0;
  let best = null;
  for (let i = 0; i < state.map.cells.length; i++) {
    if (isOwnedUnit(state.map.cells[i], owner)) {
      const d = Math.abs(i - eBase);
      if (best === null || d < best) best = d;
    }
  }
  return best;
}

// 全体单位到对方基地的平均距离（全员推进度：后排不动就拖后腿）
function avgDistToBase(state, owner) {
  const eBase = owner === 0 ? state.map.cells.length - 1 : 0;
  let sum = 0, n = 0;
  for (let i = 0; i < state.map.cells.length; i++) {
    if (isOwnedUnit(state.map.cells[i], owner)) {
      sum += Math.abs(i - eBase);
      n++;
    }
  }
  return n ? sum / n : null;
}

function evaluate(state, me) {
  if (state.winner !== null && state.winner !== undefined) {
    return state.winner === me ? WIN_V : -WIN_V;
  }
  const e = 1 - me;
  // 敌方单位价值按 1.5 倍计（牢大定）：消灭敌方收益放大 → 进攻倾向增强
  const dVal = (sideValue(state, me) - 1.5 * sideValue(state, e)) / 100.0;
  let mxMe = 0, mxE = 0, uMe = 0, uE = 0;
  for (const c of state.map.cells) {
    if (isOwnedUnit(c, me)) { if (c.v > mxMe) mxMe = c.v; uMe++; }
    if (isOwnedUnit(c, e)) { if (c.v > mxE) mxE = c.v; uE++; }
  }
  const dMax = (mxMe - mxE) / 9.0;
  const dUnits = (uMe - uE) / 8.0;
  const dAp = (R.countOf(state, me, 9) - R.countOf(state, e, 9)) / 9.0;
  const dPp = (R.countOf(state, me, 8) - R.countOf(state, e, 8)) / 8.0;
  // 距离：前锋最近单位 + 全员平均推进 各一半（前锋敢摸，大部队跟得上）
  let dDist = 0.0;
  const a = nearestToBase(state, me);
  const b = nearestToBase(state, e);
  const am = avgDistToBase(state, me);
  const bm = avgDistToBase(state, e);
  if (a !== null && b !== null) dDist += ((b - a) / 16.0) * 0.5;
  if (am !== null && bm !== null) dDist += ((bm - am) / 16.0) * 0.5;
  const power = W_VAL * dVal + W_MAX * dMax + W_UNITS * dUnits + W_AP * dAp + W_PP * dPp + W_DIST * dDist;
  return Math.max(-WIN_V, Math.min(WIN_V, power));
}

// ── 候选动作（与训练端一致：过滤 choosePhase/endTurn + 手动补 produce）──
function candidates(state) {
  const me = state.turn;
  if (state.winner) return [[], true];
  const acts = [];
  if (state.phase === null) {
    for (const a of R.getLegalActions(state, me)) {
      if (a.type !== 'choosePhase' && a.type !== 'endTurn') acts.push(a);
    }
    const d = me === 0 ? 1 : -1;
    state.map.cells.forEach((c, i) => {
      if (c.o === me && c.v === 8) {
        const j = i + d;
        if (j >= 0 && j < state.map.cells.length && !state.map.cells[j].bridge) {
          acts.push({ type: 'produce', i, j });
        }
      }
    });
    return [acts, false];
  }
  for (const a of R.getLegalActions(state, me)) {
    if (a.type !== 'endTurn') acts.push(a);
  }
  return [acts, acts.length === 0];
}

// ── 应用动作 + 滚木推进；返回是否合法 ──
function applyAndRoll(state, owner, action) {
  const r = R.applyAction(state, owner, action, true);
  if (!r.ok) return false;
  while (R.hasPendingRoll(state)) {
    if (R.rollStepOnce(state, state.turn) === null) {
      R.clearPendingRoll(state);
      break;
    }
  }
  // 滚木可能触发终局（applyAction 内部已 checkWin，补查 sumOf=0 兜底）
  if (!state.winner) {
    if (R.sumOf(state, 0) === 0) state.winner = 1;
    else if (R.sumOf(state, 1) === 0) state.winner = 0;
  }
  return true;
}

// ── 启发式排序（剪枝友好）──
function heuristicScore(a, state, me) {
  const t = a.type;
  let s = 0;
  if (t === 'devour') {
    s = 100;
    const j = a.j !== undefined ? a.j : -1;
    if (j >= 0 && j < state.map.cells.length) s += state.map.cells[j].v * 3;
  } else if (t === 'attack') {
    s = 30;
    const j = a.j !== undefined ? a.j : -1;
    if (j >= 0 && j < state.map.cells.length) {
      const tv = state.map.cells[j].v;
      s += tv === 8 ? 80 : tv >= 7 ? 40 : tv >= 4 ? 15 : 5;
    }
  } else if (t === 'produce') {
    s = 12;
  } else if (t === 'move') {
    s = 6;
    const i = a.i !== undefined ? a.i : -1;
    const steps = a.steps !== undefined ? a.steps : 1;
    s += steps * 3;
    if (i >= 0 && i < state.map.cells.length) {
      s += me === 0 ? i * 0.1 : (state.map.cells.length - 1 - i) * 0.1;
    }
  } else if (t === 'split') {
    s = 1;
  }
  return s;
}

class AlphaBetaAi {
  constructor({ depth = 5, timeBudgetMs = 1500 } = {}) {
    this.depth = depth;
    this.timeBudgetMs = timeBudgetMs;
    this.nodes = 0;
    this._deadline = 0;
  }

  decide(state) {
    const me = state.turn;
    this._deadline = Date.now() + this.timeBudgetMs;
    this.nodes = 0;
    const [acts, mustEnd] = candidates(state);
    if (mustEnd || acts.length === 0) return { type: 'endTurn' };
    if (acts.length === 1) return acts[0];
    acts.sort((a, b) => heuristicScore(b, state, me) - heuristicScore(a, state, me));
    let bestA = null;
    let bestV = -1e18;
    for (const a of acts) {
      const g2 = cloneState(state);
      if (!applyAndRoll(g2, me, a)) continue;
      const v = this._search(g2, this.depth - 1, -1e18, 1e18, me);
      if (v > bestV) { bestV = v; bestA = a; }
    }
    return bestA || acts[0];
  }

  _search(state, depth, alpha, beta, me) {
    this.nodes++;
    if (state.winner !== null && state.winner !== undefined) {
      return state.winner === me ? WIN_V : -WIN_V;
    }
    if (depth <= 0) return evaluate(state, me);
    if (Date.now() > this._deadline) return evaluate(state, me); // 超时截断
    const owner = state.turn;
    const [acts, mustEnd] = candidates(state);
    if (mustEnd || acts.length === 0) {
      const g2 = cloneState(state);
      if (applyAndRoll(g2, owner, { type: 'endTurn' })) {
        return this._search(g2, depth - 1, alpha, beta, me);
      }
      return evaluate(state, me);
    }
    acts.sort((a, b) => heuristicScore(b, state, owner) - heuristicScore(a, state, owner));
    const isMax = owner === me;
    if (isMax) {
      let best = -1e18;
      for (const a of acts) {
        const g2 = cloneState(state);
        if (!applyAndRoll(g2, owner, a)) continue;
        const v = this._search(g2, depth - 1, alpha, beta, me);
        if (v > best) best = v;
        if (best > alpha) alpha = best;
        if (beta <= alpha) break;
      }
      return best;
    } else {
      let best = 1e18;
      for (const a of acts) {
        const g2 = cloneState(state);
        if (!applyAndRoll(g2, owner, a)) continue;
        const v = this._search(g2, depth - 1, alpha, beta, me);
        if (v < best) best = v;
        if (best < beta) beta = best;
        if (beta <= alpha) break;
      }
      return best;
    }
  }
}

module.exports = { AlphaBetaAi, evaluate, candidates, applyAndRoll, heuristicScore, sideValue, cloneState };
