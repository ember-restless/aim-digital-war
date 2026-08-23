import 'package:aim/game/rules.dart';

void main() {
  final game = AimGame(limit: 16);
  game.cells = [
    AimCell(8, o: 0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
    AimCell(5, o: 0), AimCell(6, o: 1), AimCell(8, o: 1),
  ];
  game.turn = 0; game.phase = null; game.points = 0; game.produceLeft = 0;

  game.endTurn(0, deferRoll: false);
  print('滚完 turn=${game.turn + 1}: ${game.cells.map((c) => c.bridge ? "-" : "${c.v}${c.o == null ? '_' : 'p${c.o! + 1}'}").join(" ")}');

  // 玩家2 选行动 → 拆分 8@7 (keep=4) 消耗1点 → 自动过回合
  game.applyAction(1, {'type': 'choosePhase', 'phase': 'action'});
  final r = game.applyAction(1, {'type': 'split', 'i': 7, 'keep': 4});
  print('玩家2 拆分8: ok=${r['ok']} ${r['reason'] ?? ''} turn=${game.turn + 1}');
  print('棋盘: ${game.cells.map((c) => c.bridge ? "-" : "${c.v}${c.o == null ? '_' : 'p${c.o! + 1}'}").join(" ")}');

  // 现在轮到玩家1（若已自动过回合）
  if (game.turn == 0) {
    game.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
    final acts = game.getLegalActions(0);
    final oneActs = acts.where((a) => (a['i'] == 5) || (a['j'] == 5)).toList();
    print('玩家1 回合 1@5 的合法行动: $oneActs');
    final c5 = game.cells[5];
    print('1@5: o=${c5.o} auto=${c5.auto} onBridge=${c5.onBridge}');
  } else {
    print('还没轮到玩家1，当前 turn=${game.turn + 1}');
    // 玩家2 继续走完
    game.applyAction(1, {'type': 'endTurn'});
    print('玩家2 手动 endTurn: turn=${game.turn + 1}');
    game.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
    final acts = game.getLegalActions(0);
    final oneActs = acts.where((a) => (a['i'] == 5) || (a['j'] == 5)).toList();
    print('玩家1 回合 1@5 的合法行动: $oneActs');
  }
}
