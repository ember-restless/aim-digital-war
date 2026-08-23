// 背景数字气泡：渲染 + 游动/转向/自转 + 指针避开（外部 ValueNotifier 传指针）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim/widgets/bubble_digits.dart';

void main() {
  testWidgets('气泡背景：游动转向自转 + 指针靠近避开，无异常', (tester) async {
    final pointer = ValueNotifier<Offset?>(null);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: BubbleDigits(count: 8, pointer: pointer),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets, reason: '气泡画布存在');

    // 游动/转向/自转几帧（ticker 持续驱动）
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '第$i帧游动无异常');
    }

    // 模拟手指/鼠标靠近（外部指针更新 → 触发躲避逻辑）
    pointer.value = const Offset(100, 100);
    await tester.pump(const Duration(milliseconds: 120));
    pointer.value = const Offset(110, 110);
    await tester.pump(const Duration(milliseconds: 300));
    pointer.value = const Offset(200, 200);
    await tester.pump(const Duration(milliseconds: 300));
    pointer.value = null;
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull, reason: '指针避开无异常');

    pointer.dispose();
  });
}
