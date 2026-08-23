// 章节切换：退场/入场动画验证（真实推进对话）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/screens/tutorial_screen.dart';
import 'package:aim/tutorial/board_anim.dart';

void main() {
  testWidgets('第一章首屏：board 触发 → 退场 → 入场', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TutorialScreen(onExit: () {}, startChapter: 0),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // 推进对话直到 board 指令触发（首屏棋盘出现）
    for (int i = 0; i < 15 && find.text('（战场还未展开）').evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 400)); // 打字
      final coffee = find.text('咖啡');
      if (coffee.evaluate().isNotEmpty) {
        await tester.tap(coffee);
      } else {
        final next = find.text('▼ 点击继续');
        if (next.evaluate().isNotEmpty) {
          await tester.tap(next);
        } else {
          await tester.tapAt(const Offset(200, 500));
        }
      }
      await tester.pump(const Duration(milliseconds: 200));
    }

    // board 触发瞬间：退场阶段（首屏 cells 空，无格子可退）→ 入场阶段 BoardEnterCell
    // 循环退出后 board 刚触发，_playBoardTransition 开始：退场 1000ms → 入场 1000ms
    await tester.pump(const Duration(milliseconds: 300)); // 进入动画
    debugPrint('A exit=${find.byType(BoardExitCell).evaluate().length} enter=${find.byType(BoardEnterCell).evaluate().length} empty=${find.text('（战场还未展开）').evaluate().length}');
    // 再等，直到入场动画出现（applyPendingBoard 在退场 1000ms 后执行）
    var sawEnter = false;
    for (int i = 0; i < 12 && !sawEnter; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(BoardEnterCell).evaluate().isNotEmpty) sawEnter = true;
    }
    debugPrint('B sawEnter=$sawEnter exit=${find.byType(BoardExitCell).evaluate().length} enter=${find.byType(BoardEnterCell).evaluate().length}');
    expect(sawEnter, isTrue, reason: '新棋盘入场应有 BoardEnterCell 展开动画');

    // 等入场播完，棋盘正常显示
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('（战场还未展开）').evaluate().isEmpty, isTrue, reason: '棋盘应已展开');
    expect(tester.takeException(), isNull);
  });
}
