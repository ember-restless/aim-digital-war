// 精确复现牢大序列最后两步：80050068 → 玩家1 移动5(3→5 走2格) → 点数用光自动过回合
// → 6 滚木（autoRoll 全量）→ 移动动画+滚木同帧 → _deferredRoll + _detectRoll 路径
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/net/local_socket.dart';
import 'package:aim/screens/game_screen.dart';

String imgStr(WidgetTester tester) {
  return tester
      .widgetList<Image>(find.byType(Image))
      .map((img) => img.image is AssetImage ? (img.image as AssetImage).assetName.split('/').last.replaceAll('.png', '') : '?')
      .toList()
      .join(' ');
}

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

void main() {
  testWidgets('移动5(2步)+自动过回合+滚木：逐帧渲染追踪', (tester) async {
    final socket = LocalAimSocket();
    // 牢大序列第12步后：80050068 = 8,0,0,5,0,0,6,8
    socket.game.cells = [
      AimCell(8, o: 0),
      AimCell(0),
      AimCell(0),
      AimCell(5, o: 0),
      AimCell(0),
      AimCell(0),
      AimCell(6, o: 1, auto: true), // 玩家2 造兵升出的滚木
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

    print('=== 玩家1 移动5（3→5）→ 自动过回合 → 6 滚 ===');
    socket.emit('action', {'type': 'move', 'i': 3, 'steps': 2});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    var lastPrint = '';
    for (var t = 0; t < 400; t++) {
      await tester.pump(const Duration(milliseconds: 100));
      final st = socket.game.viewFor(socket.game.turn);
      final ruleLen = (st['cells'] as List).length;
      final rule = (st['cells'] as List)
          .map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : '${c['v']}'))
          .join('');
      final sig = 't=${(t + 1) * 100}ms 规则[$ruleLen]=$rule | 格数=${cellCount(tester)} | 图=${imgStr(tester)}';
      if (sig != lastPrint) {
        lastPrint = sig;
        print(sig);
      }
      // 稳定后停
      if (t > 250 && ruleLen == 8 && cellCount(tester) == 8) break;
    }
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final st = socket.game.viewFor(socket.game.turn);
    final ruleLen = (st['cells'] as List).length;
    final shown = cellCount(tester);
    print('最终: 规则$ruleLen格=${(st['cells'] as List).map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : '${c['v']}')).join('')} 渲染$shown格 图=${imgStr(tester)}');
    expect(shown, ruleLen, reason: '最终渲染格数应与规则一致');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  });
}
