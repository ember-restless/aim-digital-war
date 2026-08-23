// 教程动画回归测试：board diff / auto 攻击白闪 / 移动浮层
// 覆盖 2026-08-15 牢大反馈：教程动画与对战不一致（无移动/插入/删除/转变动画）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/screens/tutorial_screen.dart';
import 'package:aim/tutorial/tutorial_engine.dart';
import 'package:aim/widgets/hit_fx.dart';

void main() {
  test('board diff：同位置变化标记 changed，长度变化标记 inserted/removed', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['0', '0', '0', '0', '0', '0', '0', '0']},
      {'end': true},
    ]);
    engine.applyPendingBoard(); // 应用首屏
    expect(engine.boardDiff, isNull, reason: '首屏 board 不产生 diff（展开动画覆盖）');

    // 章节内 board：兵营出现（同位置 0→8）
    engine.applyBoard(['8', '0', '0', '0', '0', '0', '0', '0']);
    var diff = engine.boardDiff!;
    expect((diff['changed'] as List).length, 1);
    expect((diff['changed'] as List).first['idx'], 0);
    expect((diff['changed'] as List).first['from'], 0);
    expect((diff['changed'] as List).first['to'], 8);
    expect(diff['inserted'], isEmpty);
    expect(diff['removed'], isEmpty);

    // 敌人+指挥部出现（同位置 0→1、0→1、0→9）
    engine.applyBoard(['8', '1', '0', '0', '0', '0', '1', '9']);
    diff = engine.boardDiff!;
    expect((diff['changed'] as List).length, 3);

    // 长度变化：8 → 9 格（末尾插入）
    engine.applyBoard(['8', '1', '0', '0', '0', '0', '1', '9', '2']);
    diff = engine.boardDiff!;
    expect(diff['inserted'], [8]);

    // 长度缩短：9 → 8 格（末尾删除）
    engine.applyBoard(['8', '1', '0', '0', '0', '0', '1', '9']);
    diff = engine.boardDiff!;
    expect(diff['removed'], [8]);
    expect((diff['prevCells'] as List).length, 9, reason: 'diff 带旧棋盘快照');
  });

  testWidgets('教程第一章：兵营出现触发白闪（board diff 转变）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TutorialScreen(onExit: () {}, startChapter: 0),
    ));
    // 首屏 boardPending：退场 1s + 入场 1s
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1100));

    // 点对话框推进：跳过台词/选择，直到兵营出现（第二个 board）
    var sawHit = false;
    for (int i = 0; i < 14 && !sawHit; i++) {
      await tester.pump(const Duration(milliseconds: 600)); // 打字/对话节奏
      // 有选项点选项（咖啡/茶/酒），否则点「点击继续」推进
      final choice = find.text('咖啡');
      if (choice.evaluate().isNotEmpty) {
        await tester.tap(choice);
      } else {
        final next = find.text('▼ 点击继续');
        if (next.evaluate().isNotEmpty) {
          await tester.tap(next);
        } else {
          await tester.tapAt(const Offset(200, 500)); // 兜底：对话框区域
        }
      }
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(HitFx).evaluate().isNotEmpty) sawHit = true;
    }
    expect(sawHit, isTrue, reason: '兵营/敌人出现应触发白闪转变动画');
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);
  });

  test('auto attack 后 lastAction 带 prevCells 且 insertedAt 正确（溢出插桥）', () {
    final engine = TutEngine();
    engine.load([
      {'board': ['0', '5', '{1}', '0', '0', '0', '0', '0']},
      {'end': true},
    ]);
    engine.applyPendingBoard();
    engine.runAuto({'auto': 'attack', 'i': 1, 'j': 2, 'owner': 0});
    final la = engine.lastAction!;
    expect(la['type'], 'attack');
    expect(la['insertedAt'], 2);
    expect((la['prevCells'] as List).length, 8);
    // 引擎结果：桥在格2、目标变4在格3
    expect(engine.cells[2].isB, isTrue);
    expect(engine.cells[3].v, 4);
  });
}
