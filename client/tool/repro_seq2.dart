import 'package:aim/game/rules.dart';

String board(AimGame g) => g.cells.map((c) => c.bridge ? '-' : '${c.v}').join('');
String detail(AimGame g) => g.cells.map((c) => c.bridge ? '-' : '${c.v}${c.o == null ? '_' : 'p${c.o! + 1}'}${c.auto ? 'a' : ''}${c.onBridge ? 'B' : ''}${c.pressedV != null ? '[$c.pressedV]' : ''}').join(' ');

void main() {
  final g = AimGame(limit: 16);
  g.turn = 0; g.phase = null; g.points = 0; g.produceLeft = 0;
  // 前10步：双方造兵升级到5
  for (var round = 0; round < 5; round++) {
    g.applyAction(0, {'type': 'produce', 'i': 0});
    g.applyAction(0, {'type': 'endTurn'});
    g.applyAction(1, {'type': 'produce', 'i': 7});
    g.applyAction(1, {'type': 'endTurn'});
  }
  print('10步后: ${board(g)} (85000058)');
  print('  ${detail(g)}');

  // 11. 玩家1 移动 5（index1 → index3，走2格）
  g.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
  final r11 = g.applyAction(0, {'type': 'move', 'i': 1, 'steps': 2});
  print('11. 移动5: ok=${r11['ok']} ${r11['reason'] ?? ''} → ${board(g)} (期望 80050058)');
  print('  ${detail(g)}');
  g.applyAction(0, {'type': 'endTurn'});

  // 12. 玩家2 造兵升级 5→6（滚木！）
  final r12 = g.applyAction(1, {'type': 'produce', 'i': 7});
  print('12. 玩家2造兵: ok=${r12['ok']} → ${board(g)} (期望 80050068)');
  print('  ${detail(g)}');
  g.applyAction(1, {'type': 'endTurn'});

  // 13. 玩家1 移动 5（index3 → index5，走2格）
  g.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
  final r13 = g.applyAction(0, {'type': 'move', 'i': 3, 'steps': 2});
  print('13. 移动5: ok=${r13['ok']} → ${board(g)} (期望 80000568)');
  print('  ${detail(g)}');
  // points 0 → maybeAutoEnd 自动过回合 → 6 滚！
  print('自动过回合后: ${board(g)}');
  print('  ${detail(g)}');
  print('turn=${g.turn + 1} rollSeq=${g.rollSeq} rollPending=${g.hasPendingRoll}');
  print('rollSteps=${g.rollSteps}');
}
