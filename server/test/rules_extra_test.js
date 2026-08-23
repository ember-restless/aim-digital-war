// 关键机制专项测试
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

// T1: 溢出插桥方向（我方单位受击，桥应插在它前方=右）
{
  let s = R.createGame({ limit: 16 });
  s.map.cells[2] = { v: 1, o: 0 };
  s.map.cells[3] = { v: 2, o: 1 }; // 敌方2轻骑贴脸（射程1）
  R.applyAction(s, 0, { type: 'endTurn' });
  R.applyAction(s, 1, { type: 'choosePhase', phase: 'action' });
  const atk = R.getLegalActions(s, 1).find(a => a.type === 'attack' && a.j === 2);
  ok(!!atk, '敌方2轻骑能攻击我方小兵');
  if (atk) {
    R.applyAction(s, 1, atk);
    const l = line(s);
    console.log('  溢出后:', l);
    // 1受2伤=-1 → 桥插在1的左边（负数-在左）。期望 [8] 0 - [1] ...
    ok(l.includes('- [1]'), '小兵1左边插了桥（- [1]）');
    ok(s.map.cells.length === 9, '地图+1格（8→9）');
  }
}

// T2: 小兵过桥拆桥
{
  let s = R.createGame({ limit: 16 });
  s.map.cells = [
    { v: 8, o: 0 }, { v: 1, o: 0 }, { bridge: true }, { v: 0, o: null },
    { v: 0, o: null }, { v: 0, o: null }, { v: 0, o: null }, { v: 8, o: 1 },
  ];
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  // 小兵在1，前方2是桥 → 上桥
  const mv1 = R.getLegalActions(s, 0).find(a => a.type === 'move' && a.i === 1);
  ok(!!mv1, '小兵能上桥');
  if (mv1) {
    R.applyAction(s, 0, mv1);
    console.log('  上桥后:', line(s));
    ok(s.map.cells[2].onBridge === true && s.map.cells[2].v === 1, '小兵站在桥上（onBridge）');
    // 过回合再移动：小兵从桥出发，前方3是空地 → 走到3，桥变空地
    R.applyAction(s, 0, { type: 'endTurn' });
    R.applyAction(s, 1, { type: 'endTurn' });
    R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
    const mv2 = R.getLegalActions(s, 0).find(a => a.type === 'move' && a.i === 2);
    ok(!!mv2, '小兵能下桥');
    if (mv2) {
      R.applyAction(s, 0, mv2);
      const l = line(s);
      console.log('  拆桥后:', l);
      ok(!l.includes('-'), '桥被拆成空地');
    }
  }
}

// T3: 重单位走桥（UI 可选，后果桥塌人亡）
{
  let s = R.createGame({ limit: 16 });
  s.map.cells = [
    { v: 8, o: 0 }, { v: 5, o: 0 }, { bridge: true }, { v: 0, o: null },
    { v: 0, o: null }, { v: 0, o: null }, { v: 0, o: null }, { v: 8, o: 1 },
  ];
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  const fatal = R.getLegalActions(s, 0).find(a => a.type === 'move' && a.i === 1 && a.fatal);
  ok(!!fatal, '重骑兵5可选择走桥（fatal）');
  if (fatal) {
    R.applyAction(s, 0, fatal);
    const l = line(s);
    console.log('  走桥后:', l);
    ok(!l.includes('5') && !l.includes('-'), '桥塌人亡（桥删、5也死）');
    ok(s.map.cells.length === 6, '地图-2格（8→6）');
  }
}

// T4: 吞噬超9变拉
{
  let s = R.createGame({ limit: 16 });
  s.map.cells[2] = { v: 5, o: 0 };
  s.map.cells[3] = { v: 5, o: 1 }; // 吞敌方5
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  const dev = R.getLegalActions(s, 0).find(a => a.type === 'devour');
  ok(!!dev, '5能吞5');
  if (dev) {
    R.applyAction(s, 0, dev);
    const l = line(s);
    console.log('  5吞5后:', l);
    // 10 → [1]小兵 + [0]空地
    ok(l.includes('[1] 0'), '10拆成小兵1+空地0（变拉了）');
  }
}

