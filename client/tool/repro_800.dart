// 重现 80000568 滚木流程：驱动本地热座引擎，打印每步棋盘 + rollActs
// 用法: cd /root/aim/client && /opt/flutter/bin/dart run ../tools/repro_800.dart
import 'package:aim/game/rules.dart';

String line(List cells) => cells
    .map((c) {
      final m = (c as AimCell);
      if (m.bridge) return '-';
      return m.o == null ? '0' : '${m.v}';
    })
    .join('');

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

  print('初始: ${line(game.cells)}');
  final res = game.applyAction(0, {'type': 'endTurn'}, deferRoll: true);
  print('endTurn ok=${res['ok']} rollPending=${game.hasPendingRoll}');
  print('回合后(未滚): ${line(game.cells)}');

  var guard = 0;
  while (guard++ < 20) {
    final acts = game.rollStepOnce(game.turn);
    final v = game.viewFor(game.turn);
    print('step$guard acts=${acts == null ? 'null(结束)' : acts}');
    print('       棋盘: ${line(game.cells)} len=${game.cells.length}');
    if (acts == null) break;
  }
  print('最终: ${line(game.cells)}');
  print('rollSteps=${game.rollSteps}');
}
