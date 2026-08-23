import 'package:aim/game/rules.dart';

void main() {
  final game = AimGame(limit: 16);
  // 80000118: 8,0,0,0,0, 1(玩家1), 1(玩家2), 8
  game.cells = [
    AimCell(8, o: 0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
    AimCell(1, o: 0), AimCell(1, o: 1), AimCell(8, o: 1),
  ];
  game.turn = 0; // 玩家1 回合
  game.phase = null; game.points = 0; game.produceLeft = 0;
  print('棋盘: ${game.cells.map((c) => "${c.v}${c.o == null ? '_' : 'p${c.o! + 1}'}").join(" ")}');

  // 玩家1 视角的合法行动
  final v = game.viewFor(0);
  print('viewFor(0) legalActions:');
  for (final a in v['legalActions'] as List) print('  $a');
  final one = (v['legalActions'] as List).where((a) => (a['i'] == 5) || (a['j'] == 5)).toList();
  print('涉及 1@5 的行动: $one');

  // 直接跑 genUnitActions 看攻击是否生成
  final game2 = AimGame(limit: 16);
  game2.cells = [
    AimCell(8, o: 0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
    AimCell(1, o: 0), AimCell(1, o: 1), AimCell(8, o: 1),
  ];
  game2.turn = 0; game2.phase = 'action'; game2.points = 1; game2.produceLeft = 0;
  final acts = game2.getLegalActions(0);
  print('玩家1 action 阶段合法行动:');
  for (final a in acts) print('  $a');
}
