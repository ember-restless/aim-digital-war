import 'dart:math';
import '../lib/tutorial/tutorial_engine.dart';
import '../lib/game/rules.dart';

String fmtTut(List<TutCell> cs) {
  final buf = StringBuffer();
  for (final c in cs) {
    if (c.isB) buf.write('-');
    else if (c.v == 0) buf.write('0');
    else if (c.o == 1) buf.write('{${c.v}}');
    else buf.write('${c.v}');
  }
  return buf.toString();
}

String fmtGame(List<AimCell> cs) {
  final buf = StringBuffer();
  for (final c in cs) {
    if (c.bridge) buf.write('-');
    else if (c.v == 0) buf.write('0');
    else if (c.o == 1) buf.write('{${c.v}}');
    else buf.write('${c.v}');
  }
  return buf.toString();
}

void main() {
  print('═══ 教程 TutEngine（重写后）═══');
  final e = TutEngine();
  e.load([
    {'board': ['6', '0', '2', '0', '0', '0', '0', '7']},
    {'end': true},
  ]);
  while (e.boardPending) { e.applyPendingBoard(); }
  print('初始: ${fmtTut(e.cells)}');
  for (int k = 1; k <= 3; k++) {
    e.rollStep(0, k);
    print('rollStep($k): ${fmtTut(e.cells)} (${e.cells.length}格)  rollSteps=${e.lastRollSteps}');
  }
  // pressed 语义
  final e2 = TutEngine();
  e2.load([
    {'board': ['6', '0', '2', '0', '0', '0', '0', '7']},
    {'end': true},
  ]);
  while (e2.boardPending) { e2.applyPendingBoard(); }
  e2.rollStep(0, 1);
  TutCell? r;
  for (final c in e2.cells) {
    if (c.isUnit && c.v == 6) r = c;
  }
  print('step1 后滚木: v=${r?.v} pressedV=${r?.pressedV} pressedO=${r?.pressedO}');
  print('step1 棋盘: ${fmtTut(e2.cells)}');

  print('═══ 游戏 AimGame（对照）═══');
  final g = AimGame(limit: 16);
  g.cells = [
    AimCell(6, o: 0), AimCell(0), AimCell(2, o: 0),
    AimCell(0), AimCell(0), AimCell(0), AimCell(0), AimCell(7, o: 0),
  ];
  print('初始: ${fmtGame(g.cells)}');
  g.autoRoll(0);
  print('autoRoll: ${fmtGame(g.cells)} (${g.cells.length}格)  rollSteps=${g.rollSteps}');
}
