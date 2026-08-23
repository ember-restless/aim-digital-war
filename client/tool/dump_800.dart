import 'package:aim/game/rules.dart';

String cellInfo(AimCell c) {
  final o = c.o == null ? '无主' : '玩家${c.o! + 1}';
  return '{v:${c.v}, $o, bridge:${c.bridge}, onBridge:${c.onBridge}, auto:${c.auto}, id:${c.id}${c.pressedV != null ? ', pressed:${c.pressedV}/${c.pressedO}' : ''}}';
}

void main() {
  final game = AimGame(limit: 16);
  game.cells = [
    AimCell(8, o: 0),
    AimCell(0, o: null),
    AimCell(0, o: null),
    AimCell(0, o: null),
    AimCell(0, o: null),
    AimCell(5, o: 0),
    AimCell(6, o: 1),
    AimCell(8, o: 1),
  ];
  game.turn = 0;
  game.phase = null;
  game.points = 0;
  game.produceLeft = 0;
  print('初始:');
  for (var i = 0; i < game.cells.length; i++) print('  [$i] ${cellInfo(game.cells[i])}');

  game.endTurn(0, deferRoll: false); // 自动全量滚
  print('滚完 turn=${game.turn} phase=${game.phase} points=${game.points}:');
  for (var i = 0; i < game.cells.length; i++) print('  [$i] ${cellInfo(game.cells[i])}');

  // 玩家1（当前回合者）视角的合法行动里，1 可操作吗
  final acts = game.getLegalActions(game.turn);
  print('当前回合玩家${game.turn + 1}的合法行动:');
  for (final a in acts) print('  $a');
  // 玩家0 视角
  final acts0 = game.getLegalActions(0);
  print('玩家1 能否点 1：${acts.any((a) => (a['i'] == 5) || (a['j'] == 5))}');
}
