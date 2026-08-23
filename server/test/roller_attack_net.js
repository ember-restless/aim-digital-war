// 联机端到端：敌方滚木能否被我方攻击
// 玩家0 持续造兵把基地前堆到 6（滚木）→ 滚动(auto) → 玩家1 攻击滚木
const { io } = require('socket.io-client');
const URL = 'http://127.0.0.1:5000';
const wait = (ms) => new Promise(r => setTimeout(r, ms));

let p0, p1, roomId;
let p0State, p1State;

function cells(s) {
  if (!s) return '?';
  return s.cells.map(c => c.bridge ? '-' : (c.o === null ? '0' : (c.o === 0 ? `[${c.v}]` : `{${c.v}}`))).join(' ');
}
const hasMy6 = (s) => s && s.cells.some(c => c.v === 6 && c.o === 0);

async function produceOnce(sock, getState) {
  sock.emit('action', { type: 'choosePhase', phase: 'produce' });
  await wait(200);
  const la = (getState()?.legalActions) || [];
  const prod = la.find(a => a.type === 'produce');
  if (prod) { sock.emit('action', prod); await wait(250); return true; }
  return false;
}

async function main() {
  p0 = io(URL, { transports: ['websocket'] });
  await new Promise(r => p0.on('connect', r));
  p0.on('game_state', s => { p0State = s; });
  p0.on('room_update', d => { if (d && d.id) roomId = d.id; });
  p0.emit('create_room', { name: 'T0' });
  await wait(400);

  p1 = io(URL, { transports: ['websocket'] });
  await new Promise(r => p1.on('connect', r));
  p1.on('game_state', s => { p1State = s; });
  p1.emit('join_room', { roomId, name: 'T1' });
  await wait(400);

  p0.emit('start_game', { limit: 16 });
  await wait(600);
  console.log('开战:', cells(p0State), 'turn=', p0State?.turn);

  // 轮流造兵（双方基地前各 +1），玩家0 需要攒到 6（约6个自己回合）
  let guard = 0;
  while (!hasMy6(p0State) && guard++ < 12) {
    if (p0State?.turn === 0) {
      await produceOnce(p0, () => p0State);
    } else {
      await produceOnce(p1, () => p1State);
    }
    await wait(150);
    if (guard % 2 === 0) console.log(`轮${guard}:`, cells(p0State), 'turn=', p0State?.turn);
  }

  if (!hasMy6(p0State)) { console.log('❌ 没凑出6'); process.exit(1); }
  const ri = p0State.cells.findIndex(c => c.v === 6 && c.o === 0);
  console.log(`✅ 玩家0 滚木在位置 ${ri}, auto=`, p0State.cells[ri].auto, '|', cells(p0State));

  // 玩家1 回合：检查能否攻击滚木（滚木在敌方地盘，玩家1 需要射程够）
  // 若滚木位置太远，玩家1 无法攻击——先看玩家1 视角合法行动里有没有 j==ri 的 attack
  const p1la = p1State?.legalActions || [];
  const atks = p1la.filter(a => a.type === 'attack' && a.j === ri);
  console.log('玩家1 攻击滚木选项:', JSON.stringify(atks));
  if (atks.length > 0) {
    const r = await new Promise(res => { p1.once('game_state', s => res(s)); p1.emit('action', atks[0]); });
    console.log('攻击后:', cells(r), '滚木格:', JSON.stringify(r.cells[ri]));
    console.log('✅ 玩家1 成功攻击敌方滚木');
  } else {
    console.log('ℹ️ 滚木距玩家1 太远（不在射程），改看玩家1 是否有任何 attack 选项:', JSON.stringify(p1la.filter(a => a.type === 'attack').slice(0, 3)));
  }
  process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
