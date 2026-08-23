import 'dart:math';
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

void main() {
  final rng = Random(12345);
  var bad = 0;

  for (var round = 0; round < 300 && bad < 3; round++) {
    final g = AimGame(limit: 16);
    var expected = g.cells.length;
    for (var step = 0; step < 400; step++) {
      if (g.winner != null) break;
      if (g.phase == null) {
        final acts = g.getLegalActions(g.turn);
        final cp = acts.where((a) => a['type'] == 'choosePhase').toList();
        if (cp.isNotEmpty) g.applyAction(g.turn, cp[rng.nextInt(cp.length)]);
        continue;
      }
      final acts = g.getLegalActions(g.turn);
      final playable = acts.where((a) => a['type'] != 'endTurn' && a['type'] != 'choosePhase').toList();
      if (playable.isEmpty) {
        final before = g.cells.length;
        g.endTurn(g.turn);
        final rs = g.rollSteps ?? [];
        var delta = 0;
        for (final r in rs) {
          if (r['bridge'] == true) delta += 1;
          if (r['dead'] == true && r['bridgeCollapse'] == true) delta -= 1;
        }
        expected += delta;
        if (g.cells.length != expected) {
          print('❌ 滚木漂移: 期望$expected 实际${g.cells.length} 棋盘=${boardStr(g)}');
          print('  rollSteps=$rs');
          bad++;
          break;
        }
        continue;
      }
      final a = playable[rng.nextInt(playable.length)];
      final ok = g.applyAction(g.turn, a);
      if (ok['ok'] != true) continue;
      final type = a['type'] as String;
      final la = g.lastAction;
      switch (type) {
        case 'move': expected += (la?['bridgeCollapse'] != null) ? -1 : 0; break;
        case 'attack': expected += (la?['insertedAt'] != null) ? 1 : 0; break;
        case 'split': expected += (la?['full'] == true) ? 0 : 1; break;
        case 'devour': expected += (la?['spliced'] == true) ? -1 : 0; break;
        default: break;
      }
      if (g.cells.length != expected) {
        print('❌ 漂移: 行动=$type 期望$expected 实际${g.cells.length} 棋盘=${boardStr(g)}');
        print('  lastAction=$la');
        bad++;
        break;
      }
      if (g.points <= 0 && g.phase == 'action') {
        g.endTurn(g.turn);
        final rs = g.rollSteps ?? [];
        var delta = 0;
        for (final r in rs) {
          if (r['bridge'] == true) delta += 1;
          if (r['dead'] == true && r['bridgeCollapse'] == true) delta -= 1;
        }
        expected += delta;
        if (g.cells.length != expected) {
          print('❌ 滚木漂移2: 期望$expected 实际${g.cells.length} 棋盘=${boardStr(g)}');
          bad++;
          break;
        }
      }
    }
  }
  print(bad == 0 ? '✅ 规则层无幽灵格子' : '❌ 规则层发现幽灵格子');
}
