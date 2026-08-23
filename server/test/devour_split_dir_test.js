// 吞噬超9拆分方向：棋盘从左到右读 = 十进制（十位在左、个位在右）
// 回归：右方(玩家1) 7吞5=12 之前生成"21"，现在必须"12"
'use strict';
const assert = require('assert');
const { createGame, applyAction } = require('../src/game/rules.js');

function board12(rows) {
  const g = createGame({ limit: 12 });
  g.map.cells = rows.map(([v, o]) => ({ v, o: o === undefined ? null : o, bridge: false, onBridge: false, auto: false }));
  g.phase = 'action';
  g.turn = 0;
  g.points = 5;
  return g;
}

const empty = () => [0, null];

function test(name, fn) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
  } catch (e) {
    console.error(`  ✗ ${name}\n    ${e.message}`);
    process.exitCode = 1;
  }
}

console.log('吞噬拆分方向（服务端）');

test('左方(玩家0) 7吞5=12 → me=1(十位)，目标位=2(个位)：左1右2', () => {
  const g = board12([
    [8, 0], [7, 0], [5, 0], empty(), empty(), empty(), empty(), empty(), empty(), empty(), empty(), [8, 1],
  ]);
  const r = applyAction(g, 0, { type: 'devour', i: 1, j: 2 });
  assert.equal(r.ok, true);
  assert.equal(g.map.cells[1].v, 1);
  assert.equal(g.map.cells[2].v, 2);
  assert.equal(g.map.cells[1].o, 0);
  assert.equal(g.map.cells[2].o, 0);
});

test('右方(玩家1) 7吞5=12 → me=2(个位)，目标位=1(十位)：仍是左1右2', () => {
  const g = board12([
    [8, 0], empty(), empty(), empty(), empty(), empty(), empty(), empty(), empty(), [5, 1], [7, 1], [8, 1],
  ]);
  g.turn = 1;
  const r = applyAction(g, 1, { type: 'devour', i: 10, j: 9 });
  assert.equal(r.ok, true);
  assert.equal(g.map.cells[9].v, 1, '目标位（左）应为十位 1');
  assert.equal(g.map.cells[10].v, 2, 'me（右）应为个位 2');
  assert.equal(g.map.cells[9].o, 1);
  assert.equal(g.map.cells[10].o, 1);
});

test('右方(玩家1) 8吞2=10 → me 变空，目标位 1', () => {
  const g = board12([
    [8, 0], empty(), empty(), empty(), empty(), empty(), empty(), empty(), empty(), [2, 1], [8, 1], [8, 1],
  ]);
  g.turn = 1;
  const r = applyAction(g, 1, { type: 'devour', i: 10, j: 9 });
  assert.equal(r.ok, true);
  assert.equal(g.map.cells[9].v, 1);
  assert.equal(g.map.cells[9].o, 1);
  assert.equal(g.map.cells[10].v, 0, 'me 变空');
  assert.equal(g.map.cells[10].o, null, '空地不能残留归属');
});