// T5: 骑兵规则（2轻骑固定走2格，第2格有单位停1格）
{
  let s = R.createGame({ limit: 16 });
  s.map.cells = [
    { v: 8, o: 0 }, { v: 2, o: 0 }, { v: 0, o: null }, { v: 1, o: 1 },
    { v: 0, o: null }, { v: 0, o: null }, { v: 0, o: null }, { v: 8, o: 1 },
  ];
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  const moves = R.getLegalActions(s, 0).filter(a => a.type === 'move');
  ok(moves.length === 1 && moves[0].steps === 1, '第2格有单位，骑兵只能停1格（不能走2格）');
  if (moves.length) {
    R.applyAction(s, 0, moves[0]);
    console.log('  骑兵停1格:', line(s));
  }
  // 空地时骑兵必须走2格
  s = R.createGame({ limit: 16 });
  s.map.cells[2] = { v: 2, o: 0 };
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  const m2 = R.getLegalActions(s, 0).filter(a => a.type === 'move');
  ok(m2.some(a => a.steps === 2), '空地时骑兵走2格');
}

// T6: 造兵攻击敌方单位
{
  let s = R.createGame({ limit: 16 });
  s.map.cells[1] = { v: 3, o: 1 }; // 敌方3贴在基地前
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'produce' });
  const prod = R.getLegalActions(s, 0).find(a => a.type === 'produce');
  ok(!!prod, '基地前方是敌方单位时仍可造兵（=攻击）');
  if (prod) {
    R.applyAction(s, 0, prod);
    const l = line(s);
    console.log('  造兵攻击后:', l);
    ok(l.includes('{2}'), '敌方3被减成2');
  }
}

// T7: 吞噬出9（指挥部）
{
  let s = R.createGame({ limit: 16 });
  s.map.cells[2] = { v: 5, o: 0 };
  s.map.cells[3] = { v: 4, o: 1 };
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  const dev = R.getLegalActions(s, 0).find(a => a.type === 'devour');
  R.applyAction(s, 0, dev);
  const l = line(s);
  console.log('  5吞4后:', l);
  ok(l.includes('[9]'), '5吞4=9指挥部');
}

// T8: 建筑不可攻击 + 胜利条件——敌方数字和归0
{
  // 8.1 建筑不生成攻击/移动/吞噬行动
  let s = R.createGame({ limit: 16 });
  s.map.cells[6] = { v: 9, o: 0 }; // 我方指挥部
  s.map.cells[7] = { v: 8, o: 1 }; // 敌方基地贴脸
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  const acts = R.getLegalActions(s, 0);
  ok(!acts.some(a => a.type === 'attack'), '建筑不能攻击');
  ok(!acts.some(a => a.type === 'move'), '建筑不能移动');
  ok(!acts.some(a => a.type === 'devour'), '建筑不能吞噬');

  // 8.2 胜利条件
  s = R.createGame({ limit: 16 });
  // 敌方：只剩1个小兵1在7，我方1小兵在6贴脸
  for (let i = 0; i < 7; i++) s.map.cells[i] = { v: 0, o: null };
  s.map.cells[0] = { v: 8, o: 0 };
  s.map.cells[6] = { v: 1, o: 0 };
  s.map.cells[7] = { v: 1, o: 1 };
  ok(R.sumOf(s, 1) === 1, '敌方数字和=1');
  R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
  const fin = R.getLegalActions(s, 0).find(a => a.type === 'attack' && a.j === 7);
  ok(!!fin, '小兵1能攻击敌方小兵1');
  if (fin) {
    R.applyAction(s, 0, fin);
    console.log('  补刀后:', line(s), '胜者:', s.winner);
    ok(s.winner === 0, '敌方数字和归0，玩家0获胜');
  }
}
