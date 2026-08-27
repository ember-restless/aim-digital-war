// 房间游戏封装：房间状态机 + 规则引擎调用
'use strict';
const R = require('./rules');

class RoomGame {
  constructor(roomId, roomName, mode = 'online', password = null, title = null) {
    this.id = roomId;
    this.name = roomName || ('AIM-' + roomId);
    this.title = title || this.name;   // 房间名（可自定义，默认 AIM-N 或 服务器房间名）
    this.password = password || null;  // 房间密码（null=无密码）
    this.mode = mode;            // 'online' | 'hotseat'
    this.status = 'waiting'; // waiting | playing | ended
    this.players = [];       // [{ socketId, name, disconnected, ready }]（最多2，null 占位）
    this.spectators = [];    // 观战者 [{ socketId, name, disconnected }]
    this.state = null;
    this.limit = 16;
    this.allowOwnRollerAttack = true; // 规则开关：己方能否攻击己方滚木（创建房间时定，默认开）
    this.hostSide = 'left';  // 房主选的边
    this.roomOwnerSocket = null;
    // ── 训练数据记录（牢大定：真人对局 AI 都学）──
    this.recordMode = true;   // 联机/热座真人对局都记录双方棋谱
    this.recordSteps = [];
    this._recordFlushed = false;
    this.onRecorded = null;   // 对局结束回调（index.js 写 games.jsonl + 触发自动训练）
  }

  isHotseat() {
    return this.mode === 'hotseat';
  }

  addPlayer(socketId, name, index = null) {
    if (this.players.some(p => p && p.socketId === socketId)) return { ok: true };
    if (this.isHotseat()) {
      // 热座：一个连接占两个玩家位，轮流操作
      const idx = this.players.length;
      this.players.push({ socketId, name: name || '玩家1', disconnected: false, ready: false });
      if (idx === 0) this.players.push({ socketId, name: '玩家2', disconnected: false, ready: false });
      this.roomOwnerSocket = socketId;
      return { ok: true, playerIdx: idx };
    }
    // 指定位置（房主选边）或自动填空位
    const freeIdx = this.players.findIndex(p => !p);
    let idx;
    if (index !== null && !this.players[index]) {
      idx = index;
    } else if (freeIdx >= 0) {
      idx = freeIdx;
    } else if (this.players.length < 2) {
      idx = this.players.length;
    } else {
      // 玩家已满：仅对局中（playing）允许观战；等待中的房间不支持观战（牢大 2026-08-15 定）
      if (this.status === 'playing' && this.spectators.length < 8) {
        this.spectators.push({ socketId, name: name || '观战者', disconnected: false });
        return { ok: true, spectator: true };
      }
      return { ok: false, reason: '房间已满' };
    }
    this.players[idx] = { socketId, name: name || '玩家' + (idx + 1), disconnected: false, ready: false };
    if (!this.roomOwnerSocket) this.roomOwnerSocket = socketId;
    return { ok: true, playerIdx: idx };
  }

  setHostSide(side) {
    if (side === 'left' || side === 'right') this.hostSide = side;
  }

  removePlayer(socketId) {
    // 热座：一个连接占两个位置，断开时全清（热座无重连）
    if (this.isHotseat() && this.players.some(p => p && p.socketId === socketId)) {
      this.players[0] = null;
      this.players[1] = null;
      this.roomOwnerSocket = null;
      return;
    }
    const idx = this.players.findIndex(p => p && p.socketId === socketId);
    if (idx >= 0) {
      if (this.status === 'playing' && this.state && !this.state.winner) {
        // 对局中掉线：标记 disconnected，座位保留，等重连（30s 超时判负由 tick 处理）
        this.players[idx].disconnected = true;
        this.players[idx].disconnectAt = Date.now();
        this.state.log.push(`玩家${idx}断线，等待重连…`);
        return;
      }
      // waiting / 已结束：直接移除座位
      this.players[idx] = null;
      if (this.roomOwnerSocket === socketId) {
        const first = this.players.find(p => p);
        this.roomOwnerSocket = first ? first.socketId : null;
      }
      return;
    }
    const si = this.spectators.findIndex(p => p.socketId === socketId);
    if (si >= 0) this.spectators.splice(si, 1);
  }

  // 断线重连：playing 状态 + 该座位 disconnected + 名字匹配 → 恢复
  tryReconnect(socketId, name, idx) {
    if (this.status !== 'playing' || !this.state || this.state.winner !== null) {
      return { ok: false, reason: '对局已结束' };
    }
    const p = this.players[idx];
    if (!p || !p.disconnected) return { ok: false, reason: '该座位不在重连状态' };
    if (p.name !== name) return { ok: false, reason: '名字不匹配，无法重连' };
    p.socketId = socketId;
    p.disconnected = false;
    p.disconnectAt = null;
    this.state.log.push(`玩家${idx}重连成功`);
    return { ok: true, playerIdx: idx };
  }

