// 验证新 _startTutMv（绑定模型）动画棋盘序列（rid 写入修复后）
import 'dart:math';
import '../lib/tutorial/tutorial_engine.dart';

String fmt(List<TutCell> cs) {
  final buf = StringBuffer();
  for (final c in cs) {
    if (c.isB) buf.write('-');
    else if (c.v == 0) buf.write('0');
    else if (c.o == 1) buf.write('{${c.v}}');
    else buf.write('${c.v}');
    if (c.pressedV != null && c.pressedV! > 0) buf.write('(${c.pressedV})');
  }
  return buf.toString();
}

void simRoll(TutEngine e, List<TutCell> prev, int oldIdx, int dirn, List<Map<String, dynamic>> rollSteps, int rid) {
  final v = 6, o = 0;
  final steps = rollSteps.length;
  var anim = prev.map((c) => c.copy()).toList();

  void clearCell(int k) {
    final cc = anim[k];
    if (cc.pressedV != null && cc.pressedV! > 0) {
      anim[k] = TutCell(cc.pressedV!, o: cc.pressedO);
    } else if (cc.isB || cc.onBridge) {
      anim[k] = TutCell(0, bridge: true);
    } else {
      anim[k] = TutCell(0);
    }
  }

  void placeUnit(int from) {
    for (int k = 0; k < anim.length; k++) {
      if (anim[k].id == rid) clearCell(k);
    }
    print('    [placeUnit@$from] ${fmt(anim)} (${anim.length}格)');
  }

  void applyRollStep(int s) {
    final rs = rollSteps[s - 1];
    if (rs['dead'] == true) { print('    [子步$s] dead'); return; }
    if (rs['bump'] == true || rs['crush'] != true) return;
    final arrival = oldIdx + dirn * s;
    final owner = (rs['owner'] as num?)?.toInt();
    if (rs['kill'] == true) {
      anim[arrival] = TutCell.withId(v, rid, o: o);
    } else if (rs['bridge'] == true) {
      anim[arrival] = TutCell.withId(v, rid, o: o, pressedV: (rs['newV'] as num).toInt(), pressedO: owner);
      anim.insert(arrival, TutCell(0, bridge: true));
    } else {
      anim[arrival] = TutCell.withId(v, rid, o: o, pressedV: (rs['newV'] as num).toInt(), pressedO: owner);
    }
    print('    [子步$s] $rs → ${fmt(anim)} (${anim.length}格)');
  }

  print('  ── 动画开始：旧 ${fmt(prev)} / 引擎 ${fmt(e.cells)} (${e.cells.length}格)');
  for (int step = 1; step <= steps; step++) {
    var from = oldIdx;
    for (var i = 1; i < step; i++) {
      final r = rollSteps[i - 1];
      from += (r['bump'] == true) ? 1 : dirn;
    }
    final subDirn = rollSteps[step - 1]['bump'] == true ? 1 : dirn;
    print('  [步$step] 浮层 ${from}→${from + subDirn}');
    placeUnit(from);
    applyRollStep(step);
    if (rollSteps[step - 1]['crush'] == true && rollSteps[step - 1]['kill'] != true) {
      print('    (压单位停顿 660ms，滚木绑定棋盘，浮层隐藏)');
    }
  }
  print('  ── 结束 cleanup → 引擎 ${fmt(e.cells)} (${e.cells.length}格)');
}

void main() {
  print('═══ 第七章：滚木压 2 号溢出插桥（绑定模型）═══');
  final e = TutEngine();
  e.load([
    {'board': ['6', '0', '2', '0', '0', '0', '0', '7']},
    {'end': true},
  ]);
  while (e.boardPending) { e.applyPendingBoard(); }
  final rollerId = e.cells.firstWhere((c) => c.v == 6 && c.isUnit).id;
  for (int k = 1; k <= 3; k++) {
    final prev = e.cells.map((c) => c.copy()).toList();
    e.rollStep(0, k);
    print('rollStep($k) → 引擎 ${fmt(e.cells)} (${e.cells.length}格) rollSteps=${e.lastRollSteps}');
    int oi = -1, ni = -1;
    for (int idx = 0; idx < prev.length; idx++) {
      if (prev[idx].id == rollerId) { oi = idx; break; }
    }
    for (int j = 0; j < e.cells.length; j++) {
      if (e.cells[j].id == rollerId) { ni = j; break; }
    }
    if (oi < 0 || ni < 0) { print('  滚木消失'); continue; }
    if (oi == ni) { print('  滚木没动'); continue; }
    simRoll(e, prev, oi, ni > oi ? 1 : -1, e.lastRollSteps, rollerId);
  }
}
