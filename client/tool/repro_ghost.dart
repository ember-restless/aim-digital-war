import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

void main() {
  // 场景 A：850-128，5 走两步到桥
  var g = AimGame(limit: 16);
  g.cells = List.generate(7, (i) => AimCell(0));
  g.cells[0] = AimCell(8, o: 0);
  g.cells[1] = AimCell(5, o: 0);
  g.cells[3] = AimCell(0, bridge: true);
  g.cells[4] = AimCell(1, o: 1);
  g.cells[5] = AimCell(2, o: 1);
  g.cells[6] = AimCell(8, o: 1);
  print('A 初始(${g.cells.length}): ${boardStr(g)}');
  g.phase = 'action'; g.points = 5; g.turn = 0;
  g.doMove(0, 1, 2);
  print('A 5走两步后(${g.cells.length}): ${boardStr(g)}  期望 800128（6格）');

  // 场景 B：80000568，6@6 往左滚（玩家1）
  var g2 = AimGame(limit: 16);
  g2.cells = List.generate(8, (i) => AimCell(0));
  g2.cells[0] = AimCell(8, o: 0);
  g2.cells[5] = AimCell(5, o: 0);
  g2.cells[6] = AimCell(6, o: 1);
  g2.cells[7] = AimCell(8, o: 1);
  print('\nB 初始(${g2.cells.length}): ${boardStr(g2)}');
  g2.endTurn(0, deferRoll: false); // 玩家0结束 → 玩家1滚木滚（往左）
  print('B 6滚完后(${g2.cells.length}): ${boardStr(g2)}');

  // 场景 C：80000568，6@6 往右滚（玩家0）
  var g3 = AimGame(limit: 16);
  g3.cells = List.generate(8, (i) => AimCell(0));
  g3.cells[0] = AimCell(8, o: 0);
  g3.cells[5] = AimCell(5, o: 0);
  g3.cells[6] = AimCell(6, o: 0);
  g3.cells[7] = AimCell(8, o: 1);
  print('\nC 初始(${g3.cells.length}): ${boardStr(g3)}');
  g3.turn = 1;
  g3.endTurn(1, deferRoll: false); // 玩家1结束 → 玩家0滚木滚（往右）
  print('C 6滚完后(${g3.cells.length}): ${boardStr(g3)}');
}
