// 热座 80000568 滚木撞桥：widget 级验证显示层格子数与规则棋盘一致（幽灵格子检测）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/screens/game_screen.dart';

int cellCount(WidgetTester tester) {
  return tester.widgetList(find.byWidgetPredicate((w) =>
      w.key != null && w.key.toString().contains("'cell"))).length;
}

// 模拟 hotseat_screen：onEvent 里 setState 更新 state，GameScreen 保持同一 widget 树
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
        // GameScreen 的 roll_step 请求已延迟到帧后，此处 setState 不再处于 build 阶段
        setState(() => gameState = data as Map<String, dynamic>);
      }
    };
  }
  @override
  Widget build(BuildContext context) {
    final st = gameState ?? widget.socket.game.viewFor(0);
    debugPrint('HARNESS build: rollPending=${st['rollPending']} rollStepSeq=${st['rollStepSeq']} rollActs=${st['rollActs']} cellsLen=${(st['cells'] as List).length}');
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

void main() {
  testWidgets('80000568 滚木撞桥：显示层无幽灵格子', (tester) async {
    final socket = LocalAimSocket();
    // 80000568：玩家1 滚木6@6（往左滚，压5溢出插桥，再撞桥死）
    socket.game.cells = [
      AimCell(8, o: 0),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(0, o: null),
      AimCell(5, o: 0),
      AimCell(6, o: 1),
      AimCell(8, o: 1),
    ];
    socket.game.turn = 0;
    socket.game.phase = null;
    socket.game.points = 0;
    socket.game.produceLeft = 0;

    await tester.pumpWidget(HotseatHarness(socket: socket));
    await tester.pump(const Duration(milliseconds: 1000));

    // 玩家0 结束回合 → 玩家1 滚木待滚（GameScreen 自动驱动）
    socket.emit('action', {'type': 'endTurn'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 让 GameScreen 全自动驱动（onDone 自动请求 roll_step），逐步检查显示 vs 规则
    var mismatches = 0;
    var lastShown = -1;
    var quiet = 0;
    for (var round = 0; round < 80; round++) {
      // 推进动画（滑动/停顿/删除/onDone 间隔）
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final st = socket.game.viewFor(socket.game.turn);
      final ruleLen = (st['cells'] as List).length;
      final shown = cellCount(tester);
      // 检查 GameScreen 内部动画状态
      String animState = '?';
      try {
        final gs = tester.state<State<GameScreen>>(find.byType(GameScreen));
        final dyn = gs as dynamic;
        animState = 'animCells=${dyn._animCells?.length} lock=${dyn._animLock} mv=${dyn._mv != null} paused=${dyn._rollPaused} ctrl=${dyn._stepCtrl?.isAnimating}';
      } catch (e) {
        animState = 'ERR: $e';
      }
      final board = (st['cells'] as List)
          .map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : '${c['v']}'))
          .join(' ');
      print('轮=$round 规则($ruleLen): $board | 显示$shown格 | rollPending=${st['rollPending']}');
      if (shown == lastShown && st['rollPending'] != true) quiet++;
      if (quiet >= 2 && st['rollPending'] != true) break;
      lastShown = shown;
    }
    // 最终检查（等所有动画结束）
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final st = socket.game.viewFor(socket.game.turn);
    final finalShown = cellCount(tester);
    final finalRule = (st['cells'] as List).length;
    print('滚完: 显示$finalShown格 vs 规则$finalRule格');
    expect(finalShown, finalRule, reason: '滚完显示层无幽灵格子');
    print('✅ 80000568 滚木流程显示层无幽灵格子');
  });
}
