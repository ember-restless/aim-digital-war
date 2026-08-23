import 'package:aim/game/rules.dart';

void main() {
  final game = AimGame(limit: 16);
  game.cells = [
    AimCell(8, o: 0), AimCell(0), AimCell(0), AimCell(0), AimCell(0),
    AimCell(5, o: 0), AimCell(6, o: 1), AimCell(8, o: 1),
  ];
  game.turn = 0; game.phase = null; game.points = 0; game.produceLeft = 0;

  game.endTurn(0, deferRoll: false); // 玩家1过回合 → 玩家2滚木滚
  print('滚完 turn=${game.turn + 1} 回合, 棋盘=${game.cells.map((c) => c.bridge ? "-" : "${c.v}${c.o == null ? '_' : 'p${c.o! + 1}'}").join(" ")}');

  // 玩家2 选行动阶段（点数=0+1=1，玩家2没有9 → points=1）
  game.applyAction(1, {'type': 'choosePhase', 'phase': 'action'});
  print('玩家2 选行动: points=${game.points}');
  // 玩家2 没有可行动单位（只有8基地），直接 endTurn
  game.applyAction(1, {'type': 'endTurn'});
  print('玩家2 endTurn → turn=${game.turn + 1}');

  // 玩家1 回合：1@5 可操作吗？
  game.applyAction(0, {'type': 'choosePhase', 'phase': 'action'});
  print('玩家1 选行动: points=${game.points}');
  final acts = game.getLegalActions(0);
  final oneActs = acts.where((a) => (a['i'] == 5) || (a['j'] == 5)).toList();
  print('玩家1 回合 1@5 的合法行动: ${oneActs}');
  print('1@5 o=${game.cells[5].o} auto=${game.cells[5].auto} onBridge=${game.cells[5].onBridge}');
}
