// 压力测试：双方无限造兵（造出滚木），找滚木相关 bug
const R = require('../src/game/rules');

let s = R.createGame({ limit: 16 });
let turns = 0;
const MAX = 300;

function line() {
  return s.map.cells.map(c => {
    if (c.bridge) return '-';
    if (c.o === null) return '0';
    return c.o === 0 ? `[${c.v}]` : `{${c.v}}`;
  }).join(' ');
}

function validate() {
  // 基本不变量检查
  const cells = s.map.cells;
  if (cells.length > s.map.limit) throw new Error(`地图超上限: ${cells.length} > ${s.map.limit}`);
  // 两端必须是双方基地
  if (cells[0].v !== 8 || cells[0].o !== 0) throw new Error(`左端不是玩家0基地: ${JSON.stringify(cells[0])}`);
  if (cells[cells.length - 1].v !== 8 || cells[cells.length - 1].o !== 1) throw new Error(`右端不是玩家1基地`);
}

try {
  while (turns < MAX) {
    const owner = s.turn;
    // 模拟玩家行为：疯狂点造兵（点基地）
    if (s.phase === null || s.phase === 'produce') {
      const acts = R.getLegalActions(s, owner);
      const prod = acts.find(a => a.type === 'produce');
      if (prod) {
        const r = R.applyAction(s, owner, prod);
        if (!r.ok) throw new Error(`造兵失败: ${r.reason} | ${line()}`);
      } else {
        // 没有可造的（被桥挡）→ 本回合已选阶段但无事可做？检查点数
        if (s.phase === 'produce' && s.produceLeft > 0) {
          // 应该被 maybeAutoEnd 处理？没有——produceLeft>0 但没有 produce 目标（桥挡）
          // 这会是死局吗？牢大说不可能。但这里发生了——记录！
          console.log(`⚠ 造兵目标被挡（第${turns}回合）: ${line()}`);
          // 手动清零避免卡死（模拟端不会发生，服务端这样会卡）
          s.produceLeft = 0;
          R.applyAction(s, owner, { type: 'endTurn' });
          turns++;
          continue;
        }
        // phase null 且没 produce 目标？正常（有基地但前方桥）→ 跳过本回合
        R.applyAction(s, owner, { type: 'endTurn' });
        turns++;
        continue;
      }
    }
    turns++;
    if (turns % 50 === 0) {
      validate();
      console.log(`第${turns}回合: ${line()}`);
    }
  }
  console.log('=== 300 回合无异常 ===');
  console.log('最终:', line());
} catch (e) {
  console.log('❌ BUG 复现!');
  console.log('  错误:', e.message);
  console.log('  回合:', turns);
  console.log('  状态:', line());
  console.log('  turn:', s.turn, 'phase:', s.phase, 'pts:', s.points, 'prod:', s.produceLeft);
  process.exit(1);
}