  // 周期检查（index.js 全局 5s 定时器驱动）：掉线 30s 超时判负；当前回合方掉线 15s 自动过回合
  // 返回是否有变化（调用方负责 broadcast）
  tick() {
    if (this.status !== 'playing' || !this.state || this.state.winner !== null) return false;
    const now = Date.now();
    let changed = false;
    // 掉线超时（30s）→ 判负
    for (let i = 0; i < this.players.length; i++) {
      const p = this.players[i];
      if (p && p.disconnected && now - p.disconnectAt > 30000) {
        this.state.winner = 1 - i;
        this.state.log.push(`玩家${i}掉线超时，玩家${1 - i}获胜`);
        this.status = 'ended';
        this._flushRecord();
        changed = true;
      }
    }
    if (this.state.winner !== null) return changed;
    // 当前回合方掉线（15s）→ 自动过回合，游戏不卡死（全量滚，客户端走 rollSteps 回放兜底）
    const cur = this.players[this.state.turn];
    if (cur && cur.disconnected && now - cur.disconnectAt > 15000) {
      const r = R.applyAction(this.state, this.state.turn, { type: 'endTurn' });
      if (r.ok) {
        this.state.log.push(`玩家${this.state.turn}掉线，自动过回合`);
        changed = true;
        if (this.state.winner !== null) this.status = 'ended';
      }
    }
    return changed;
  }

  isFull() { return this.players.length >= 2; }

  // 房主踢人：把玩家移出房间
  kickPlayer(socketId) {
    if (this.isHotseat()) return false;
    const idx = this.players.findIndex(p => p && p.socketId === socketId);
    if (idx < 0) return false;
    this.players[idx] = null;
    return true;
  }

  // 玩家准备/取消准备
  setReady(socketId, ready) {
    const p = this.players.find(q => q && q.socketId === socketId);
    if (!p) return false;
    p.ready = !!ready;
    return true;
  }

  // 全员准备检查：非房主玩家必须都 ready（热座/单人不需要）
  allReady() {
    if (this.isHotseat()) return true;
    return this.players.every(p => !p || p.socketId === this.roomOwnerSocket || p.ready);
  }

  start(limit) {
    if (this.status !== 'waiting') return { ok: false, reason: '游戏已开始' };
    const need = this.isHotseat() ? 1 : 2;
    const count = this.players.filter(p => p).length;
    if (count < need) return { ok: false, reason: '需要两名玩家' };
    if (!this.allReady()) return { ok: false, reason: '有玩家未准备' };
    if (limit && [12, 14, 16].includes(limit)) this.limit = limit;
    this.state = R.createGame({
      limit: this.limit,
      allowOwnRollerAttack: this.allowOwnRollerAttack,
    });
    this.status = 'playing';
    return { ok: true };
  }

  isSpectator(socketId) {
    return this.spectators.some(p => p.socketId === socketId);
  }

  // 观战者视角
  viewForSpectator() {
    const s = this.state;
    if (!s) return null;
    return {
      cells: s.map.cells.map(c => ({ ...c })),
      mapLen: s.map.cells.length,
      limit: s.map.limit,
      turn: s.turn,
      phase: s.phase,
      points: s.points,
      produceLeft: s.produceLeft,
      winner: s.winner,
      yourIdx: -1,
      names: this.players.map(p => (p ? p.name : '空位')),
      hotseat: false,
      spectator: true,
      mySum: 0,
      enemySum: 0,
      myBases: 0,
      myHqs: 0,
      sums: [R.sumOf(s, 0), R.sumOf(s, 1)],
      bases: [R.countOf(s, 0, 8), R.countOf(s, 1, 8)],
      hqs: [R.countOf(s, 0, 9), R.countOf(s, 1, 9)],
      legalActions: [],
      log: s.log.slice(-8),
      lastAction: s.lastAction || null,
      lastSeq: s.lastSeq || 0,
      rollSteps: s.rollSteps || null,
      rollSeq: s.rollSeq || 0,
      rollPending: s._pendingRoll || s._rsActive,
      rollActs: s._lastRollActs || null,
      rollStepSeq: s._rollStepSeq || 0,
      stats: s.stats || { kills: [0, 0], losses: [0, 0], produce: [0, 0] },
      turnCount: s.turnCount || 0,
    };
  }

