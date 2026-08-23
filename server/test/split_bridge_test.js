// 桥 + 拆分回归测试（2026-08-12 牢大报 bug）
const R = require('../src/game/rules');

function cells(s) {
  return s.map.cells.map(c => {
    if (c.bridge) return '-';
    if (c.o === null) return '0';
    return c.o === 0 ? `[${c.v}]` : `{${c.v}}`;
  }).join(' ');
}

let pass = 0, fail = 0;
function check(name, cond) {
  if (cond) { pass++; console.log(`✅ ${name}`); }
  else { fail++; console.log(`❌ ${name}`); }
}

// 场景1（牢大报的 bug）：玩家1 单位7，左边（前方）临桥，拆 keep=4
// 预期：桥原位，other=3 在保留值4的另一侧（右侧）→ {桥}{4}[3] 的顺序
{
  const s = R.createGame({ limit: 16 });
  s.turn = 1; // 玩家1 回合
  s.map.cells[3] = { v: 7, o: 1 };
  s.map.cells[2] = { bridge: true };
  const r = R.applyAction(s, 1, { type: 'split', i: 3, keep: 4 });
  const line = cells(s);
  console.log('  场景1 结果:', line);
  check('场景1: 拆分成功', r.ok === true);
  check('场景1: 桥保持原位(位置2)', s.map.cells[2].bridge === true);
  check('场景1: 保留值4在原格(位置3)', s.map.cells[3].v === 4 && s.map.cells[3].o === 1);
  check('场景1: other=3在保留值右侧(位置4)', s.map.cells[4].v === 3 && s.map.cells[4].o === 1);
  check('场景1: 地图+1', s.map.cells.length === 9);
}

// 场景2：玩家0 单位7，右边（前方）临桥，拆 keep=4
// 预期：桥原位，other=3 插到保留值另一侧（左侧）
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[3] = { v: 7, o: 0 };
  s.map.cells[4] = { bridge: true };
  const r = R.applyAction(s, 0, { type: 'split', i: 3, keep: 4 });
  const line = cells(s);
  console.log('  场景2 结果:', line);
  check('场景2: 拆分成功', r.ok === true);
  check('场景2: other=3插在右侧(位置4)', s.map.cells[4].v === 3 && s.map.cells[4].o === 0);
  check('场景2: 保留值4在原格(位置3)', s.map.cells[3].v === 4 && s.map.cells[3].o === 0);
  check('场景2: 桥被顶到产物后(位置5)', s.map.cells[5].bridge === true);
  check('场景2: 地图+1', s.map.cells.length === 9);
}

// 场景3：无桥正常拆分（回归）
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[3] = { v: 7, o: 0 };
  const r = R.applyAction(s, 0, { type: 'split', i: 3, keep: 4 });
  const line = cells(s);
  console.log('  场景3 结果:', line);
  check('场景3: 拆分成功', r.ok === true);
  check('场景3: keep在原格', s.map.cells[3].v === 4);
  check('场景3: other在右侧', s.map.cells[4].v === 3);
}

// 场景4：满员拆分（保大）不受影响
{
  const s = R.createGame({ limit: 8 }); // 初始4格
  s.map.cells[3] = { v: 7, o: 0 };
  for (let k = 0; k < 4; k++) s.map.cells.push({ v: 0, o: null }); // 撑到满员8格
  const r = R.applyAction(s, 0, { type: 'split', i: 3, keep: 5 });
  const line = cells(s);
  console.log('  场景4 结果:', line);
  check('场景4: 满员拆分成功', r.ok === true);
  check('场景4: 只保留5', s.map.cells[3].v === 5);
  check('场景4: 地图没+1', s.map.cells.length === 8);
}

// ── 桥上吞噬规则（2026-08-12 傍晚牢大补充）：合并后 >=5 → 桥毁人亡 ──
function devourState(meV, tV, meOnBridge) {
  const s = R.createGame({ limit: 16 });
  s.map.cells[3] = { v: meV, o: 0, onBridge: meOnBridge };
  s.map.cells[4] = { v: tV, o: 1 };
  return s;
}

// 场景5：桥上 3 吞 2 → 5 ≥5 → 桥毁人亡
{
  const s = devourState(3, 2, true);
  const r = R.applyAction(s, 0, { type: 'devour', i: 3, j: 4 });
  const line = cells(s);
  console.log('  场景5 结果:', line);
  check('场景5: 吞噬成功', r.ok === true);
  check('场景5: 桥上单位死亡(原格变空地)', s.map.cells[3].v === 0);
  check('场景5: 桥也没了', s.map.cells[3].onBridge !== true);
  check('场景5: 目标消失(被吞)', s.map.cells[4].v === 0 || s.map.cells.length < 9);
}

// 场景6：桥上 2 吞 2 → 4 <5 → 安全留在桥上
{
  const s = devourState(2, 2, true);
  const r = R.applyAction(s, 0, { type: 'devour', i: 3, j: 4 });
  const line = cells(s);
  console.log('  场景6 结果:', line);
  check('场景6: 吞噬成功', r.ok === true);
  check('场景6: 合并后4在桥上', s.map.cells[3].v === 4 && s.map.cells[3].onBridge === true);
}

// 场景7：地上 4 吞 1 → 5（不在桥上，没事）
{
  const s = devourState(4, 1, false);
  const r = R.applyAction(s, 0, { type: 'devour', i: 3, j: 4 });
  const line = cells(s);
  console.log('  场景7 结果:', line);
  check('场景7: 吞噬成功', r.ok === true);
  check('场景7: 地上5正常存活', s.map.cells[3].v === 5);
}

// 场景8：桥上 4 吞 1 → 5 ≥5 → 桥毁人亡
{
  const s = devourState(4, 1, true);
  const r = R.applyAction(s, 0, { type: 'devour', i: 3, j: 4 });
  const line = cells(s);
  console.log('  场景8 结果:', line);
  check('场景8: 吞噬成功', r.ok === true);
  check('场景8: 桥毁人亡(原格变空地)', s.map.cells[3].v === 0);
}

// 场景9：两桥夹击（牢大例子 -5- → 期望 -41-）
{
  const s = R.createGame({ limit: 16 });
  s.map.cells[0] = { bridge: true };
  s.map.cells[1] = { v: 5, o: 0 };
  s.map.cells[2] = { bridge: true };
  const r = R.applyAction(s, 0, { type: 'split', i: 1, keep: 4 });
  const line = cells(s);
  console.log('  场景9 结果:', line);
  check('场景9: 拆分成功', r.ok === true);
  check('场景9: 左桥原位(位置0)', s.map.cells[0].bridge === true);
  check('场景9: keep=4在位置1', s.map.cells[1].v === 4 && s.map.cells[1].o === 0);
  check('场景9: other=1在keep右侧(位置2)', s.map.cells[2].v === 1 && s.map.cells[2].o === 0);
  check('场景9: 右桥被顶到产物后(位置3)', s.map.cells[3].bridge === true);
}

console.log(`\n共 ${pass + fail} 项: ${pass} 通过, ${fail} 失败`);
process.exit(fail > 0 ? 1 : 0);
