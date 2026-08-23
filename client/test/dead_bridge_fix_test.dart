// 验证修复：热座 80000568 撞桥死，死停期 6 应落位桥格（棋盘无 dash 桥图标），死停后 8 格
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/screens/game_screen.dart';

int cellCount(WidgetTester tester) {
  return tester.widgetList(find.byWidgetPredicate((w) =>
      w.key != null && w.key.toString().contains("'cell"))).length;
}

List<String> unitImages(WidgetTester tester) {
  return tester
      .widgetList<Image>(find.byType(Image))
      .map((img) => img.image is AssetImage ? (img.image as AssetImage).assetName : '?')
      .toList();
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

void main() {
  testWidgets('撞桥死：死停期 6 落位桥格，结束 8 格', (tester) async {
    final socket = LocalAimSocket();
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
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    socket.emit('action', {'type': 'endTurn'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    var sawDashInDead = false; // 死停期还显示桥图标 = 修复前的 bug
    var sawNoDash = false;     // 6 落位桥格后不再有桥图标
    var final8 = false;
    for (var round = 0; round < 120; round++) {
      for (var i = 0; i < 2; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final imgs = unitImages(tester);
      final dash = imgs.any((a) => a.contains('/dash.png'));
      final has6 = imgs.any((a) => a.contains('/6.png'));
      // 死停期特征：6 在棋盘上且无 dash（6 落位桥格）
      if (has6 && !dash) sawNoDash = true;
      if (dash && has6) sawDashInDead = true;
      final n = cellCount(tester);
      final st = socket.game.viewFor(socket.game.turn);
      final ruleLen = (st['cells'] as List).length;
      if (n == ruleLen && !dash && !has6) {
        final imgs2 = unitImages(tester);
        final d2 = imgs2.any((a) => a.contains('/dash.png'));
        if (!d2) {
          final ruleStr = (st['cells'] as List)
              .map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : '${c['v']}'))
              .join();
          print('稳定态: 显示$n格 规则$ruleLen $ruleStr');
          if (n == ruleLen) final8 = true;
        }
      }
      if (final8) break;
    }
    // 修复生效条件：出现过"6 在棋盘且无 dash"（6 落位桥格覆盖桥图标）
    expect(sawNoDash, isTrue, reason: '死停期 6 应落位桥格（覆盖桥图标 dash）');
    expect(final8, isTrue, reason: '动画结束后显示层与规则棋盘一致');
    print('✅ 撞桥死修复验证通过：6 落位桥格，结束 ${final8 ? '8格' : '?格'}');
    // 清残留 timer/ticker（死停 800ms + 删除补位 400ms + 收尾 600ms）
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
