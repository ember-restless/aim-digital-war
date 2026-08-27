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
    expect(ai.outSlots, 97);

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

  test('左右镜像局面决策对称（视角归一化）', () async {
    final wf = File('/root/aim/covers/train_weights_preview.json');
    if (!wf.existsSync()) return; // 无权重跳过
    final j = jsonDecode(wf.readAsStringSync()) as Map<String, dynamic>;
    final ai = TrainAi(explore: false);
    ai.loadFromJson(j);
    expect(ai.hasModel, true);

    // 局面 A：AI 在左（turn=0），我方 5 号在 1，敌方 3 号在 5
    final ga = AimGame(limit: 16);
    ga.cells[0] = AimCell(0);
    ga.cells[1] = AimCell(5, o: 0);
    ga.cells[5] = AimCell(3, o: 1);
    ga.cells[7] = AimCell(0);
    ga.turn = 0;
    ga.phase = 'action';
    ga.points = 3;
    final a1 = ai.decide(ga);
    expect(a1, isNotNull);

    // 局面 B：AI 在右（turn=1），棋盘是 A 的镜像（B[i] = A[7-i] 且双方互换）
    final gb = AimGame(limit: 16);
    gb.cells[0] = AimCell(0);
    gb.cells[2] = AimCell(3, o: 0); // 敌方 3 号（A[5] 镜像）
    gb.cells[6] = AimCell(5, o: 1); // 我方 5 号（A[1] 镜像）
    gb.cells[7] = AimCell(0);
    gb.turn = 1;
    gb.phase = 'action';
    gb.points = 3;
    final a2 = ai.decide(gb);
    expect(a2, isNotNull);

    // 同一「我方视角」下的决策应镜像一致：类型相同、格子索引互为镜像
    expect(a1!['type'], a2!['type'], reason: '类型应一致: $a1 vs $a2');
    if (a1['type'] == 'move' || a1['type'] == 'attack' || a1['type'] == 'devour' ||
        a1['type'] == 'split' || a1['type'] == 'produce') {
      expect((a1['i'] as int) + (a2['i'] as int), 7, reason: '格子索引应镜像: $a1 vs $a2');
    }
  });
}
