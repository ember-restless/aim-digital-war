// 滚木操控限制测试：第一回合可操控，自动滚动后锁定，被打降级后恢复
const R = require('../src/game/rules');

function line(s) {
  return s.map.cells.map(c => {
    if (c.bridge) return '-';
    if (c.o === null) return '0';
    return c.o === 0 ? `[${c.v}]` : `{${c.v}}`;
  }).join(' ');
}
function ok(cond, msg) {
  console.log((cond ? '✅' : '❌') + ' ' + msg);
  if (!cond) process.exitCode = 1;
}

// 场景：我方滚木刚制造（当回合），可操控
let s = R.createGame({ limit: 16 });
s.map.cells[2] = { v: 6, o: 0 }; // 刚造出的滚木（无 auto）
R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
let acts = R.getLegalActions(s, 0);
let rollerActs = acts.filter(a => a.get && a.i === 2);
// getLegalActions 返回普通对象数组，检查 i===2 的行动
rollerActs = acts.filter(a => a.i === 2);
ok(rollerActs.length > 0, '第一回合滚木可操控（有行动选项）');
console.log('  滚木行动:', JSON.stringify(rollerActs.slice(0, 3)));

// 过回合触发自动滚动 → 锁定（先耗完点数）
s.points = 0;
R.applyAction(s, 0, { type: 'endTurn' });
s.points = 0;
R.applyAction(s, 1, { type: 'endTurn' }); // 轮到玩家0，滚木自动前进
R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
acts = R.getLegalActions(s, 0);
rollerActs = acts.filter(a => a.i && s.map.cells[a.i] && s.map.cells[a.i].v === 6);
ok(rollerActs.length === 0, '第二回合滚木不可操控（无行动选项）');
console.log('  滚木位置:', line(s));

// 被打降级后恢复操控
// 找到滚木位置
const ri = s.map.cells.findIndex(c => c.v === 6 && c.o === 0);
if (ri >= 0) {
  // 手动模拟被打：6→5
  s.map.cells[ri].v = 5;
  s.map.cells[ri].auto = false;
  s.points = 0;
  R.applyAction(s, 0, { type: 'endTurn' });
  s.points = 0;
  R.applyAction(s, 1, { type: 'endTurn' });
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  acts = R.getLegalActions(s, 0);
  const fiveActs = acts.filter(a => a.i === ri);
  ok(fiveActs.length > 0, '滚木被打成5后恢复可操控');
  console.log('  降级后行动:', JSON.stringify(fiveActs.slice(0, 2)));
}
