// 幽灵格子模糊测试：随机行动序列，监控棋盘长度漂移和异常空格
// 用法：dart run tool/fuzz_ghost_cell.dart
import 'dart:math';
import '../lib/game/rules.dart';

String boardStr(AimGame g) =>
    g.cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : '${c.v}${c.o == 0 ? 'a' : 'b'}')).join(' ');

void main() {
  final rng = Random(42);
  var totalSteps = 0;
  var badSteps = 0;

  for (var round = 0; round < 200; round++) {
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
      if (playable.isEmpty) {
        g.endTurn(g.turn);
        continue;
      }
      final a = playable[rng.nextInt(playable.length)];
      final before = g.cells.length;
      final ok = g.applyAction(g.turn, a);
      final after = g.cells.length;
      if (ok['ok'] != true) continue;
      totalSteps++;

      final delta = after - before;
      if (delta.abs() > 2) {
        print('⚠️ 长度异常: 行动=${a['type']} 变化=$delta 棋盘=${boardStr(g)}');
        badSteps++;
        break;
      }
      if (delta > 0) {
        final last = g.cells.last;
        if (last.v == 0 && !last.bridge) {
          print('❌ 幽灵空格(末尾): 行动=${a['type']} 棋盘=${boardStr(g)}');
          badSteps++;
          break;
        }
      }
      // 全场扫描：普通空格是否出现在"不该有"的位置（两基地之间任意位置其实都正常，只查长度）
      if (g.cells.length > 16) {
        print('❌ 超限: ${g.cells.length} 格 行动=${a['type']} 棋盘=${boardStr(g)}');
        badSteps++;
        break;
      }
      if (g.points <= 0 && g.phase == 'action') {
        g.endTurn(g.turn);
      }
    }
    if (badSteps > 5) break;
  }
  print('共执行 $totalSteps 步，异常 $badSteps 处');
  print(badSteps == 0 ? '✅ 无幽灵格子' : '❌ 发现幽灵格子');
}
