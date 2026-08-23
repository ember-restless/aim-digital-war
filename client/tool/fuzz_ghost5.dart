// 单步长度对比 v2：行动后重置 points 防自动滚木干扰；滚木阶段用 rollSteps 推导对比
import 'dart:math';
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

int expectDelta(Map<String, dynamic>? la) {
  if (la == null) return 0;
  switch (la['type']) {
    case 'move': return la['bridgeCollapse'] != null ? -1 : 0;
    case 'attack': return la['insertedAt'] != null ? 1 : 0;
    case 'split': return la['full'] == true ? 0 : 1;
    case 'devour': return la['spliced'] == true ? -1 : 0;
    default: return 0;
  }
}

void main() {
  final rng = Random(777);
  var bad = 0, checked = 0, rollChecked = 0;

  for (var round = 0; round < 300 && bad < 5; round++) {
    final g = AimGame(limit: 16);
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
        // 显式过回合 → 滚木阶段：rollSteps 推导
        final before = g.cells.length;
        g.endTurn(g.turn);
        final rs = g.rollSteps ?? [];
        var delta = 0;
        for (final r in rs) {
          if (r['bridge'] == true) delta += 1;
          if (r['dead'] == true && r['bridgeCollapse'] == true) delta -= 1;
        }
        final after = g.cells.length;
        rollChecked++;
        if (after - before != delta) {
          print('❌ 滚木不一致: 实际delta=${after - before} 预期$delta');
          print('  rollSteps=$rs');
          print('  棋盘=${boardStr(g)}');
          bad++;
          break;
        }
        continue;
      }
      final a = playable[rng.nextInt(playable.length)];
      g.points = 5; g.produceLeft = 5; // 行动前保证点数充足，防止 maybeAutoEnd 自动过回合干扰对比
      final before = g.cells.length;
      final ok = g.applyAction(g.turn, a);
      if (ok['ok'] != true) continue;
      final after = g.cells.length;
      final la = g.lastAction;
      final d = expectDelta(la);
      checked++;
      if (after - before != d) {
        print('❌ 单步不一致: 行动=${a['type']} 实际delta=${after - before} 预期$d');
        print('  lastAction=$la');
        print('  棋盘=${boardStr(g)}');
        bad++;
        break;
      }
      g.points = 5; // 防止 maybeAutoEnd 自动过回合干扰
    }
  }
  print('行动 $checked 步、滚木 $rollChecked 轮，$bad 处不一致');
  print(bad == 0 ? '✅ 规则层无长度 bug' : '❌ 规则层长度有 bug');
}
