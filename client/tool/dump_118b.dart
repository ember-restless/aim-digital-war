import 'package:aim/game/rules.dart';

void main() {
  // 场景1：80000568 滚木滚完，转正的 1 应 auto=false 且能攻击
  final g = AimGame(limit: 16);
  g.cells = [
    AimCell(8, o: 0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
    AimCell(5, o: 0), AimCell(6, o: 1), AimCell(8, o: 1),
  ];
  g.turn = 0; g.phase = null; g.points = 0; g.produceLeft = 0;
  g.endTurn(0, deferRoll: false);
  final c5 = g.cells[5];
  print('滚完 1@5: v=${c5.v} o=${c5.o} auto=${c5.auto}');
  print('期望: auto=false');

  // 场景2：80000118，玩家1 回合，1@5 攻击 1@6
  final g2 = AimGame(limit: 16);
  g2.cells = [
    AimCell(8, o: 0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
    AimCell(1, o: 0, auto: true), // 模拟滚木滚出来的 1（旧代码残留 auto=true）
    AimCell(1, o: 1), AimCell(8, o: 1),
  ];
  g2.turn = 0; g2.phase = 'action'; g2.points = 1; g2.produceLeft = 0;
  final r = g2.doAttack(0, 5, 6);
  print('1@5(auto=true) 攻击 1@6: ok=$r');
  print('攻击后棋盘: ${g2.cells.map((c) => "${c.v}${c.o == null ? '_' : 'p${c.o! + 1}'}").join(" ")}');
  // 移动也验证
  final g3 = AimGame(limit: 16);
  g3.cells = [
    AimCell(8, o: 0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
    AimCell(1, o: 0, auto: true), AimCell(0), AimCell(8, o: 1),
  ];
  g3.turn = 0; g3.phase = 'action'; g3.points = 1; g3.produceLeft = 0;
  final rm = g3.doMove(0, 5, 1);
  print('1@5(auto=true) 移动: ok=$rm');
}
