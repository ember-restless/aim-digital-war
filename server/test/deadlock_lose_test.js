// 死局判负（牢大 08-22）：一方无任何可执行行动 → 直接判负（与 Dart 版对拍）
// 跑法：cd /root/aim/server && node test/deadlock_lose_test.js
const R = require('../src/game/rules');
const assert = require('assert');

// 1. 只剩锁死滚木 → 判负
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[0] = { v: 6, o: 0, bridge: false, auto: true }; // 玩家0 只剩滚木
  s.turn = 0;
  s.points = 1;
  const r = R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  assert.strictEqual(r.ok, true);
  assert.strictEqual(s.winner, 1, '玩家0 无法行动，玩家1 获胜');
  assert.ok(s.log.some((l) => l.includes('判负')), '日志应记录判负');
  console.log('✓ 死局判负：只剩锁死滚木 → 玩家0 判负');
}

// 2. 正常局面 → 不判负
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[1] = { v: 1, o: 0, bridge: false, auto: false };
  s.turn = 0;
  s.points = 1;
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  assert.strictEqual(s.winner, null, '有可行动单位，不应判负');
  console.log('✓ 正常局面不误伤');
}

// 3. 只剩基地8（可拆分）→ 不判负
{
  const s = R.createGame({ limit: 16 });
  s.turn = 0;
  s.points = 1;
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  assert.strictEqual(s.winner, null, '基地8 可拆分，不算死局');
  console.log('✓ 只剩基地不误伤');
}

console.log('\n全部通过 ✓');
