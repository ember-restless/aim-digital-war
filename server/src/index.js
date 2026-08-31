// AIM 数字大战 — 联机服务器
// 单端口 5000：游戏（Socket.io）+ 下载页（静态）+ /api/version 一体
// ⚠️ 3000 是 math（Graphwar）的端口，勿动
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { Server } = require('socket.io');
const { RoomGame } = require('./game/RoomGame');

// ── αβ 剪枝 AI（战斗测试：人机/AI 对战）──
const abRules = require('./game/rules');
const { AlphaBetaAi, candidates, applyAndRoll, sideValue } = require('./game/ab_ai');

function abGameToJson(s) {
  return {
    cells: s.map.cells.map((c) => ({
      v: c.v, o: c.o === undefined ? null : c.o,
      bridge: !!c.bridge, onBridge: !!c.onBridge, auto: !!c.auto,
      pressedV: c.pressedV === undefined ? null : c.pressedV,
      pressedO: c.pressedO === undefined ? null : c.pressedO,
    })),
    turn: s.turn, phase: s.phase, points: s.points, produceLeft: s.produceLeft,
    turnCount: s.turnCount, winner: s.winner === undefined ? null : s.winner,
    limit: s.map.limit,
  };
}

function abJsonToGame(j) {
  const s = abRules.createGame({ limit: (j && j.limit) || 16 });
  s.map.cells = (j.cells || []).map((c) => ({
    v: c.v, o: c.o === null || c.o === undefined ? null : c.o,
    bridge: !!c.bridge, onBridge: !!c.onBridge, auto: !!c.auto,
    pressedV: c.pressedV === null || c.pressedV === undefined ? null : c.pressedV,
    pressedO: c.pressedO === null || c.pressedO === undefined ? null : c.pressedO,
  }));
  s.turn = j.turn; s.phase = j.phase; s.points = j.points || 0;
  s.produceLeft = j.produceLeft || 0; s.turnCount = j.turnCount || 0;
  s.winner = j.winner === undefined ? null : j.winner;
  return s;
}

function abActDesc(owner, a, g) {
  const t = a.type;
  const tag = 'P' + owner;
  if (t === 'endTurn') return tag + ' 结束回合';
  if (t === 'choosePhase') return tag + ' 选择阶段 ' + a.phase;
  const i = a.i !== undefined ? a.i : -1;
  const v = (i >= 0 && i < g.map.cells.length) ? g.map.cells[i].v : '?';
  const d = owner === 0 ? '右' : '左';
  if (t === 'move') return `${tag} 单位@${i}(${v}) 向${d}走${a.steps !== undefined ? a.steps : 1}格`;
  if (t === 'attack') {
    const j = a.j !== undefined ? a.j : -1;
    const tv = (j >= 0 && j < g.map.cells.length) ? g.map.cells[j].v : '?';
    return `${tag} 单位@${i}(${v}) 攻击 @${j}(${tv})`;
  }
  if (t === 'devour') {
    const j = a.j !== undefined ? a.j : -1;
    const tv = (j >= 0 && j < g.map.cells.length) ? g.map.cells[j].v : '?';
    return `${tag} 单位@${i}(${v}) 吞噬 @${j}(${tv}) → ${v + tv}`;
  }
  if (t === 'split') return `${tag} 单位@${i}(${v}) 拆分为 ${a.a}+${a.b}`;
  if (t === 'produce') return `${tag} 基地@${i}(8) 造兵`;
  return tag + ' ' + JSON.stringify(a);
}

function abMakeAi(name, depth, tb) {
  if (name === 'ab') return new AlphaBetaAi({ depth: depth || 5, timeBudgetMs: tb !== undefined ? tb : 1500 });
  // 规则 AI（easy/normal/hard）：JS 简易启发式
  return { name, decide: (s) => abRuleDecide(s, name) };
}

// 简易 JS 规则 AI（对应客户端 ai.dart 的 easy/normal/hard 简化版）
function abRuleDecide(state, level) {
  const owner = state.turn;
  const [playable] = candidates(state); // 含手动补的 produce（防拆基地）
  if (playable.length === 0) return { type: 'endTurn' };
  if (level === 'easy') {
    return playable[Math.floor(Math.random() * playable.length)];
  }
  playable.sort((x, y) => abRuleScore(state, owner, y) - abRuleScore(state, owner, x));
  return playable[0];
}

