// 规则层长度变化精确验证：每种行动的预期 delta
// 用法：dart run tool/verify_len_delta.dart
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

int failures = 0;
void check(String name, bool cond, String detail) {
  if (!cond) {
    failures++;
    print('❌ $name: $detail');
  } else {
    print('✅ $name');
  }
}

void main() {
  // ── 1. 重单位走桥塌桥：长度 -2 ──
  var g = AimGame(limit: 16);
  g.cells = List.generate(10, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[4] = AimCell(5, o: 0);
  g.cells[6] = AimCell(0, bridge: true); // 桥在两步外
  g.cells[9] = AimCell(8, o: 1);
  print('桥塌前(${g.cells.length}格): ${boardStr(g)}');
  g.phase = 'action'; g.points = 5; g.turn = 0;
  final ok = g.doMove(0, 4, 2);
  print('桥塌后(${g.cells.length}格): ${boardStr(g)}  ok=$ok');
  check('重单位走桥 长度-2', g.cells.length == 8, '实际 ${g.cells.length}');

  // ── 2. 拆分：长度 +1 ──
  g = AimGame(limit: 16);
  g.cells = List.generate(8, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[3] = AimCell(5, o: 0);
  g.cells[7] = AimCell(8, o: 1);
  g.phase = 'action'; g.points = 5; g.turn = 0;
  g.doSplit(0, 3, 2);
  print('拆分后(${g.cells.length}格): ${boardStr(g)}');
  check('拆分 长度+1', g.cells.length == 9, '实际 ${g.cells.length}');

  // ── 3. 溢出插桥：长度 +1 ──
  g = AimGame(limit: 16);
  g.cells = List.generate(8, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[4] = AimCell(2, o: 1);
  g.cells[5] = AimCell(7, o: 0);
  g.cells[7] = AimCell(8, o: 1);
  g.phase = 'action'; g.points = 5; g.turn = 0;
  g.doAttack(0, 5, 4); // 7 打 2：2-7=-5 → 5 + 桥
  print('插桥后(${g.cells.length}格): ${boardStr(g)}');
  check('溢出插桥 长度+1', g.cells.length == 9, '实际 ${g.cells.length}');

  // ── 4. 吞噬：长度 -1 ──
  g = AimGame(limit: 16);
  g.cells = List.generate(8, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[3] = AimCell(4, o: 0);
  g.cells[4] = AimCell(1, o: 1);
  g.cells[7] = AimCell(8, o: 1);
  g.phase = 'action'; g.points = 5; g.turn = 0;
  g.doDevour(0, 3, 4);
  print('吞噬后(${g.cells.length}格): ${boardStr(g)}');
  check('吞噬 长度-1', g.cells.length == 7, '实际 ${g.cells.length}');

  // ── 5. 小兵过桥拆桥：长度不变 ──
  g = AimGame(limit: 16);
  g.cells = List.generate(8, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[3] = AimCell(1, o: 0);
  g.cells[4] = AimCell(0, bridge: true);
  g.cells[7] = AimCell(8, o: 1);
  g.phase = 'action'; g.points = 5; g.turn = 0;
  g.doMove(0, 3, 1);
  print('小兵过桥后(${g.cells.length}格): ${boardStr(g)}');
  check('小兵过桥 长度不变', g.cells.length == 8, '实际 ${g.cells.length}');

  // ── 6. 轻单位过桥（2-4）：桥保留 ──
  g = AimGame(limit: 16);
  g.cells = List.generate(8, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[3] = AimCell(2, o: 0);
  g.cells[4] = AimCell(0, bridge: true);
  g.cells[5] = AimCell(0);
  g.cells[7] = AimCell(8, o: 1);
  g.phase = 'action'; g.points = 5; g.turn = 0;
  g.doMove(0, 3, 2); // 2 是骑兵走2格，跨过桥
  print('轻骑过桥后(${g.cells.length}格): ${boardStr(g)}');
  check('轻骑过桥 长度不变', g.cells.length == 8, '实际 ${g.cells.length}');

  // ── 7. 滚木撞桥：长度 -1 ──
  g = AimGame(limit: 16);
  g.cells = List.generate(8, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[3] = AimCell(0, bridge: true);
  g.cells[4] = AimCell(6, o: 0); // 滚木，滚向桥（往右）
  g.cells[7] = AimCell(8, o: 1);
  g.endTurn(1, deferRoll: false); // 玩家1 endTurn → 玩家0 滚木滚
  print('滚木撞桥后(${g.cells.length}格): ${boardStr(g)}');
  check('滚木撞桥 长度-1', g.cells.length == 7, '实际 ${g.cells.length}');

  // ── 8. 滚木压单位溢出插桥：长度 +1 ──
  g = AimGame(limit: 16);
  g.cells = List.generate(8, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[3] = AimCell(2, o: 1); // 敌人（滚木压它溢出）
  g.cells[4] = AimCell(6, o: 0);
  g.cells[7] = AimCell(8, o: 1);
  g.endTurn(1, deferRoll: false);
  print('滚木插桥后(${g.cells.length}格): ${boardStr(g)}');
  // 2 受6伤 → -4 → 4 + 桥（+1）
  check('滚木溢出插桥 长度+1', g.cells.length == 9, '实际 ${g.cells.length}');

  print(failures == 0 ? '\n🎉 全部通过' : '\n❌ $failures 处失败');
}
