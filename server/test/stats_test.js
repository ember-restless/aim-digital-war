// 对局统计测试（与 Dart 版对拍）：kills/losses/produce/turnCount
// 跑法：cd /root/aim/server && node test/stats_test.js
const R = require('../src/game/rules');
const assert = require('assert');

// 1. 攻击击杀 + 损失
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[1] = { v: 1, o: 0, bridge: false, auto: false };
  s.map.cells[2] = { v: 1, o: 1, bridge: false, auto: false };
  s.turn = 0;
  s.phase = 'action';
  s.points = 1;
  R.applyAction(s, 0, { type: 'attack', i: 1, j: 2 }); // 1 打 1 → 击杀
  assert.strictEqual(s.stats.kills[0], 1, '玩家0 击杀+1');
  assert.strictEqual(s.stats.losses[1], 1, '玩家1 损失+1');
  console.log('✓ 攻击击杀/损失');
}

// 2. 造兵数
{
  const s = R.createGame({ limit: 16 });
  s.turn = 0;
  s.phase = 'produce';
  s.produceLeft = 1;
  R.applyAction(s, 0, { type: 'produce', i: 0, j: 1 });
  assert.strictEqual(s.stats.produce[0], 1, '造兵数+1');
  console.log('✓ 造兵数');
}

// 3. 吞噬记击杀/损失
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[1] = { v: 4, o: 0, bridge: false, auto: false };
  s.map.cells[2] = { v: 2, o: 1, bridge: false, auto: false };
  s.turn = 0;
  s.phase = 'action';
  s.points = 1;
  R.applyAction(s, 0, { type: 'devour', i: 1, j: 2 });
  assert.strictEqual(s.stats.kills[0], 1, '吞噬记击杀');
  assert.strictEqual(s.stats.losses[1], 1);
  console.log('✓ 吞噬击杀/损失');
}

// 4. 滚木碾死只记损失
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[0] = { v: 6, o: 0, bridge: false, auto: true };
  s.map.cells[1] = { v: 6, o: 1, bridge: false, auto: false };
  s.turn = 1;
  R.applyAction(s, 1, { type: 'endTurn' }); // 玩家1 过回合 → 玩家0 滚木滚 → 压死格1的6
  assert.strictEqual(s.stats.losses[1], 1);
  assert.strictEqual(s.stats.kills[0], 0, '滚木不记击杀');
  assert.strictEqual(s.stats.kills[1], 0);
  console.log('✓ 滚木碾死只记损失');
}

// 5. endTurn 回合数
{
  const s = R.createGame({ limit: 16 });
  s.turn = 0;
  R.applyAction(s, 0, { type: 'endTurn' });
  assert.strictEqual(s.turnCount, 1, '回合数+1');
  console.log('✓ 回合数');
}

console.log('\n全部通过 ✓');