function abRuleScore(state, owner, a) {
  const t = a.type;
  let s = 0;
  const cells = state.map.cells;
  if (t === 'attack') {
    const j = a.j;
    const tv = cells[j] ? cells[j].v : 0;
    s = tv * 2 + (tv === 8 ? 120 : 0) + (tv === 9 ? 200 : 0) + (tv === 7 ? 60 : 0);
    if (tv <= (a.v >= 4 ? a.v : 1)) s += 150;
  } else if (t === 'devour') {
    const j = a.j;
    const tv = cells[j] ? cells[j].v : 0;
    const total = (cells[a.i] ? cells[a.i].v : 0) + tv;
    s = (total >= 9 ? 400 : total === 8 ? 250 : total >= 6 ? 120 : 0) + (cells[j] && cells[j].o !== owner ? tv * 4 : 0);
  } else if (t === 'move') {
    s = 10 + (owner === 0 ? a.i : cells.length - 1 - a.i) * 2;
  } else if (t === 'produce') {
    s = 8;
  } else if (t === 'split') {
    s = -40;
  }
  return s;
}

function abSendJson(res, data) {
  const body = JSON.stringify(data);
  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function abReadBody(req, cb) {
  let data = '';
  req.on('data', (c) => { data += c; if (data.length > 1e6) req.destroy(); });
  req.on('end', () => {
    try { cb(JSON.parse(data || '{}')); } catch (e) { cb({}); }
  });
}

function handleAbApi(pathname, req, res) {
  console.error(`[ab-api] ${new Date().toISOString()} ${req.method} ${pathname} from ${req.socket.remoteAddress}`);
  if (pathname === '/api/ab/new') {
    const st = abGameToJson(abRules.createGame({ limit: 16 }));
    st._ver = 'AB-V3-1300';
    abSendJson(res, st);
    return;
  }
  if (pathname === '/api/ab/legal' && req.method === 'POST') {
    abReadBody(req, (body) => {
      try {
        const g = abJsonToGame(body.state);
        const owner = g.turn;
        const [acts, mustEnd] = candidates(g);
        const out = acts.map((a) => ({ action: a, desc: abActDesc(owner, a, g) }));
        abSendJson(res, { ok: true, owner, actions: out, mustEnd: mustEnd || acts.length === 0, state: abGameToJson(g) });
      } catch (e) { abSendJson(res, { ok: false, msg: 'legal 失败: ' + e.message }); }
    });
    return;
  }
  if (pathname === '/api/ab/act' && req.method === 'POST') {
    abReadBody(req, (body) => {
      try {
        const g = abJsonToGame(body.state);
        const owner = g.turn;
        const ok = applyAndRoll(g, owner, body.action);
        if (!ok) { abSendJson(res, { ok: false, msg: '操作不合法', state: body.state }); return; }
        const desc = abActDesc(owner, body.action, g);
        let aiResp = null;
        const aiSide = body.ai_side;
        if (aiSide !== undefined && aiSide !== null && !g.winner && g.turn === aiSide) {
          const ai = abMakeAi(body.ai || 'ab', body.depth, body.tb);
          const a2 = ai.decide(g);
          if (a2) {
            const ok2 = applyAndRoll(g, aiSide, a2);
            aiResp = { action: a2, desc: abActDesc(aiSide, a2, g), ok: ok2 };
          }
        }
        abSendJson(res, { ok: true, state: abGameToJson(g), desc, ai: aiResp });
      } catch (e) { abSendJson(res, { ok: false, msg: 'act 失败: ' + e.message }); }
    });
    return;
  }
  if (pathname === '/api/ab/ai_act' && req.method === 'POST') {
    abReadBody(req, (body) => {
      try {
        const g = abJsonToGame(body.state);
        const owner = g.turn;
        const ai = abMakeAi(body.ai || 'ab', body.depth, body.tb);
        const a = ai.decide(g);
        const ok = a && applyAndRoll(g, owner, a);
        abSendJson(res, {
          ok: !!ok, action: ok ? a : null,
          desc: ok ? abActDesc(owner, a, g) : '无动作',
          state: abGameToJson(g), winner: g.winner,
        });
      } catch (e) { abSendJson(res, { ok: false, msg: 'ai_act 失败: ' + e.message }); }
    });
    return;
  }
  abSendJson(res, { ok: false, msg: 'unknown ab api' });
}


const DOWNLOAD_PORT = 5000;
const DOWNLOAD_DIR = path.join(__dirname, '..', 'public', 'downloads');
const CFG = require('./config.js');
const VERSION = CFG.APP_VERSION;


// ---------- 游戏服务器（Socket.io 挂到单端口 server，定义在后面） ----------
const io = new Server({ cors: { origin: '*' } });

const rooms = new Map(); // roomId -> RoomGame
const socketRoom = new Map(); // socketId -> { roomId, playerIdx }
const socketName = new Map(); // socketId -> name
// 在线管理：socketId -> { name, status: 'lobby' | 'room:<id>' }
const online = new Map();
// 目录注册：serverId -> { name, host, port, players, maxPlayers, version, desc, ts }
const directory = new Map();
let roomSeq = 1000;
let serverSeq = 1;

function genRoomId() {
  return 'A' + (roomSeq++);
}

function onlineCount() {
  return online.size;
}

// 广播在线玩家列表（大厅右侧「在线的人」）
function broadcastOnline() {
  const list = [...online.entries()].map(([sid, info]) => ({
    name: info.name,
    status: info.status,
    roomId: info.status.startsWith('room:') ? info.status.slice(5) : null,
  }));
  io.emit('player_list', list);
}

// 系统消息进大厅聊天框
function sysMsg(text) {
  io.emit('chat', { name: '系统', msg: text, sys: true });
}

// 更新某人的在线状态并广播
function setStatus(socketId, status) {
  const info = online.get(socketId);
  if (!info) return;
  info.status = status;
  broadcastOnline();
}

function broadcastRoom(room) {
  const pub = room.publicState();
  for (const p of room.players) {
    if (p) io.to(p.socketId).emit('room_update', pub);
  }
  for (const sp of room.spectators) {
    io.to(sp.socketId).emit('room_update', pub);
  }
}

function broadcastGame(room) {
  if (room.isHotseat()) {
    // 热座：只发当前回合玩家的视角（同一设备轮流操作）
    const p0 = room.players[0];
    if (p0) io.to(p0.socketId).emit('game_state', room.viewFor(room.state.turn));
  } else {
    for (let i = 0; i < room.players.length; i++) {
      const p = room.players[i];
      if (p) io.to(p.socketId).emit('game_state', room.viewFor(i));
    }
  }
  // 观战者：完整棋盘视角（无操作权）
  const specView = room.viewForSpectator();
  if (specView) {
    for (const sp of room.spectators) {
      io.to(sp.socketId).emit('game_state', specView);
    }
  }
}

io.on('connection', (socket) => {
  // ── 进服：报名字 + 占在线名额（人数上限保护）──
  socket.on('hello', ({ name, version } = {}) => {
    if (online.has(socket.id)) {
      socket.emit('error', { msg: '重复连接' });
      return;
    }
    if (onlineCount() >= CFG.SERVER_MAX_PLAYERS) {
      socket.emit('error', { msg: `服务器已满（${CFG.SERVER_MAX_PLAYERS} 人），稍后再试` });
      socket.disconnect(true);
      return;
    }
    const n = String(name || '玩家').slice(0, 12);
    online.set(socket.id, { name: n, status: 'lobby' });
    socketName.set(socket.id, n);
    socket.emit('hello_ok', { name: n, server: { name: CFG.SERVER_NAME, maxPlayers: CFG.SERVER_MAX_PLAYERS, online: onlineCount() } });
    sysMsg(`「${n}」连接了服务器`);
    broadcastOnline();
    // 连上来先拉一次房间列表
    const list = [...rooms.values()]
      .filter(r => r.status === 'waiting' || r.status === 'playing')
      .map(r => r.publicState());
    socket.emit('room_list', list);
  });

  socket.on('create_room', ({ name, limit, mode, side, password, title, allowOwnRollerAttack } = {}) => {
    if (socketRoom.has(socket.id)) {
      socket.emit('error', { msg: '你已经在房间里了' });
      return;
    }
    const room = new RoomGame(genRoomId(), 'AIM-' + roomSeq, mode === 'hotseat' ? 'hotseat' : 'online',
      password ? String(password).slice(0, 12) : null,
      title ? String(title).slice(0, 16) : null);
    room.allowOwnRollerAttack = allowOwnRollerAttack !== false; // 规则开关：默认开（保持「敌我皆可」）
    if (side === 'right') room.setHostSide('right');
    const idx = room.isHotseat() ? 0 : (side === 'right' ? 1 : 0);
    const res = room.addPlayer(socket.id, name, idx);
    if (!res.ok) { socket.emit('error', { msg: res.reason }); return; }
    socketName.set(socket.id, name || '玩家1');
    if (online.has(socket.id)) online.get(socket.id).name = name || '玩家1';
    rooms.set(room.id, room);
    socketRoom.set(socket.id, { roomId: room.id, playerIdx: res.playerIdx });
    socket.join(room.id);
    setStatus(socket.id, 'room:' + room.id);
    socket.emit('room_update', room.publicState());
    socket.emit('you_are', { roomId: room.id, playerIdx: res.playerIdx });
    sysMsg(`「${socketName.get(socket.id)}」创建了房间「${room.title}」`);
  });

  socket.on('join_room', ({ roomId, name, password, reconnectIdx } = {}) => {
    if (socketRoom.has(socket.id)) {
      socket.emit('error', { msg: '你已经在房间里了' });
      return;
    }
    const room = rooms.get(roomId);
    if (!room) { socket.emit('error', { msg: '房间不存在' }); return; }
    // 密码验证（加入/观战/重连都要）
    if (room.password && room.password !== String(password || '')) {
      socket.emit('error', { msg: '密码错误' });
      return;
    }
    // ── 断线重连：playing 状态 + reconnectIdx → 恢复原座位 ──
    if (typeof reconnectIdx === 'number' && reconnectIdx >= 0 && room.status === 'playing') {
      const rc = room.tryReconnect(socket.id, name, reconnectIdx);
      if (!rc.ok) { socket.emit('error', { msg: rc.reason }); return; }
      socketName.set(socket.id, name || '玩家' + (rc.playerIdx + 1));
      if (online.has(socket.id)) online.get(socket.id).name = name || '玩家' + (rc.playerIdx + 1);
      socketRoom.set(socket.id, { roomId: room.id, playerIdx: rc.playerIdx });
      socket.join(room.id);
      setStatus(socket.id, 'room:' + room.id);
      socket.emit('you_are', { roomId: room.id, playerIdx: rc.playerIdx });
      socket.emit('room_update', room.publicState());
      broadcastRoom(room);
      // 立即恢复棋盘视角（含观战者不需要）
      if (room.state) socket.emit('game_state', room.viewFor(rc.playerIdx));
      if (room.state && room.state.winner !== null) {
        socket.emit('game_over', {
          winner: room.state.winner,
          winnerName: room.players[room.state.winner] ? room.players[room.state.winner].name : null,
        });
      }
      sysMsg(`「${name}」重连回房间「${room.title}」`);
      return;
    }
    const res = room.addPlayer(socket.id, name);
    if (!res.ok) { socket.emit('error', { msg: res.reason }); return; }
    socketName.set(socket.id, name || '玩家2');
    if (online.has(socket.id)) online.get(socket.id).name = name || '玩家2';
    socketRoom.set(socket.id, { roomId: room.id, playerIdx: res.playerIdx == null ? -1 : res.playerIdx });
    socket.join(room.id);
    if (res.spectator) {
      socket.emit('you_are', { roomId: room.id, playerIdx: -1, spectator: true });
      // 观战已开始的房间：立即推送当前棋盘
      if (room.state) {
        socket.emit('game_state', room.viewForSpectator());
      }
      setStatus(socket.id, 'room:' + room.id);
    } else {
      socket.emit('you_are', { roomId: room.id, playerIdx: res.playerIdx });
      setStatus(socket.id, 'room:' + room.id);
    }
    socket.emit('room_update', room.publicState());
    // 通知房主和其他玩家
    broadcastRoom(room);
    sysMsg(`「${socketName.get(socket.id)}」${res.spectator ? '进入观战' : '加入'}了房间「${room.title}」`);
  });

  // ── 房主踢人 ──
  socket.on('kick', ({ roomId, targetSocketId, targetIdx } = {}) => {
    const info = socketRoom.get(socket.id);
    const room = rooms.get(roomId || (info && info.roomId));
    if (!room || room.roomOwnerSocket !== socket.id || room.status !== 'waiting') return;
    // 支持按玩家索引踢（客户端拿不到对方 socketId，用 targetIdx）
    let target = targetSocketId;
    if (!target && typeof targetIdx === 'number') {
      const p = room.players[targetIdx];
      if (p) target = p.socketId;
    }
    if (!target || !room.kickPlayer(target)) return;
    const tinfo = socketRoom.get(target);
    if (tinfo && tinfo.roomId === room.id) {
      socketRoom.delete(target);
      io.to(target).emit('kicked', { roomId: room.id });
      setStatus(target, 'lobby');
    }
    broadcastRoom(room);
    sysMsg(`玩家被移出了房间「${room.title}」`);
  });

  // ── 房主设置地图长度（不开始，仅预设）──
  socket.on('set_limit', ({ roomId, limit } = {}) => {
    const info = socketRoom.get(socket.id);
    const room = rooms.get(roomId || (info && info.roomId));
    if (!room || room.roomOwnerSocket !== socket.id || room.status !== 'waiting') return;
    if (![12, 14, 16].includes(limit)) return;
    room.limit = limit;
    broadcastRoom(room);
  });

  // ── 准备/取消准备 ──
  socket.on('ready', ({ roomId, ready } = {}) => {
    const info = socketRoom.get(socket.id);
    const room = rooms.get(roomId || (info && info.roomId));
    if (!room || room.status !== 'waiting') return;
    if (!room.setReady(socket.id, !!ready)) return;
    broadcastRoom(room);
  });

  socket.on('set_side', ({ roomId, side } = {}) => {
    const info = socketRoom.get(socket.id);
    const room = rooms.get(roomId || (info && info.roomId));
    if (!room || room.roomOwnerSocket !== socket.id || room.status !== 'waiting') return;
    if (side !== 'left' && side !== 'right') return;
    const wantRight = side === 'right';
    if (wantRight !== (room.hostSide === 'right')) {
      if (!room.isHotseat() && room.players[0] && room.players[1]) {
        const tmp = room.players[0];
        room.players[0] = room.players[1];
        room.players[1] = tmp;
        for (const [sid, i2] of socketRoom) {
          if (i2.roomId === room.id && i2.playerIdx >= 0) {
            i2.playerIdx = 1 - i2.playerIdx;
          }
        }
        for (let i = 0; i < 2; i++) {
          if (room.players[i]) io.to(room.players[i].socketId).emit('you_are', { roomId: room.id, playerIdx: i });
        }
      }
      room.setHostSide(side);
    }
    broadcastRoom(room);
  });

  socket.on('list_rooms', () => {
    const list = [...rooms.values()]
      .filter(r => {
        if (r.status === 'waiting') return true;
        if (r.status === 'playing') return true; // 进行中可观战
        return false;
      })
      .map(r => r.publicState());
    socket.emit('room_list', list);
  });

  // 主动拉在线列表（客户端进大厅/定时刷新用，不依赖 hello 时的推送）
  socket.on('list_players', () => {
    const list = [...online.entries()].map(([sid, info]) => ({
      name: info.name,
      status: info.status,
      roomId: info.status.startsWith('room:') ? info.status.slice(5) : null,
    }));
    socket.emit('player_list', list);
  });

  socket.on('start_game', ({ limit } = {}) => {
    const info = socketRoom.get(socket.id);
    if (!info) { socket.emit('error', { msg: '不在房间' }); return; }
    const room = rooms.get(info.roomId);
    if (!room) return;
    if (room.roomOwnerSocket !== socket.id) { socket.emit('error', { msg: '只有房主能开始' }); return; }
    const res = room.start(limit);
    if (!res.ok) { socket.emit('error', { msg: res.reason }); return; }
    broadcastGame(room);
  });

  socket.on('action', (action) => {
    const info = socketRoom.get(socket.id);
    if (!info) { socket.emit('error', { msg: '不在房间' }); return; }
    const room = rooms.get(info.roomId);
    if (!room || room.status !== 'playing' || !room.state) { socket.emit('error', { msg: '游戏未开始' }); return; }
    if (info.playerIdx == null || info.playerIdx < 0) { socket.emit('error', { msg: '观战者不能操作' }); return; }
    // 热座：同一设备轮流，视为当前回合方的操作
    const playerIdx = room.isHotseat() ? room.state.turn : info.playerIdx;
    const res = room.handleAction(playerIdx, action);
    if (!res.ok) {
      socket.emit('error', { msg: res.reason });
      return;
    }
    if (res.repeatWarn) {
      // 第 2 次重复：提示该玩家「再重复一次将判负」（象棋式规则）
      socket.emit('repeat_warn', {});
    }
    broadcastGame(room);
    if (room.status === 'ended') {
      for (const p of room.players) {
        if (p) io.to(p.socketId).emit('game_over', {
          winner: room.state.winner,
          winnerName: room.players[room.state.winner] ? room.players[room.state.winner].name : null,
        });
      }
      for (const sp of room.spectators) {
        io.to(sp.socketId).emit('game_over', {
          winner: room.state.winner,
          winnerName: room.players[room.state.winner] ? room.players[room.state.winner].name : null,
        });
      }
    }
  });

  // 滚木逐步驱动：客户端播完一步动画后请求下一步（对齐热座 roll_step 协议，2026-08-21）
  socket.on('roll_step', () => {
    const info = socketRoom.get(socket.id);
    if (!info) { socket.emit('error', { msg: '不在房间' }); return; }
    const room = rooms.get(info.roomId);
    if (!room || room.status !== 'playing' || !room.state) { socket.emit('error', { msg: '游戏未开始' }); return; }
    room.handleRollStep();
    broadcastGame(room);
    if (room.status === 'ended') {
      for (const p of room.players) {
        if (p) io.to(p.socketId).emit('game_over', {
          winner: room.state.winner,
          winnerName: room.players[room.state.winner] ? room.players[room.state.winner].name : null,
        });
      }
      for (const sp of room.spectators) {
        io.to(sp.socketId).emit('game_over', {
          winner: room.state.winner,
          winnerName: room.players[room.state.winner] ? room.players[room.state.winner].name : null,
        });
      }
    }
  });

  socket.on('leave_room', () => {
    const info = socketRoom.get(socket.id);
    if (!info) return;
    const room = rooms.get(info.roomId);
    socketRoom.delete(socket.id);
    setStatus(socket.id, 'lobby');
    if (room) {
      room.removePlayer(socket.id);
      const alive = room.players.filter(p => p).length + room.spectators.length;
      if (alive === 0) {
        rooms.delete(room.id);
        sysMsg(`房间「${room.title}」已解散`);
      } else {
        broadcastRoom(room);
        if (room.state && room.state.winner !== null) {
          broadcastGame(room);
        }
      }
    }
  });

  socket.on('disconnect', () => {
    const info = socketRoom.get(socket.id);
    const name = socketName.get(socket.id) || '玩家';
    socketRoom.delete(socket.id);
    socketName.delete(socket.id);
    const wasOnline = online.delete(socket.id);
    if (wasOnline) {
      sysMsg(`「${name}」断开了连接`);
      broadcastOnline();
    }
    if (!info) return;
    const room = rooms.get(info.roomId);
    if (!room) return;
    room.removePlayer(socket.id);
    // 活跃 = 未掉线玩家 + 观战者（掉线座位保留等重连，playing 全掉线也不解散，等 tick 超时判负）
    const alive = room.players.filter(p => p && !p.disconnected).length + room.spectators.length;
    if (room.status !== 'playing' && alive === 0) {
      rooms.delete(room.id);
      sysMsg(`房间「${room.title}」已解散`);
    } else {
      broadcastRoom(room);
      if (room.state && room.state.winner !== null) {
        broadcastGame(room);
        for (const p of room.players) {
          if (p) io.to(p.socketId).emit('game_over', {
            winner: room.state.winner,
            winnerName: room.players[room.state.winner] ? room.players[room.state.winner].name : null,
          });
        }
      }
    }
  });

  // ── 大厅全局聊天（所有在线的人都能看到；系统消息也走这里）──
  socket.on('chat', ({ msg } = {}) => {
    const name = socketName.get(socket.id) || '玩家';
    const m = String(msg || '').trim().slice(0, 200);
    if (!m) return;
    io.emit('chat', { name, msg: m });
  });

  // ── 对局内快捷消息（Kards 式）：只发给同房间的玩家/观战，不打扰大厅 ──
  socket.on('ingame_chat', ({ msg } = {}) => {
    const name = socketName.get(socket.id) || '玩家';
    const m = String(msg || '').trim().slice(0, 40);
    if (!m) return;
    const info = socketRoom.get(socket.id);
    if (!info) return;
    const room = rooms.get(info.roomId);
    if (!room) return;
    const targets = [...room.players, ...room.spectators].filter(p => p && p.socketId !== socket.id);
    for (const p of targets) io.to(p.socketId).emit('ingame_chat', { name, msg: m });
  });
});

const APP_VERSION_CODE = require('./config.js').APP_VERSION_CODE;
const DOWNLOAD_PAGE = 'http://192.140.166.178:5000/';

// ---------- 单端口服务器（5000）：/api/version + 静态下载页 ----------
const mime = {
  '.html': 'text/html; charset=utf-8',
  '.apk': 'application/vnd.android.package-archive',
  '.zip': 'application/zip',
  '.md': 'text/plain; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.css': 'text/css; charset=utf-8',
  '.bin': 'application/octet-stream',
  '.dat': 'application/octet-stream',
};

const dlServer = http.createServer((req, res) => {
  const pathname = (req.url || '/').split('?')[0];
  if (pathname === '/api/version') {
    // 客户端自动检查更新用
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      name: 'AIM 数字大战',
      version: VERSION,
      versionCode: APP_VERSION_CODE,
      downloadPage: DOWNLOAD_PAGE,
      apkUrl: DOWNLOAD_PAGE + 'downloads/aim.apk',
      winUrl: DOWNLOAD_PAGE + 'downloads/aim-web.zip',
    }));
    return;
  }
  // ── 服务器目录：公开服务器列表（客户端自动选服 + 手动选择用）──
  if (pathname === '/api/servers') {
    const now = Date.now();
    // 官方服务器自己（客户端内置地址，永远在列表第一位）
    const self = {
      id: 'official',
      name: CFG.SERVER_NAME,
      host: '192.140.166.178',
      port: DOWNLOAD_PORT,
      players: onlineCount(),
      maxPlayers: CFG.SERVER_MAX_PLAYERS,
      version: VERSION,
      desc: CFG.SERVER_DESC,
      official: true,
    };
    // 注册的公开服务器（60 秒内心跳过的才算活）
    const others = [...directory.values()]
      .filter(s => s.public && now - s.ts < 60000)
      .map(s => ({ id: s.id, name: s.name, host: s.host, port: s.port, players: s.players, maxPlayers: s.maxPlayers, version: s.version, desc: s.desc, official: false }));
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ servers: [self, ...others] }));
    return;
  }
  // ── 公开服务器注册（其他服务器启动后定时 POST 到这里报心跳）──
  if (pathname === '/api/server/register') {
    let body = '';
    req.on('data', d => { body += d; if (body.length > 4096) req.destroy(); });
    req.on('end', () => {
      try {
        const b = JSON.parse(body || '{}');
        const id = String(b.id || 'srv' + (serverSeq++));
        directory.set(id, {
          id,
          name: String(b.name || 'AIM 服务器').slice(0, 20),
          host: String(b.host || '').slice(0, 64),
          port: parseInt(b.port, 10) || 5000,
          players: parseInt(b.players, 10) || 0,
          maxPlayers: parseInt(b.maxPlayers, 10) || 20,
          version: String(b.version || VERSION).slice(0, 10),
          desc: String(b.desc || '').slice(0, 40),
          public: !!b.public,
          ts: Date.now(),
        });
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, msg: 'bad json' }));
      }
    });
    return;
  }
  // ── αβ 战斗测试 API（同源 5000，人机/AI 对战）──
  if (pathname.startsWith('/api/ab/')) {
    handleAbApi(pathname, req, res);
    return;
  }
  let url = decodeURIComponent(req.url.split('?')[0]);
  if (url === '/') url = '/index.html';
  // 路径前缀归一：req.url 形如 /downloads/foo 时，path.join 会拼成 DOWNLOAD_DIR/downloads/foo，需要剥掉 /downloads 前缀
  if (url.startsWith('/downloads/')) url = url.substring('/downloads'.length);
  else if (url === '/downloads') url = '/';
  // 目录请求自动 fallback 到 index.html（避免 /portraits/ 这类路径 404）
  if (url.endsWith('/')) url += 'index.html';
  const file = path.join(DOWNLOAD_DIR, path.normalize(url));
  if (!file.startsWith(DOWNLOAD_DIR)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('404 Not Found: ' + url);
      return;
    }
    const ext = path.extname(file).toLowerCase();
    // gzip：web 资源（js/wasm 等）压缩后体积大减；已压缩格式（apk/png/zip）跳过
    const COMPRESSIBLE = ['.js', '.wasm', '.json', '.html', '.css', '.data', '.otf', '.ttf', '.txt', '.svg', '.map'];
    const wantGzip = COMPRESSIBLE.includes(ext) && (req.headers['accept-encoding'] || '').includes('gzip');
    // 缓存：web 构建产物（除 index.html）允许缓存 1 天，避免每次刷新全量重下 40MB。
    // 2026-08-28 修复：入口 JS 不带 hash（main.dart.js/flutter_bootstrap.js/service worker），
    // 若也长缓存，部署新构建后浏览器永远拿到旧版 JS——前瞻等更新全被缓存吞掉！
    // 入口文件每次刷新取新（no-store），其余带 hash 的资源（assets/）内容不可变，可长缓存。
    const inWeb = file.startsWith(path.join(DOWNLOAD_DIR, 'web'));
    const base = path.basename(file);
    const ENTRY_FILES = ['index.html', 'main.dart.js', 'flutter_bootstrap.js',
                         'flutter.js', 'flutter_service_worker.js', 'manifest.json'];
    const isEntry = inWeb && ENTRY_FILES.includes(base);
    const cacheControl = inWeb && !isEntry ? 'public, max-age=86400' : 'no-store, no-cache, must-revalidate';
    const headers = {
      'Content-Type': mime[ext] || 'application/octet-stream',
      'Content-Disposition': ['.apk', '.zip', '.png', '.jpg', '.jpeg', '.gif', '.webp'].includes(ext) ? 'attachment' : 'inline',
      'Cache-Control': cacheControl,
      'Pragma': 'no-cache',
    };
    if (wantGzip) {
      headers['Content-Encoding'] = 'gzip';
      res.writeHead(200, headers); // gzip 后长度未知，走 chunked
      fs.createReadStream(file).pipe(zlib.createGzip()).pipe(res);
    } else {
      headers['Content-Length'] = st.size; // 显式给大小：低端浏览器/手表上避免 chunked 闪退
      res.writeHead(200, headers);
      fs.createReadStream(file).pipe(res); // 流式发送，不整文件读内存
    }
  });
});

