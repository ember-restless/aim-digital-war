// 联机流程测试 v2：双方自动行动，跑 10 轮回合
const { io } = require('socket.io-client');

const URL = 'http://127.0.0.1:3000';
const p0 = io(URL), p1 = io(URL);
let roomId = null;
let state0 = null;
let totalActs = 0;
const MAX_ACTS = 40;

function fmt(cells) {
  return cells.map(c => {
    if (c.bridge) return '-';
    if (c.o === null) return '0';
    return c.o === 0 ? `[${c.v}]` : `{${c.v}}`;
  }).join(' ');
}

function autoPlay(socket, s) {
  if (totalActs >= MAX_ACTS || s.winner !== null) return;
  if (s.phase === null) {
    totalActs++;
    socket.emit('action', { type: 'choosePhase', phase: 'produce' });
  } else if (s.phase === 'produce') {
    const prod = s.legalActions.find(a => a.type === 'produce');
    totalActs++;
    socket.emit('action', prod || { type: 'endTurn' });
  } else {
    totalActs++;
    socket.emit('action', { type: 'endTurn' });
  }
}

p0.on('connect', () => p0.emit('create_room', { name: '离离' }));
p1.on('connect', () => {});
p0.on('you_are', (d) => { roomId = d.roomId; p1.emit('join_room', { roomId, name: '牢大' }); });
p0.on('room_update', (r) => { if (r.players.length === 2 && r.status === 'waiting') p0.emit('start_game', { limit: 16 }); });

p0.on('game_state', (s) => {
  state0 = s;
  if (s.turn === 0) autoPlay(p0, s);
});
p1.on('game_state', (s) => { if (s.turn === 1) autoPlay(p1, s); });

p0.on('game_over', (d) => {
  console.log('=== 游戏结束:', JSON.stringify(d));
  process.exit(0);
});
p0.on('error', e => console.log('p0 err:', e.msg));
p1.on('error', e => console.log('p1 err:', e.msg));

let last = '';
setInterval(() => {
  if (state0) {
    const cur = `turn=${state0.turn} phase=${state0.phase} pts=${state0.points} prod=${state0.produceLeft} acts=${totalActs}`;
    if (cur !== last) {
      last = cur;
      console.log(cur);
      console.log('  ', fmt(state0.cells));
    }
    if (totalActs >= MAX_ACTS) { console.log('达到步数上限，正常停止'); process.exit(0); }
  }
}, 1000);

setTimeout(() => { console.log('超时退出'); process.exit(1); }, 25000);
