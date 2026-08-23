// 压力测试 v2：混合真实行为（造兵为主 + 偶尔行动），跑 500 回合找滚木 bug
const R = require('../src/game/rules');

let s = R.createGame({ limit: 16 });
let turns = 0;
const MAX = 500;

function line() {
  return s.map.cells.map(c => {
    if (c.bridge) return '-';
    if (c.o === null) return '0';
    return c.o === 0 ? `[${c.v}]` : `{${c.v}}`;
  }).join(' ');
}

function validate() {
  const cells = s.map.cells;
  if (cells.length > s.map.limit) throw new Error(`地图超上限: ${cells.length}`);
  // 注意：基地可被降级/吞噬，两端不一定是基地（合法机制）
  cells.forEach((c, i) => {
    if (c.v < 0 || c.v > 9) throw new Error(`非法数字: 格${i} v=${c.v}`);
  });
  // 检查 auto 残留：v!==6 但 auto=true 的单位（bug 特征）
  cells.forEach((c, i) => {
    if (c.auto === true && c.v !== 6) {
      throw new Error(`auto 残留: 格${i} v=${c.v} auto=true`);
    }
  });
  // 检查重复引用（滚木复制 bug 特征）
  const refs = new Set();
  cells.forEach(c => {
    if (refs.has(c)) throw new Error('重复引用（滚木复制）!');
    refs.add(c);
  });
}

try {
  while (turns < MAX) {
    const owner = s.turn;
    if (s.winner !== null) {
      console.log(`=== 第${turns}回合游戏结束，胜者: 玩家${s.winner} ===`);
      console.log('最终:', line());
      process.exit(0);
    }
    const acts = R.getLegalActions(s, owner);
    if (acts.length === 0) {
      // 无合法行动：要么点数耗尽（maybeAutoEnd 应已处理），要么死局
      throw new Error(`无合法行动（第${turns}回合 phase=${s.phase} pts=${s.points} prod=${s.produceLeft}）: ${line()}`);
    }
    // 行为模拟：80% 造兵（点基地），20% 行动（移动/攻击/拆分/吞噬随机）
    const prod = acts.find(a => a.type === 'produce');
    let chosen;
    if (s.phase === 'produce' && prod) {
      chosen = prod;
    } else if (s.phase === 'produce' && !prod) {
      chosen = acts.find(a => a.type === 'endTurn') || acts[0];
    } else if (s.phase === 'action' || s.phase === null) {
      const nonEnd = acts.filter(a => a.type !== 'endTurn' && a.type !== 'choosePhase');
      if (nonEnd.length > 0) {
        // 80% 造兵 / 20% 行动
        if (prod && Math.random() < 0.8) chosen = prod;
        else chosen = nonEnd[Math.floor(Math.random() * nonEnd.length)];
      } else {
        chosen = acts.find(a => a.type === 'endTurn') || acts[0];
      }
    } else {
      chosen = acts[0];
    }
    const r = R.applyAction(s, owner, chosen);
    if (!r.ok) {
      // 如果失败是因为点数耗尽后 endTurn 被拒？不，endTurn 在耗尽后允许
      throw new Error(`行动失败 ${JSON.stringify(chosen)}: ${r.reason} | ${line()}`);
    }
    turns++;
    if (turns % 100 === 0) {
      validate();
      console.log(`第${turns}回合: ${line()}`);
    }
  }
  console.log('=== 500 回合混合行为无异常 ===');
  console.log('最终:', line());
} catch (e) {
  console.log('❌ BUG 复现!');
  console.log('  错误:', e.message);
  console.log('  回合:', turns);
  console.log('  状态:', line());
  process.exit(1);
}
