// AIM 数字大战 — 联机服务器
// 单端口 5000：游戏（Socket.io）+ 下载页（静态）+ /api/version 一体
// ⚠️ 3000 是 math（Graphwar）的端口，勿动
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { spawn } = require('child_process');
const { Server } = require('socket.io');
const { RoomGame } = require('./game/RoomGame');

const DOWNLOAD_PORT = 5000;
const DOWNLOAD_DIR = path.join(__dirname, '..', 'public', 'downloads');
const CFG = require('./config.js');
const VERSION = CFG.APP_VERSION;

// ── AI 训练场统计（训练数据局数/步数/模型版本）──
let trainStatsCache = null;

// RL 状态实时读（RL 进程独立写文件，不能走缓存）
function readRl() {
  let rl = null;
  try {
    const rf = path.join(__dirname, '..', '..', 'train_data', 'rl_status.json');
    if (fs.existsSync(rf)) rl = JSON.parse(fs.readFileSync(rf, 'utf8'));
    if (rl && rlProcess && rlProcess.exitCode === null && rl.state !== 'running') rl.state = 'running';
  } catch (_) {}
  return rl;
}
function readRlHistory() {
  let h = [];
  try {
    const hf = path.join(__dirname, '..', '..', 'train_data', 'rl_history.jsonl');
    if (fs.existsSync(hf)) {
      h = fs.readFileSync(hf, 'utf8').trim().split('\n').filter(Boolean)
        .map(l => { try { return JSON.parse(l); } catch (_) { return null; } })
        .filter(Boolean);
    }
  } catch (_) {}
  return h;
}

function readEvalInfo() {
  let e = null;
  try {
    const ef = path.join(__dirname, '..', '..', 'train_data', 'eval_result.json');
    if (fs.existsSync(ef)) e = JSON.parse(fs.readFileSync(ef, 'utf8'));
  } catch (_) {}
  return e;
}

function trainStats() {
  if (trainStatsCache) {
    // 静态部分走缓存，RL 状态/历史 + 模型评估实时读（eval 曾被缓存成旧值误导监视台）
    return { ...trainStatsCache, rl: readRl(), rlHistory: readRlHistory(), eval: readEvalInfo() };
  }
  let games = 0, steps = 0;
  let aiGames = 0, aiWins = 0;
  const pvpSeries = []; // 与真人对局序列：{n, aiWin}（n=局序，aiWin=AI 是否获胜）
  const dataFile = path.join(__dirname, '..', '..', 'train_data', 'games.jsonl');
  try {
    if (fs.existsSync(dataFile)) {
      const lines = fs.readFileSync(dataFile, 'utf8').trim().split('\n');
      games = lines.length;
      let seq = 0;
      for (const l of lines) {
        try {
          const g = JSON.parse(l);
          steps += (g.steps || []).length;
          // 从第一步的人类 owner 推断人类所在侧，算 AI 胜负
          const st = g.steps || [];
          const humanSide = st.length ? (st[0].owner ?? -1) : -1;
          if (humanSide === 0 || humanSide === 1) {
            seq++;
            const aiWin = (humanSide === 0 && g.winner === 1) || (humanSide === 1 && g.winner === 0);
            aiGames++;
            if (aiWin) aiWins++;
            pvpSeries.push({ n: seq, aiWin: aiWin ? 1 : 0 });
          }
        } catch (_) {}
      }
    }
  } catch (_) {}
  // 模型版本：权重文件 mtime 次数（每次部署 = 版本 +1）
  let modelVersion = 0, modelUpdatedAt = null;
  const wf = path.join(DOWNLOAD_DIR, 'train_weights.json');
  try {
    if (fs.existsSync(wf)) {
      const w = JSON.parse(fs.readFileSync(wf, 'utf8'));
      modelVersion = w.version || 1;
      modelUpdatedAt = w.updatedAt || null;
    }
  } catch (_) {}
  // 模型实力评估结果（监视台展示：vs easy/normal/hard 胜率等）——实时读
  const evalInfo = readEvalInfo();
  trainStatsCache = {
    games, steps, modelVersion, modelUpdatedAt, training, evaluating, lastTrainAt, eval: evalInfo,
    rl: readRl(), rlHistory: readRlHistory(),
    // 与真人对局：AI 场次/胜场/胜率 + 每局序列（折线图）
    aiGames, aiWins,
    aiWinRate: aiGames ? Math.round((aiWins / aiGames) * 1000) / 1000 : 0,
    pvpSeries,
  };
  return trainStatsCache;
}

