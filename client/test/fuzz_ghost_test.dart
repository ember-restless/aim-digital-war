// fuzz：随机操作多回合，每步动画播完后检查 渲染格数 vs 规则格数，
// 找"渲染多一格且持续"（幽灵格子）的操作序列
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/screens/game_screen.dart';

int cellCount(WidgetTester tester) {
  return tester.widgetList(find.byWidgetPredicate((w) =>
      w.key != null && w.key.toString().contains("'cell"))).length;
}

class HotseatHarness extends StatefulWidget {
  final LocalAimSocket socket;
  const HotseatHarness({super.key, required this.socket});
  @override
  State<HotseatHarness> createState() => _HotseatHarnessState();
}

class _HotseatHarnessState extends State<HotseatHarness> {
  Map<String, dynamic>? gameState;
  @override
  void initState() {
    super.initState();
    widget.socket.onEvent = (event, data) {
      if (event == 'game_state') {
        setState(() => gameState = data as Map<String, dynamic>);
      }
    };
  }
  @override
  Widget build(BuildContext context) {
    final st = gameState ?? widget.socket.game.viewFor(0);
    return MaterialApp(
      home: GameScreen(
        socket: widget.socket,
        state: st,
        packId: 'default',
        onBack: () {},
      ),
    );
  }
}

String ruleStr(LocalAimSocket s) {
  final v = s.game.viewFor(s.game.turn);
  return (v['cells'] as List)
      .map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : '${c['v']}'))
      .join();
}

void main() {
  testWidgets('fuzz：渲染层与规则层一致', (tester) async {
    final rand = Random(20260820);
    final socket = LocalAimSocket();
    final game = socket.game;
    // 从牢大场景变体开局（多几个单位，模拟"打出来"的过程）
    game.cells = [
      AimCell(8, o: 0),
      AimCell(0, o: null),
      AimCell(1, o: 0),
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

    await tester.pumpWidget(HotseatHarness(socket: socket));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    var mismatches = 0;
    for (var step = 0; step < 60; step++) {
      // 随机选一个合法操作执行
      final turn = game.turn;
      final acts = game.getLegalActions(turn);
      final playable = acts
          .where((a) => a['type'] != 'endTurn' && a['type'] != 'choosePhase')
          .toList();
      Map<String, dynamic>? act;
      if (playable.isNotEmpty && rand.nextDouble() < 0.8) {
        act = playable[rand.nextInt(playable.length)];
      } else {
        act = {'type': 'endTurn'};
      }
      socket.emit('action', act);
      await tester.pump();
      // 推进动画：滑动/停顿/删除/补位/收尾
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 再等动画收尾（cleanup 延迟）
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final ruleLen = (game.viewFor(game.turn)['cells'] as List).length;
      final shown = cellCount(tester);
      if (shown != ruleLen) {
        mismatches++;
        print('❌ 步$step: 操作=$act 规则[$ruleLen]=${ruleStr(socket)} 渲染$shown格');
        if (mismatches > 5) break;
      }
      if (game.winner != null) {
        print('游戏结束（第$step步）');
        break;
      }
      if (shown != ruleLen) break;
    }
    expect(mismatches, 0, reason: '渲染层与规则层应始终一致');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    print('fuzz 结束: 最终规则=${ruleStr(socket)} 渲染${cellCount(tester)}格');
  });
}