  // 玩家执行行动（服务端权威判定；手动 endTurn 延后滚木 → 逐步驱动，对齐热座）
  handleAction(playerIdx, action) {
    // 操作前快照（训练记录用；与训练场 local_socket 同格式）
    // 桥格子没有 v 字段（undefined）→ 记 0，与训练端 AimCell.v=0 语义一致
    const snapTurn = this.state.turn, snapPhase = this.state.phase;
    const snapPoints = this.state.points, snapProduce = this.state.produceLeft;
    const snapCells = this.state.map.cells.map(c =>
      [c.v ?? 0, c.o ?? -1, c.bridge ? 1 : 0, c.onBridge ? 1 : 0, c.auto ? 1 : 0]);
    const res = R.applyAction(this.state, playerIdx, action, true);
    if (!res.ok) return res;
    if (this.recordMode && this.state) {
      // 记录操作前状态 + 动作 + 操作者（含最后一步；滚木自动结算不记录，与训练数据一致）
      this.recordSteps.push({
        cells: snapCells, turn: snapTurn, phase: snapPhase,
        points: snapPoints, produceLeft: snapProduce,
        action, owner: playerIdx,
      });
    }
    if (this.state.winner !== null) {
      this.status = 'ended';
      this._flushRecord();
    }
    return res;
  }

  // 滚木逐步驱动：规则算一步 → 动画播一步（客户端播完发 roll_step）
  // 返回该步基础动作序列；全部滚完返回 null
  handleRollStep() {
    if (!this.state) return null;
    const acts = R.rollStepOnce(this.state, this.state.turn);
    if (acts == null) R.clearPendingRoll(this.state);
    if (this.state.winner !== null) {
      this.status = 'ended';
      this._flushRecord();
    }
    return acts;
  }

  // 对局结束：把双方棋谱交给 index.js（写 games.jsonl + 触发自动训练，AI 都学）
  _flushRecord() {
    if (!this.recordMode || this._recordFlushed || this.recordSteps.length === 0) return;
    this._recordFlushed = true;
    if (this.onRecorded) {
      this.onRecorded({
        winner: this.state.winner,
        turns: this.state.turnCount || 0,
        limit: this.limit,
        steps: this.recordSteps,
      });
    }
    this.recordSteps = [];
  }

  // 待滚滚木（deferRoll 模式：endTurn 后还没滚完）
  hasPendingRoll() {
    return this.state ? R.hasPendingRoll(this.state) : false;
  }

  // 玩家视角快照
  viewFor(playerIdx) {
    const s = this.state;
    if (!s) return null;
    const mine = playerIdx === s.turn;
    return {
      cells: s.map.cells.map(c => ({ ...c })),
      mapLen: s.map.cells.length,
      limit: s.map.limit,
      turn: s.turn,
      phase: s.phase,
      points: s.points,
      produceLeft: s.produceLeft,
      winner: s.winner,
      yourIdx: playerIdx,
      names: this.players.map(p => (p ? p.name : '空位')),
      hotseat: this.isHotseat(),
      mySum: R.sumOf(s, playerIdx),
      enemySum: R.sumOf(s, 1 - playerIdx),
      myBases: R.countOf(s, playerIdx, 8),
      myHqs: R.countOf(s, playerIdx, 9),
      legalActions: mine ? R.getLegalActions(s, playerIdx) : [],
      log: s.log.slice(-8),
      lastAction: s.lastAction || null,
      lastSeq: s.lastSeq || 0,
      rollSteps: s.rollSteps || null,
      rollSeq: s.rollSeq || 0,
      rollPending: s._pendingRoll || s._rsActive,
      rollActs: s._lastRollActs || null,
      rollStepSeq: s._rollStepSeq || 0,
      stats: s.stats || { kills: [0, 0], losses: [0, 0], produce: [0, 0] },
      turnCount: s.turnCount || 0,
    };
  }

  publicState() {
    return {
      id: this.id,
      title: this.title,
      name: this.name,
      status: this.status,
      mode: this.mode,
      limit: this.limit,
      allowOwnRollerAttack: this.allowOwnRollerAttack,
      hostSide: this.hostSide,
      hostIdx: this.players.findIndex(p => p && p.socketId === this.roomOwnerSocket),
      hasPassword: !!this.password,
      players: this.players.map(p => (p ? { name: p.name, disconnected: p.disconnected, ready: !!p.ready } : null)),
      spectators: this.spectators.map(p => ({ name: p.name, disconnected: p.disconnected })),
    };
  }
}

module.exports = { RoomGame };
