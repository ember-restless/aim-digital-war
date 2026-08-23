// 复现：滚木从右往左（owner=1）压单位溢出插桥，继续滚撞桥死亡
// 打印完整 rollSteps（联机路径）与每步棋盘
const R = require('../src/game/rules');

function line(s) {
  return s.map.cells.map(c => {
    if (c.bridge) return '-';
    if (c.o === null) return '0';
    return c.o === 0 ? `[${c.v}]` : `{${c.v}}`;
  }).join(' ');
}

let s = R.createGame({ limit: 16 });
// 摆盘：owner=1 的滚木在 index 8，左边 index 7 放一个 v=2 的单位（受6伤 → -4 → 4 + 插桥）
// owner=1 的基地在右侧，9 也要摆
s.map.cells = s.map.cells.map((c, i) => {
  if (i === 5) return { v: 2, o: 1, id: 700 + i };
  if (i === 6) return { v: 6, o: 1, id: 600 + i };
  return c;
});
console.log('初始棋盘(owner1滚木@6, 目标@5):', line(s));

// 触发 owner=1 的自动滚动：玩家0 endTurn
R.applyAction(s, 0, { type: 'endTurn' });
console.log('滚动后棋盘:', line(s));
console.log('rollSteps:', JSON.stringify(s.rollSteps, null, 1));
console.log('rollSeq:', s.rollSeq);
console.log('rollPending:', s.rollPending);
