// 幽灵格子 fuzz v2：跟踪期望长度（含滚木阶段的预期变化），对比实际长度
// 用法：dart run tool/fuzz_ghost2.dart
import 'dart:math';
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

void main() {
  final rng = Random(12345);
  var totalSteps = 0;
  var bad = 0;

  for (var round = 0; round < 300; round++) {
    final g = AimGame(limit: 16);
    var expected = g.cells.length; // 期望长度

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
        // endTurn → 对方滚木自动滚：用 rollSteps 推导期望变化
        final before = g.cells.length;
        g.endTurn(g.turn);
        final rs = g.rollSteps ?? [];
        var delta = 0;
        for (final r in rs) {
          if (r['bridge'] == true) delta += 1; // 溢出插桥 +1
          if (r['dead'] == true && r['bridgeCollapse'] == true) delta -= 1; // 撞桥 -1
        }
        expected += delta;
        final after = g.cells.length;
        if (after != expected) {
          print('❌ 滚木后长度漂移: 期望$expected 实际$after 步数=$step 棋盘=${boardStr(g)} rollSteps=${rs.length}');
          bad++;
          if (bad > 8) break;
        }
        continue;
      }
      final a = playable[rng.nextInt(playable.length)];
      final before = g.cells.length;
      final ok = g.applyAction(g.turn, a);
      if (ok['ok'] != true) continue;
      totalSteps++;
      final type = a['type'] as String;
      // 期望长度变化
      switch (type) {
        case 'move':
          expected += (g.lastAction?['bridgeCollapse'] != null) ? -1 : 0;
          break;
        case 'attack':
          expected += (g.lastAction?['insertedAt'] != null) ? 1 : 0;
          break;
        case 'split':
          expected += (g.lastAction?['full'] == true) ? 0 : 1;
          break;
        case 'devour':
          expected += (g.lastAction?['spliced'] == true) ? -1 : 0;
          break;
        default:
          break;
      }
      final after = g.cells.length;
      if (after != expected) {
        print('❌ 长度漂移: 行动=${type} 期望$expected 实际$after 棋盘=${boardStr(g)}');
        bad++;
        if (bad > 8) break;
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
      }
    }
    if (bad > 8) break;
  }
  print('共 $totalSteps 步行动，$bad 处长度漂移');
  print(bad == 0 ? '✅ 规则层无幽灵格子' : '❌ 规则层发现幽灵格子');
}
