// 验证：桥上单位受溢出伤害 → 被桥挤开 → onBridge 残留 → 走开凭空造桥
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

void main() {
  var g = AimGame(limit: 16);
  g.cells = List.generate(9, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[3] = AimCell(0, bridge: true); // 桥
  g.cells[4] = AimCell(2, o: 0, onBridge: true); // 轻骑站在桥上（onBridge 标志）
  g.cells[5] = AimCell(0);
  g.cells[8] = AimCell(8, o: 1);
  print('初始(${g.cells.length}格): ${boardStr(g)}  桥数=${g.cells.where((c) => c.bridge).length}');

  // 7 攻击桥上的 2：2-7=-5 → 5 + 插桥（2 被挤到右边）
  g.phase = 'action'; g.points = 5; g.turn = 0;
  // 需要一个 7 来攻击
  g.cells[2] = AimCell(7, o: 0);
  print('攻击前: ${boardStr(g)}');
  g.doAttack(0, 2, 4);
  print('溢出攻击后(${g.cells.length}格): ${boardStr(g)}  桥数=${g.cells.where((c) => c.bridge).length}');
  final moved = g.cells[5];
  print('被挤开的单位: v=${moved.v} o=${moved.o} onBridge=${moved.onBridge}');

  // 被挤开的 5 移动走开：如果 onBridge 残留 → 原地凭空造桥
  g.points = 5;
  final ok = g.doMove(0, 5, 1);
  print('移动后(${g.cells.length}格): ${boardStr(g)}  桥数=${g.cells.where((c) => c.bridge).length}');
  final bridgeCount = g.cells.where((c) => c.bridge).length;
  print(bridgeCount == 2 ? '❌ 凭空多了一座桥（onBridge 残留 bug）' : '✅ 桥数正常（${bridgeCount}）');
}