// ── 自动训练（在线学习）：有新对局就后台训练，训完自动部署权重 ──
// 节流：两次训练间隔 ≥ TRAIN_MIN_GAP；训练期间的来数据 → 训练完再补训一次（合并）
const TRAIN_MIN_GAP = 30 * 1000; // 30s 最小间隔（防连续对局训练风暴）
let training = false;
let pendingTrain = false;
let evaluating = false;
let rlProcess = null; // 自博弈 RL 进程（detached）
let lastTrainAt = null;

function triggerTrain() {
  if (training) { pendingTrain = true; return; }
  if (lastTrainAt && Date.now() - lastTrainAt < TRAIN_MIN_GAP) { pendingTrain = true; return; }
  // 没有数据就不训
  const dataFile = path.join(__dirname, '..', '..', 'train_data', 'games.jsonl');
  if (!fs.existsSync(dataFile)) return;
  training = true;
  const logPath = path.join(__dirname, '..', '..', 'train', 'train.log');
  const out = fs.openSync(logPath, 'a');
  const started = Date.now();
  fs.writeSync(out, `\n===== 自动训练 ${new Date().toISOString()} =====\n`);
  const p = spawn('python3', ['/root/aim/train/train_bc.py', '--deploy', '--epochs', '40'],
    { cwd: '/root/aim', stdio: ['ignore', out, out] });
  p.on('close', (code) => {
    try { fs.closeSync(out); } catch (_) {}
    training = false;
    lastTrainAt = Date.now();
    trainStatsCache = null; // 统计缓存失效（版本号已变）
    console.log(`[train] 训练结束 code=${code} 耗时=${((Date.now() - started) / 1000).toFixed(1)}s`);
    // 训练部署完成 → 自动评估模型实力（新权重存在才评）
    if (code === 0) triggerEval();
    if (pendingTrain) { pendingTrain = false; triggerTrain(); }
  });
  p.on('error', () => {
    try { fs.closeSync(out); } catch (_) {}
    training = false;
    lastTrainAt = Date.now();
  });
}

