// 返回流程测试：game_over → 返回按钮 → 菜单
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/net/socket.dart';
import 'package:aim/screens/game_screen.dart';
import 'package:aim/screens/menu_screen.dart';
import 'package:aim/art/art_manager.dart';
void main() {
  testWidgets('对局结束返回按钮触发 onBack', (tester) async {
    var backed = false;
    final state = {
      'cells': [
        {'v': 8, 'o': 0}, {'v': 0, 'o': null}, {'v': 0, 'o': null}, {'v': 0, 'o': null},
        {'v': 0, 'o': null}, {'v': 0, 'o': null}, {'v': 0, 'o': null}, {'v': 8, 'o': 1},
      ],
      'mapLen': 8, 'limit': 16, 'turn': 0, 'phase': null, 'points': 1, 'produceLeft': 1,
      'winner': 0, 'yourIdx': 0, 'names': ['玩家1', '玩家2'], 'hotseat': true,
      'mySum': 8, 'enemySum': 0, 'myBases': 1, 'myHqs': 0,
      'legalActions': [], 'log': [],
    };
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        socket: AIMSocket('http://127.0.0.1:1'),
        state: state,
        packId: 'default',
        over: {'winner': 0, 'winnerName': '玩家1'},
        onBack: () => backed = true,
      ),
    ));
    await tester.pump();

    // 热座胜利文字（现在是「左胜」/「右胜」）
    final winText = find.textContaining('胜');
    debugPrint('热座胜利文案: ${winText.evaluate().length}');
    expect(winText.evaluate().length, greaterThan(0), reason: '热座应显示「左胜/右胜」');

    // 点返回大厅
    final backBtn = find.text('返回大厅');
    expect(backBtn.evaluate().length, greaterThan(0), reason: '应有返回大厅按钮');
    await tester.tap(backBtn.first);
    await tester.pump();
    expect(backed, isTrue, reason: '点返回应触发 onBack');
  });

  testWidgets('MenuScreen 正常渲染', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MenuScreen(
        packId: 'default',
        packs: const [],
        onPackChange: (_) {},
      ),
    ));
    await tester.pump();
    debugPrint('菜单标题: ${find.text('AIM').evaluate().length}');
    expect(find.text('AIM').evaluate().length, greaterThan(0), reason: '菜单应显示 AIM');
    expect(find.text('联机大厅').evaluate().length, greaterThan(0), reason: '菜单应有联机大厅入口');
    expect(find.text('局域网').evaluate().length, greaterThan(0), reason: '菜单应有局域网入口');
    expect(find.text('热座').evaluate().length, greaterThan(0), reason: '菜单应有热座入口');
    expect(tester.takeException(), isNull, reason: '菜单渲染不应抛异常');
  });
}
