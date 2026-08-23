// 规则开关：滚木能否被己方攻击（allowOwnRollerAttack）—— 与 Dart 版 rules.dart 对拍
// 跑法：cd /root/aim/server && node test/allow_own_roll_test.js
const R = require('../src/game/rules');
const assert = require('assert');

// 玩家0 视角：格1=2(己方)，格2=6(己方滚木,auto)
function board() {
  const s = R.createGame({ limit: 16 });
  s.map.cells[1] = { v: 2, o: 0, bridge: false, auto: false };
  s.map.cells[2] = { v: 6, o: 0, bridge: false, auto: true };
  return s;
}

// 1. 默认开启：己方可攻击己方滚木
{
  const s = board(); // allowOwnRollerAttack 默认 true
  const acts = R.getLegalActions(s, 0);
  assert.ok(
    acts.some((a) => a.type === 'attack' && a.i === 1 && a.j === 2),
    '默认开启：应有攻击己方滚木选项'
  );
  const r = R.applyAction(s, 0, { type: 'attack', i: 1, j: 2 });
  assert.strictEqual(r.ok, true, '默认开启：攻击应成功');
  assert.strictEqual(s.map.cells[2].v, 4, '2 打 6 → 4');
  assert.strictEqual(s.map.cells[2].auto, false, '被打降级后滚木解锁');
  console.log('✓ 默认开启：己方可攻击己方滚木（2 打 6 → 4）');
}

// 2. 关闭后：己方不能攻击己方滚木（选项消失 + 执行被拒）
{
  const s = R.createGame({ limit: 16, allowOwnRollerAttack: false });
  s.map.cells[1] = { v: 2, o: 0, bridge: false, auto: false };
  s.map.cells[2] = { v: 6, o: 0, bridge: false, auto: true };
  const acts = R.getLegalActions(s, 0);
  assert.ok(
    !acts.some((a) => a.type === 'attack'),
    '关闭后：攻击选项应消失（己方滚木不出现）'
  );
  // 绕过选项生成直接伪造攻击：doAttack 应拒绝
  s.phase = 'action';
  s.points = 1;
  const r = R.applyAction(s, 0, { type: 'attack', i: 1, j: 2 });
  assert.strictEqual(r.ok, false, '关闭后：伪造攻击应被拒绝');
  console.log('✓ 关闭后：己方滚木免疫己方攻击（选项消失 + 服务端拒绝）');
}

// 3. 关闭后：己方普通单位仍可攻击（开关只针对滚木）
{
  const s = R.createGame({ limit: 16, allowOwnRollerAttack: false });
  s.map.cells[1] = { v: 2, o: 0, bridge: false, auto: false };
  s.map.cells[2] = { v: 2, o: 0, bridge: false, auto: false }; // 己方普通2
  const acts = R.getLegalActions(s, 0);
  assert.ok(
    acts.some((a) => a.type === 'attack' && a.i === 1 && a.j === 2),
    '己方普通单位仍可被己方攻击'
  );
  console.log('✓ 关闭后：己方普通单位仍可被攻击（敌我皆可不变）');
}

// 4. 关闭后：敌方仍可攻击己方滚木
{
  const s = R.createGame({ limit: 16, allowOwnRollerAttack: false });
  s.map.cells[3] = { v: 6, o: 0, bridge: false, auto: true }; // 玩家0 滚木
  s.map.cells[4] = { v: 1, o: 1, bridge: false, auto: false }; // 玩家1 小兵
  s.turn = 1;
  const acts = R.getLegalActions(s, 1);
  assert.ok(
    acts.some((a) => a.type === 'attack' && a.i === 4 && a.j === 3),
    '敌方打己方滚木不受开关限制'
  );
  s.phase = 'action';
  s.points = 1;
  const r = R.applyAction(s, 1, { type: 'attack', i: 4, j: 3 });
  assert.strictEqual(r.ok, true, '敌方攻击应成功');
  assert.strictEqual(s.map.cells[3].v, 5, '1 打 6 → 5');
  console.log('✓ 关闭后：敌方仍可击破己方滚木（1 打 6 → 5）');
}

console.log('\n全部通过 ✓');
