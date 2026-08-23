// 验证：选中单位后是否显示操作按键
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aim/main.dart';
import 'package:aim/net/socket.dart';
import 'package:aim/screens/game_screen.dart';

void main() {
  testWidgets('选中单位后显示操作按键', (tester) async {
    // 未连接的 AIMSocket：emit 安全（_socket 为 null）
    final fake = AIMSocket('http://127.0.0.1:1');
    final state = {
      'cells': [
        {'v': 8, 'o': 0}, {'v': 2, 'o': 0}, {'v': 0, 'o': null}, {'v': 0, 'o': null},
        {'v': 0, 'o': null}, {'v': 0, 'o': null}, {'v': 1, 'o': 1}, {'v': 8, 'o': 1},
      ],
      'mapLen': 8, 'limit': 16, 'turn': 0, 'phase': null, 'points': 1, 'produceLeft': 1,
      'winner': null, 'yourIdx': 0, 'names': ['玩家1', '玩家2'], 'hotseat': true,
      'mySum': 10, 'enemySum': 9, 'myBases': 1, 'myHqs': 0,
      'legalActions': [
        {'type': 'choosePhase', 'phase': 'action'},
        {'type': 'choosePhase', 'phase': 'produce'},
        {'type': 'move', 'i': 1, 'steps': 2},   // 2轻骑能移动
        {'type': 'split', 'i': 0, 'keep': 1},   // 基地能拆
      ],
      'log': [],
    };

    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        socket: fake,
        state: state,
        packId: 'default',
        onBack: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 1000)); // 等入场动画完成（_animLock 解锁）

    // 点格1（2轻骑）选中
    debugPrint('GestureDetector 数量: ${find.byType(GestureDetector).evaluate().length}');
    final texts = () => find.byType(Text).evaluate()
        .map((e) => (e.widget as Text).data).whereType<String>().toList();
    debugPrint('点击前文本: $texts');
    // 直接调用 onTap（绕过 hit test）
    final gd = tester.widget<GestureDetector>(find.byKey(const ValueKey('cell1')));
    gd.onTap!();
    await tester.pump();
    debugPrint('点击后文本: ${texts()}');

    // 检查操作按键是否出现
    final moveBtn = find.text('移动');
    final attackBtn = find.text('攻击');
    final devourBtn = find.text('吞噬');
    final splitBtn = find.text('拆分');
    final cancelBtn = find.text('取消');
    debugPrint('=== 按键检测 ===');
    debugPrint('移动: ${moveBtn.evaluate().length} | 攻击: ${attackBtn.evaluate().length} | 吞噬: ${devourBtn.evaluate().length} | 拆分: ${splitBtn.evaluate().length} | 取消: ${cancelBtn.evaluate().length}');

    expect(moveBtn.evaluate().length, greaterThan(0), reason: '选中后应有「移动」按键');
    expect(cancelBtn.evaluate().length, greaterThan(0), reason: '应有「取消」按键');
    // 再点基地格0：应显示「拆分」按键
    final gd0 = tester.widget<GestureDetector>(find.byKey(const ValueKey('cell0')));
    gd0.onTap!();
    await tester.pump();
    debugPrint('点基地后: 拆分=${find.text('拆分').evaluate().length}');
    expect(find.text('拆分').evaluate().length, greaterThan(0), reason: '基地可拆应有「拆分」按键');
  });
}
