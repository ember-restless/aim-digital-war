// 断线重连端到端测试（连 5000 真实服务）：掉线不判负 → 重连恢复座位 → 恢复棋盘
// 跑法：cd /root/aim/server && node test/reconnect_e2e_test.js（需服务已启动）
const { io } = require('socket.io-client');
const assert = require('assert');

const URL = 'http://127.0.0.1:5000';
let roomId = null;
const log = (m) => console.log('  ', m);

function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

async function main() {
  // 1. 建房 + 加入 + 开始
  const p0 = io(URL);
  const p1 = io(URL);
  await Promise.all([once(p0, 'connect'), once(p1, 'connect')]);
  p0.emit('create_room', { name: '玩家甲' });
  const you0 = await once(p0, 'you_are');
  roomId = you0.roomId;
  p1.emit('join_room', { roomId, name: '玩家乙' });
  await once(p1, 'you_are');
  p1.emit('ready', { roomId, ready: true });
  await wait(300);
  p0.emit('start_game', { limit: 16 });
  const st0 = await once(p0, 'game_state');
  assert.ok(st0.cells.length > 0, '应收到棋盘');
  log(`对局开始，棋盘 ${st0.cells.length} 格，turn=${st0.turn}`);

  // 2. 玩家0 掉线 → 不应立即判负（p1 收不到 game_over）
  let p1GameOver = null;
  p1.on('game_over', (d) => { p1GameOver = d; });
  p0.disconnect();
  await wait(1500);
  assert.strictEqual(p1GameOver, null, '掉线后不应立即判负');
  log('玩家0 掉线，1.5s 内未判负 ✓');

  // 3. 玩家0 重连（新 socket，reconnectIdx=0）→ 恢复座位 + 收到棋盘
  const p0b = io(URL);
  await once(p0b, 'connect');
  let reconnectErr = null;
  p0b.on('error', (e) => { reconnectErr = e; });
  p0b.emit('join_room', { roomId, name: '玩家甲', reconnectIdx: 0 });
  const youR = await once(p0b, 'you_are');
  assert.strictEqual(youR.playerIdx, 0, '应恢复玩家0 座位');
  const stR = await once(p0b, 'game_state');
  assert.ok(stR.cells.length > 0, '重连应收到棋盘');
  log(`重连成功，恢复座位 playerIdx=${youR.playerIdx}，棋盘 ${stR.cells.length} 格 ✓`);

  // 4. 重连后仍能正常行动（发一个 endTurn 验证链路通）
  p0b.emit('action', { type: 'choosePhase', phase: 'produce' });
  const stR2 = await once(p0b, 'game_state');
  assert.strictEqual(stR2.phase, 'produce', '重连后操作应生效');
  log('重连后操作链路正常 ✓');

  p0b.disconnect();
  p1.disconnect();
  console.log('\n端到端重连测试全部通过 ✓');
}

function once(sock, ev) {
  return new Promise((resolve) => {
    sock.once(ev, (d) => resolve(d || {}));
  });
}

main().catch((e) => { console.error('FAIL:', e.message); process.exit(1); });
