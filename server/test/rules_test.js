// 规则引擎冒烟测试
const R = require('../src/game/rules');

function logState(s, label) {
  console.log(`\n=== ${label} ===`);
  const line = s.map.cells.map(c => {
    if (c.bridge) return '-';
    if (c.o === null) return '0';
    return c.o === 0 ? `[${c.v}]` : `{${c.v}}`;
  }).join(' ');
  console.log(line);
  console.log(`turn=${s.turn} phase=${s.phase} pts=${s.points} prod=${s.produceLeft} win=${s.winner}`);
}

// 测试1：基础移动
let s = R.createGame({ limit: 16 });
logState(s, '初始（16上限，8格）');

// 玩家0选择行动
console.log(R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' }));
// 玩家0造兵？先测试造兵：选produce
s = R.createGame({ limit: 16 });
R.applyAction(s, 0, { type: 'choosePhase', phase: 'produce' });
logState(s, '玩家0选造兵');
// 基地前方一格是空地0 → +1 变成小兵1
const prod = R.getLegalActions(s, 0).find(a => a.type === 'produce');
console.log('合法造兵:', prod);
console.log(R.applyAction(s, 0, prod));
logState(s, '造兵后（基地前应出现[1]）');
console.log('敌方数字和:', R.sumOf(s, 1), '我方:', R.sumOf(s, 0));
console.log(R.applyAction(s, 0, { type: 'endTurn' }));
logState(s, '过回合后（轮到玩家1）');

// 测试2：行动阶段移动+攻击
s = R.createGame({ limit: 16 });
R.applyAction(s, 0, { type: 'choosePhase', phase: 'produce' });
R.applyAction(s, 0, R.getLegalActions(s, 0).find(a => a.type === 'produce')); // 造1
R.applyAction(s, 0, { type: 'endTurn' });
// 玩家1也造一个
R.applyAction(s, 1, { type: 'choosePhase', phase: 'produce' });
R.applyAction(s, 1, R.getLegalActions(s, 1).find(a => a.type === 'produce'));
R.applyAction(s, 1, { type: 'endTurn' });
logState(s, '双方各造一个1');
// 玩家0行动：移动小兵
R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
const moves = R.getLegalActions(s, 0).filter(a => a.type === 'move');
console.log('合法移动:', moves);
if (moves.length) R.applyAction(s, 0, moves[0]);
logState(s, '小兵前进一步');

// 测试3：拆分
s = R.createGame({ limit: 16 });
// 直接手动放一个5在中间测试
s.map.cells[2] = { v: 5, o: 0 };
s.map.cells[3] = { v: 0, o: null };
s.map.cells[4] = { v: 0, o: null };
R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
const splits = R.getLegalActions(s, 0).filter(a => a.type === 'split');
console.log('\n合法拆分(5):', JSON.stringify(splits));
if (splits.length) {
  console.log(R.applyAction(s, 0, { type: 'split', i: 2, keep: 2 })); // 5 → 2 + 3(右边)
  logState(s, '拆分后(5→2+3)');
}

// 测试4：吞噬
s = R.createGame({ limit: 16 });
s.map.cells[2] = { v: 5, o: 0 };
s.map.cells[3] = { v: 3, o: 1 }; // 敌方3
R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
const dev = R.getLegalActions(s, 0).find(a => a.type === 'devour');
console.log('\n合法吞噬:', dev);
if (dev) {
  console.log(R.applyAction(s, 0, dev));
  logState(s, '吞噬后 5+3=8 基地');
  console.log('基地数(0):', R.countOf(s, 0, 8));
}

// 测试5：伤害溢出 → 插桥
s = R.createGame({ limit: 16 });
s.map.cells[2] = { v: 1, o: 0 }; // 我方小兵1
R.applyAction(s, 0, { type: 'choosePhase', phase: 'action' });
// 敌方攻击它？直接模拟：applyDamage
s.map.cells[3] = { v: 3, o: 1 }; // 敌方3弓手（射程2）
const atk = R.getLegalActions(s, 1) // 不，是玩家0回合。手动测试伤害：
// 直接调用内部不行，用攻击：让敌方3攻击？turn是0。先过回合。
R.applyAction(s, 0, { type: 'endTurn' });
// 玩家1回合：3弓手攻击小兵1
R.applyAction(s, 1, { type: 'choosePhase', phase: 'action' });
const atks = R.getLegalActions(s, 1).filter(a => a.type === 'attack');
console.log('\n敌方合法攻击:', atks);
if (atks.length) {
  console.log(R.applyAction(s, 1, atks[0]));
  logState(s, '1受3伤后（应插入独木桥-）');
}

// 测试6：滚木
s = R.createGame({ limit: 16 });
s.map.cells[2] = { v: 6, o: 0 }; // 我方滚木
s.map.cells[3] = { v: 2, o: 1 }; // 敌方轻骑
s.map.cells[4] = { v: 3, o: 1 }; // 敌方弓手（第三格，抹杀）
logState(s, '滚木前');
R.applyAction(s, 0, { type: 'endTurn' }); // 过回合触发玩家1滚木？不，是玩家0的滚木，玩家1回合开始不滚
// 玩家1过回合 → 玩家0回合开始 → 玩家0滚木自动前进
R.applyAction(s, 1, { type: 'endTurn' });
logState(s, '玩家0回合开始，滚木自动前进3格后');

// 测试7：盾兵7免疫弓兵3/炮兵4远程伤害（2026-08-12 牢大补充）
// 给玩家1两个指挥部9 → 3行动点，一轮内连续射多箭
s = R.createGame({ limit: 16 });
s.map.cells[1] = { v: 5, o: 0 }; // 盾兵身后的重骑兵
s.map.cells[2] = { v: 7, o: 0 }; // 我方盾兵
s.map.cells[3] = { v: 3, o: 1 }; // 敌方弓手（射程2 → 打2、1）
s.map.cells[5] = { v: 9, o: 1 }; // 敌方指挥部×2 → 3行动点
s.map.cells[6] = { v: 9, o: 1 };
s.turn = 1;
R.applyAction(s, 1, { type: 'choosePhase', phase: 'action' });
logState(s, '盾兵屏障测试前（弓手3在3，射程2）');
console.log('弓手射盾兵(2):', R.applyAction(s, 1, { type: 'attack', i: 3, j: 2 }));
console.log('盾兵血量应仍为7:', s.map.cells[2].v);
console.log('弓手射盾兵身后重骑(1):', R.applyAction(s, 1, { type: 'attack', i: 3, j: 1 }));
console.log('重骑血量应仍为5:', s.map.cells[1].v);
logState(s, '两箭后（应无任何变化）');

// 对照1：无盾兵保护的近战单位被弓手射 → 正常掉血
s = R.createGame({ limit: 16 });
s.map.cells[2] = { v: 5, o: 0 }; // 无盾兵保护的重骑
s.map.cells[4] = { v: 3, o: 1 }; // 敌方弓手（射程2 → 打3、2）
s.turn = 1;
R.applyAction(s, 1, { type: 'choosePhase', phase: 'action' });
console.log('\n对照：弓手射无保护重骑(2):', R.applyAction(s, 1, { type: 'attack', i: 4, j: 2 }));
console.log('重骑血量应降为4:', s.map.cells[2].v);

// 对照2：近战5打盾兵 → 正常掉血
s = R.createGame({ limit: 16 });
s.map.cells[2] = { v: 7, o: 0 }; // 盾兵
s.map.cells[3] = { v: 5, o: 1 }; // 敌方重骑
s.turn = 1;
R.applyAction(s, 1, { type: 'choosePhase', phase: 'action' });
console.log('\n对照：近战5砍盾兵(2):', R.applyAction(s, 1, { type: 'attack', i: 3, j: 2 }));
console.log('盾兵血量应降为2:', s.map.cells[2].v);

// 对照3：炮兵4射盾兵身后单位 → 也免疫（射程3 → 打2、1、0）
s = R.createGame({ limit: 16 });
s.map.cells[1] = { v: 5, o: 0 }; // 盾兵身后重骑
s.map.cells[2] = { v: 7, o: 0 }; // 盾兵
s.map.cells[0] = { v: 8, o: 0 }; // 基地（盾兵身后）
s.map.cells[3] = { v: 4, o: 1 }; // 敌方炮手（射程3 → 打2、1、0）
s.map.cells[5] = { v: 9, o: 1 }; // 敌方指挥部×3 → 4行动点
s.map.cells[6] = { v: 9, o: 1 };
s.map.cells[7] = { v: 9, o: 1 }; // 覆盖掉原基地8？不，先保留——7格改9，8在末格
s.turn = 1;
R.applyAction(s, 1, { type: 'choosePhase', phase: 'action' });
console.log('\n炮手射盾兵(2):', R.applyAction(s, 1, { type: 'attack', i: 3, j: 2 }));
console.log('炮手射身后重骑(1):', R.applyAction(s, 1, { type: 'attack', i: 3, j: 1 }));
console.log('炮手射身后基地(0):', R.applyAction(s, 1, { type: 'attack', i: 3, j: 0 }));
console.log('盾兵/重骑/基地应全无变化:', s.map.cells[2].v, s.map.cells[1].v, s.map.cells[0].v);

console.log('\n✅ 全部测试完成');
