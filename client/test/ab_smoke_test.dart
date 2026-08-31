// Dart 版 αβ 冒烟测试：vs 规则 AI（hard/normal）验证移植正确性
// 运行: cd client && dart run test/ab_smoke_test.dart
import 'package:aim/game/alphabeta_ai.dart';
import 'package:aim/game/ai.dart';
import 'package:aim/game/rules.dart';

int playOne(AlphaBetaAi ai, AimAi rule, int side, int i) {
  final g = AimGame(limit: 16);
  var guard = 0;
  while (g.winner == null && guard < 400) {
    guard++;
    final owner = g.turn;
    Map<String, dynamic>? a;
    if (owner == side) {
      a = ai.decide(g);
    } else {
      a = rule.decide(g);
    }
    if (a == null) break;
    if (!abApplyAndRoll(g, owner, a)) {
      final (acts, mustEnd) = abCandidates(g);
      if (acts.isEmpty) break;
      if (!abApplyAndRoll(g, owner, acts.first)) break;
    }
  }
  return g.winner ?? -1;
}

void main() {
  for (final opp in [AiLevel.hard, AiLevel.normal]) {
    var wins = 0;
    final sw = Stopwatch()..start();
    for (var i = 0; i < 4; i++) {
      final ai = AlphaBetaAi(depth: 5, timeBudgetMs: 1500);
      final rule = AimAi(opp, seed: i * 13 + 37);
      final w = playOne(ai, rule, 0, i);
      if (w == 0) wins++;
      print('  vs ${opp.name} game=$i ${w == 0 ? "W" : "L"} (${ai.nodes} nodes, ${ai.lastThinkMs.toStringAsFixed(0)}ms)');
    }
    print('== Dart αβ vs ${opp.name}: $wins/4 耗时 ${sw.elapsed.inSeconds}s ==');
  }
}
