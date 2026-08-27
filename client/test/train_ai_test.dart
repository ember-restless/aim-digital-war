// TrainAi 加载权重 + 决策测试：验证权重格式与规则引擎兼容
// 跑法：cd /root/aim/client && timeout 120 /opt/flutter/bin/flutter test --no-version-check test/train_ai_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aim/game/rules.dart';
import 'package:aim/train/train_ai.dart';

void main() {
  test('加载训练权重并决策（返回合法动作）', () async {
    final wf = File('/root/aim/covers/train_weights_preview.json');
    if (!wf.existsSync()) {
      // 权重不存在就跳过（CI/无训练数据环境）
      return;
    }
    final j = jsonDecode(wf.readAsStringSync()) as Map<String, dynamic>;
    final ai = TrainAi();
    ai.loadFromJson(j);
    expect(ai.hasModel, true);
    expect(ai.outSlots, 49);

    // 开局局面：AI（玩家1）决策
    final g = AimGame(limit: 16);
    g.turn = 1;
    g.phase = 'action';
    g.points = 1;
    final a = ai.decide(g);
    expect(a, isNotNull);
    final acts = g.getLegalActions(1);
    expect(acts.any((x) => x['type'] == a!['type'] && x['i'] == a['i']), true,
        reason: 'AI 应返回合法动作，实际 $a');
  });

  test('无权重时回退启发式 AI', () {
    final ai = TrainAi();
    expect(ai.hasModel, false);
    final g = AimGame(limit: 16);
    g.turn = 1;
    g.phase = 'action';
    g.points = 1;
    final a = ai.decide(g);
    expect(a, isNotNull);
  });
}