io.attach(dlServer); // Socket.io 与下载页同端口

// 对局结束广播（判负时：tick 超时判负 / 其它结束路径复用）
function endGameBroadcast(room) {
  broadcastGame(room);
  const w = room.state ? room.state.winner : null;
  if (w == null) return;
  for (const p of room.players) {
    if (p) io.to(p.socketId).emit('game_over', {
      winner: w,
      winnerName: room.players[w] ? room.players[w].name : null,
    });
  }
  for (const sp of room.spectators) {
    io.to(sp.socketId).emit('game_over', {
      winner: w,
      winnerName: room.players[w] ? room.players[w].name : null,
    });
  }
}

// ── 断线重连周期检查（每 5s）：掉线 30s 超时判负；当前回合方掉线 15s 自动过回合 ──
setInterval(() => {
  for (const room of rooms.values()) {
    if (room.status !== 'playing') continue;
    const changed = room.tick();
    if (changed) {
      endGameBroadcast(room);
      if (room.status === 'ended') sysMsg(`房间「${room.title}」对局结束`);
    }
  }
}, 5000);

dlServer.listen(DOWNLOAD_PORT, () => {
  console.log(`[AIM] 单端口服务器 ${DOWNLOAD_PORT}（游戏 + 下载页一体, v${VERSION})`);
});
