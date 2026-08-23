import 'package:aim/game/rules.dart';

String board(AimGame g) => g.cells.map((c) => c.bridge ? '-' : '${c.v}').join('');
String detail(AimGame g) => g.cells.map((c) => c.bridge ? '-' : '${c.v}${c.o == null ? '_' : 'p${c.o! + 1}'}${c.auto ? 'a' : ''}${c.onBridge ? 'B' : ''}${c.pressedV != null ? '[$c.pressedV]' : ''}').join(' ');

void main() {
  final g = AimGame(limit: 16);
  g.turn = 0; g.phase = null; g.points = 0; g.produceLeft = 0;
  print('初始: ${board(g)}');
  print('  ${detail(g)}');

  // 序列：双方轮流造兵（index1/index6 升级），玩家1 移动5两次，玩家2 造兵升出6
  // 1. 玩家1 造兵 1@1
  g.applyAction(0, {'type': 'produce', 'i': 0});
  g.applyAction(0, {'type': 'endTurn'});
  print('1. ${board(g)} (81000008)');
  print('  ${detail(g)}');
  // 2. 玩家2 造兵 1@6
  g.applyAction(1, {'type': 'produce', 'i': 7});
  g.applyAction(1, {'type': 'endTurn'});
  print('2. ${board(g)} (81000018)');
  print('  ${detail(g)}');
  // 3-10. 轮流升级
  for (var round = 3; round <= 10; round++) {
    final owner = (round % 2 == 1) ? 0 : 1;
    final base = (owner == 0) ? 0 : 7;
    g.applyAction(owner, {'type': 'produce', 'i': base});
    g.applyAction(owner, {'type': 'endTurn'});
    print('$round. ${board(g)} (${round % 2 == 1 ? '8${round ~/ 2 + 1}' : '8${round ~/ 2}'}00000${round % 2 == 0 ? (round ~/ 2).toString() : '0'})');
    print('  ${detail(g)}');
  }
}
