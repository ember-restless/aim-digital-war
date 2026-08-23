// 滚木阶段：打印 endTurn 前后棋盘，找长度变化来源
import 'dart:math';
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

void main() {
  final rng = Random(999);
  var bad = 0;
  for (var round = 0; round < 400 && bad < 3; round++) {
    final g = AimGame(limit: 16);
    for (var step = 0; step < 300; step++) {
      if (g.winner != null) break;
      if (g.phase == null) {
        final acts = g.getLegalActions(g.turn);
        final cp = acts.where((a) => a['type'] == 'choosePhase').toList();
        if (cp.isNotEmpty) g.applyAction(g.turn, cp[rng.nextInt(cp.length)]);
        continue;
      }
      final acts = g.getLegalActions(g.turn);
      final playable = acts.where((a) => a['type'] != 'endTurn' && a['type'] != 'choosePhase').toList();
      if (step % 15 == 14 || playable.isEmpty) {
        final before = boardStr(g);
        final beforeLen = g.cells.length;
        g.endTurn(g.turn);
        final rs = List<Map<String, dynamic>>.from(g.rollSteps ?? []);
        var delta = 0;
        for (final r in rs) {
          if (r['bridge'] == true) delta += 1;
          if (r['dead'] == true && r['bridgeCollapse'] == true) delta -= 1;
        }
        final after = boardStr(g);
        final afterLen = g.cells.length;
        if (afterLen - beforeLen != delta) {
          print('❌ 滚木不一致: 实际${afterLen - beforeLen} 预期$delta');
          print('  前($beforeLen): $before');
          print('  后($afterLen): $after');
          print('  rollSteps=$rs');
          bad++;
          break;
        }
        continue;
      }
      g.points = 5; g.produceLeft = 5;
      g.applyAction(g.turn, playable[rng.nextInt(playable.length)]);
    }
  }
  print(bad == 0 ? '✅ 滚木无长度 bug' : '❌ $bad 处不一致');
}