// 模型实力评估：vs easy/normal/hard 各打几局（左右两侧），结果落盘 eval_result.json
function triggerEval() {
  if (evaluating) return;
  const wf = path.join(DOWNLOAD_DIR, 'train_weights.json');
  if (!fs.existsSync(wf)) return; // 无权重不评
  evaluating = true;
  const logPath = path.join(__dirname, '..', '..', 'train', 'train.log');
  const out = fs.openSync(logPath, 'a');
  const started = Date.now();
  fs.writeSync(out, `\n===== 模型评估 ${new Date().toISOString()} =====\n`);
  const p = spawn('python3', ['/root/aim/train/eval_model.py', '--games', 'easy=4,normal=4,hard=8'],
    { cwd: '/root/aim', stdio: ['ignore', out, out] });
  p.on('close', (code) => {
    try { fs.closeSync(out); } catch (_) {}
    evaluating = false;
    trainStatsCache = null; // 评估结果缓存失效
    console.log(`[eval] 评估结束 code=${code} 耗时=${((Date.now() - started) / 1000).toFixed(1)}s`);
  });
  p.on('error', () => {
    try { fs.closeSync(out); } catch (_) {}
    evaluating = false;
  });
}

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
  // ── AI 训练场：对局数据上传（JSONL 落盘，供行为克隆训练）──
  if (pathname === '/api/train/upload') {
    let body = '';
    req.on('data', d => { body += d; if (body.length > 2 * 1024 * 1024) req.destroy(); });
    req.on('end', () => {
      try {
        const b = JSON.parse(body || '{}');
        if (!b.steps || !Array.isArray(b.steps) || b.steps.length === 0) {
          res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: false, msg: 'empty steps' }));
          return;
        }
        const dir = path.join(__dirname, '..', '..', 'train_data');
        fs.mkdirSync(dir, { recursive: true });
        const line = JSON.stringify({
          v: VERSION,
          winner: b.winner,
          turns: b.turns,
          limit: b.limit,
          steps: b.steps,
          ts: Date.now(),
        });
        fs.appendFileSync(path.join(dir, 'games.jsonl'), line + '\n');
        // 统计缓存失效 + 触发异步训练（在线学习：有数据就训，训完自动部署权重）
        trainStatsCache = null;
        triggerTrain();
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, msg: 'bad json' }));
      }
    });
    return;
  }
  // ── AI 训练场：统计（对局数 / 步数 / 模型版本）──
  if (pathname === '/api/train/stats') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(trainStats()));
    return;
  }
  // ── 自博弈强化学习：启动（后台进程，以最新 BC 权重为基；body 可带 games=目标局数）──
  if (pathname === '/api/train/rl/start') {
    if (rlProcess && rlProcess.exitCode === null) {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true, msg: '已在运行' }));
      return;
    }
    // 读 body（可带 games 目标局数）
    let body = '';
    req.on('data', d => { body += d; if (body.length > 4096) req.destroy(); });
    req.on('end', () => {
      let rlGames = 0;
      try {
        const b = JSON.parse(body || '{}');
        rlGames = parseInt(b.games, 10) || 0;
      } catch (_) {}
      const stopFile = path.join(__dirname, '..', '..', 'train', 'rl_stop');
      try { if (fs.existsSync(stopFile)) fs.unlinkSync(stopFile); } catch (_) {}
      const logPath = path.join(__dirname, '..', '..', 'train', 'rl.log');
      const out = fs.openSync(logPath, 'a');
      fs.writeSync(out, `\n===== RL 启动 ${new Date().toISOString()} 目标局数=${rlGames || '无限'} =====\n`);
      const args = ['/root/aim/train/rl_selfplay.py'];
      if (rlGames > 0) args.push('--games', String(rlGames));
      rlProcess = spawn('python3', args,
        { cwd: '/root/aim', stdio: ['ignore', out, out], detached: true });
      rlProcess.unref(); // 服务器重启不杀 RL
      rlProcess.on('close', () => { rlProcess = null; });
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true, msg: 'RL 已启动' + (rlGames ? '（目标 ' + rlGames + ' 局）' : '') }));
    });
    return;
  }
  // ── 自博弈强化学习：停止（优雅退出）──
  if (pathname === '/api/train/rl/stop') {
    const stopFile = path.join(__dirname, '..', '..', 'train', 'rl_stop');
    try { fs.writeFileSync(stopFile, 'stop'); } catch (_) {}
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true, msg: 'RL 停止中（保存后退出）' }));
    return;
  }
  // ── 自博弈强化学习：部署 RL 权重为游戏 AI（手动按钮）──
  if (pathname === '/api/train/rl/deploy') {
    const rlFile = path.join(DOWNLOAD_DIR, 'train_weights_rl.json');
    const mainFile = path.join(DOWNLOAD_DIR, 'train_weights.json');
    if (!fs.existsSync(rlFile)) {
      res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: false, msg: '没有 RL 权重（先跑完一次 RL）' }));
      return;
    }
    try {
      const rl = JSON.parse(fs.readFileSync(rlFile, 'utf8'));
      // 版本号接续主权重 +1，标记来源 RL
      let ver = 1;
      try {
        if (fs.existsSync(mainFile)) {
          ver = (JSON.parse(fs.readFileSync(mainFile, 'utf8')).version || 0) + 1;
        }
      } catch (_) {}
      rl.version = ver;
      rl.updatedAt = new Date().toISOString().replace('T', ' ').slice(0, 19);
      rl.rlDeployed = true;
      rl.rlSourceVersion = rl.rlVersion || null;
      fs.writeFileSync(mainFile, JSON.stringify(rl));
      trainStatsCache = null;
      console.log(`[rl] RL 权重已部署为游戏 AI（v${ver}）`);
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true, msg: '已部署（v' + ver + '）', version: ver }));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: false, msg: '部署失败: ' + e.message }));
    }
    return;
  }
  // ── AI 训练场：训练日志尾部（监视台用）──
  if (pathname === '/api/train/log') {
    let log = '';
    const logFile = path.join(__dirname, '..', '..', 'train', 'train.log');
    try {
      if (fs.existsSync(logFile)) {
        const size = fs.statSync(logFile).size;
        const start = Math.max(0, size - 8192); // 尾部 8KB
        const fd = fs.openSync(logFile, 'r');
        const buf = Buffer.alloc(size - start);
        fs.readSync(fd, buf, 0, buf.length, start);
        fs.closeSync(fd);
        log = buf.toString('utf8');
      }
    } catch (_) {}
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ log }));
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
    // 缓存：web 构建产物（除 index.html）允许缓存 1 天，避免每次刷新全量重下 40MB
    const inWeb = file.startsWith(path.join(DOWNLOAD_DIR, 'web'));
    const isIndex = path.basename(file) === 'index.html';
    const cacheControl = inWeb && !isIndex ? 'public, max-age=86400' : 'no-store, no-cache, must-revalidate';
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
