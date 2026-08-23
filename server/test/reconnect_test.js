// 断线重连测试：掉线不判负 → 重连恢复 → 超时判负 / 自动过回合
// 跑法：cd /root/aim/server && node test/reconnect_test.js
const { RoomGame } = require('../src/game/RoomGame');
const assert = require('assert');

function setup() {
  const room = new RoomGame('R1', '测试房', 'online');
  room.addPlayer('sockA', '玩家甲', 0);
  room.addPlayer('sockB', '玩家乙', 1);
  room.players[1].ready = true; // 非房主准备
  const r = room.start(16);
  assert.strictEqual(r.ok, true);
  return room;
}

// 1. 掉线不判负，座位保留标记 disconnected
{
  const room = setup();
  room.removePlayer('sockA');
  assert.strictEqual(room.state.winner, null, '掉线不应立即判负');
  assert.strictEqual(room.players[0].disconnected, true, '座位应保留并标记掉线');
  assert.ok(room.players[0].disconnectAt > 0, '应记录掉线时间');
  console.log('✓ 掉线不判负，座位保留');
}

// 2. 重连成功（名字匹配 + 原座位）
{
  const room = setup();
  room.removePlayer('sockA');
  const rc = room.tryReconnect('sockA2', '玩家甲', 0);
  assert.strictEqual(rc.ok, true);
  assert.strictEqual(rc.playerIdx, 0);
  assert.strictEqual(room.players[0].socketId, 'sockA2');
  assert.strictEqual(room.players[0].disconnected, false);
  assert.strictEqual(room.players[0].disconnectAt, null);
  assert.strictEqual(room.state.winner, null, '重连后不应有 winner');
  console.log('✓ 重连成功恢复座位');
}

// 3. 重连拒绝：名字不匹配 / 座位没掉线 / 房间 waiting
{
  const room = setup();
  room.removePlayer('sockA');
  assert.strictEqual(room.tryReconnect('x', '路人', 0).ok, false, '名字不匹配应拒绝');
  assert.strictEqual(room.tryReconnect('x', '玩家甲', 1).ok, false, '未掉线的座位不可重连');
  assert.strictEqual(room.tryReconnect('x', '玩家甲', 5).ok, false, '越界座位拒绝');
  const room2 = new RoomGame('R2', '等待房', 'online');
  room2.addPlayer('a', 'A', 0);
  room2.addPlayer('b', 'B', 1);
  assert.strictEqual(room2.tryReconnect('c', 'A', 0).ok, false, 'waiting 状态不可重连');
  console.log('✓ 非法重连全部拒绝');
}

// 4. 掉线 30s 超时 → 判负
{
  const room = setup();
  room.removePlayer('sockA');
  room.players[0].disconnectAt = Date.now() - 31000;
  const changed = room.tick();
  assert.strictEqual(changed, true);
  assert.strictEqual(room.state.winner, 1, '玩家0 掉线超时，玩家1 获胜');
  assert.strictEqual(room.status, 'ended');
  console.log('✓ 掉线 30s 超时判负');
}

// 5. 当前回合方掉线 15s → 自动过回合（不判负，游戏继续）
{
  const room = setup();
  // 玩家0 当前回合（turn=0），掉线
  room.removePlayer('sockA');
  room.players[0].disconnectAt = Date.now() - 16000;
  const changed = room.tick();
  assert.strictEqual(changed, true, '自动过回合应产生变化');
  assert.strictEqual(room.state.winner, null, '未超时不应判负');
  assert.strictEqual(room.state.turn, 1, '回合应切到玩家1');
  assert.strictEqual(room.status, 'playing');
  console.log('✓ 当前回合方掉线 15s 自动过回合');
}

// 6. 重连成功后再掉线，仍可再重连（超时窗口重置）
{
  const room = setup();
  room.removePlayer('sockA');
  assert.strictEqual(room.tryReconnect('sockA2', '玩家甲', 0).ok, true);
  room.removePlayer('sockA2');
  assert.strictEqual(room.players[0].disconnected, true, '再次掉线重新标记');
  assert.strictEqual(room.tryReconnect('sockA3', '玩家甲', 0).ok, true, '再次重连成功');
  console.log('✓ 掉线-重连可循环');
}

console.log('\n全部通过 ✓');
