// 动画层逐帧模拟器：复刻 game_screen.dart 的 _playRollActs/_detectRoll/_startMoveAnim/applyRollStep/_cellOffset
// 逻辑，逐帧打印 6 的渲染位置，验证绑定模型与旧路径在四个场景下的表现
// 用法：dart run tools/anim_sim.dart
import '../client/lib/game/rules.dart' as R;

const stepW = 40.0; // 每格步距（含 margin）
const layoutW = 800.0; // 布局宽度：足够宽 → 棋盘恒溢出 → centerDelta=0（手机实况）
const moveMs = 260; // 每格平移时长
const insertMs = 400; // 插桥动画时长
const pauseCrushMs = 660; // 压单位停顿
const pauseDeadMs = 400; // 死亡停顿
const tickMs = 30; // 模拟帧间隔

double easeOutCubic(double t) => 1 - (1 - t) * (1 - t) * (1 - t);
double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

class InsertAnim {
  int idx;
  double t = 0; // 0→1
  bool done = false;
  InsertAnim(this.idx);
}

class Sim {
  List<Map<String, dynamic>> animCells;
  Map<String, dynamic>? mv;
  bool rollDead = false;
  int step = 0;
  final List<InsertAnim> inserts = [];

  Sim(this.animCells);

  // ── _cellOffset 复刻（只保留插入分支；centerDelta 在宽屏=0） ──
  double cellOffset(int i) {
    double dx = 0;
    for (final a in inserts) {
      if (a.done) continue;
      final tv = clamp01(a.t / 0.75); // Interval(0,0.75)
      final t = easeOutCubic(tv);
      if (i != a.idx) {
        // centerDelta（宽屏恒 0）
      }
      if (i > a.idx) dx -= stepW * (1 - t);
    }
    return dx;
  }

  // 6 当前渲染位置（格单位）：浮层优先，否则棋盘格子
  double? sixPos() {
    final m = mv;
    if (m != null && m['bound'] != true && m['_floating'] == true) {
      final fi = m['stepFrom'] as int;
      final t = m['_t'] as double;
      final subDirn = m['subDirn'] as int;
      return fi * stepW + t * subDirn * stepW + cellOffset(fi);
    }
    for (int i = 0; i < animCells.length; i++) {
      final c = animCells[i];
      if (c['v'] == 6 && c['bridge'] != true && c['o'] != null) return i * stepW + cellOffset(i);
    }
    return null;
  }

  String boardLine() => animCells
      .map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : (c['o'] == 0 ? '[${c['v']}]' : '{${c['v']}}')))
      .join(' ');

  void applyRollStep(int s, List? rollSteps, int oldIdx, int dirn, int v, int o, dynamic rid, int? bindAt) {
    if (rollSteps == null || s < 1 || s > rollSteps.length) return;
    final rs = rollSteps[s - 1] as Map;
    if (rs['dead'] == true) {
      rollDead = true;
      return;
    }
    if (rs['bump'] == true || rs['crush'] != true) return;
    final arrival = oldIdx + dirn * s;
    if (arrival < 0 || arrival >= animCells.length) return;
    final origId = animCells[arrival]['id'];
    final owner = rs['owner'] as int?;
    if (rs['kill'] == true) {
      animCells[arrival] = {'v': 0, 'o': null, 'id': origId};
    } else if (rs['bridge'] == true) {
      if (bindAt != null) {
        // 绑定模型
        animCells[arrival] = {'id': rid, 'v': v, 'o': o, 'pressedV': rs['newV'] as int, 'pressedO': owner};
        animCells.insert(arrival, {'v': 0, 'o': null, 'bridge': true, 'id': -999});
        inserts.add(InsertAnim(arrival));
        mv!['bound'] = true;
      } else {
        // 旧路径
        animCells.insert(arrival, {'v': 0, 'o': null, 'bridge': true, 'id': -999});
        if (arrival + 1 < animCells.length) {
          animCells[arrival + 1] = {'v': rs['newV'] as int, 'o': owner, 'id': origId};
        }
        inserts.add(InsertAnim(arrival));
      }
    } else {
      animCells[arrival] = {'v': rs['newV'] as int, 'o': owner, 'id': origId};
    }
  }

  void placeUnit(int from, dynamic rid, int v, int o) {
    for (int k = 0; k < animCells.length; k++) {
      final c = animCells[k];
      final isRoller = rid != null ? c['id'] == rid : (k == from && c['v'] == v && c['o'] == o);
      if (isRoller) {
        final pv = c['pressedV'];
        if (pv != null && (pv as num) > 0) {
          animCells[k] = {'v': pv.toInt(), 'o': c['pressedO'] as int?, 'id': -1000 - k};
        } else if (c['bridge'] == true || c['onBridge'] == true) {
          animCells[k] = {'v': 0, 'o': null, 'bridge': true, 'id': -1000 - k};
        } else {
          animCells[k] = {'v': 0, 'o': null, 'id': -1000 - k};
        }
      }
    }
  }
}

// 运行一次移动动画（复刻 _startMoveAnim 主体），返回 (时间, 描述) 事件流
List<(int, String)> runMove(
  List prevCells,
  Map<String, dynamic> moved,
  List? rollSteps, {
  int? bindAt,
  String tag = '',
}) {
  final sim = Sim(prevCells.map((c) => Map<String, dynamic>.from(c)).toList());
  final v = moved['v'] as int;
  final o = moved['o'] as int;
  final dirn = moved['dir'] as int;
  final steps = moved['steps'] as int;
  final oldIdx = moved['oldIdx'] as int;
  dynamic rid = moved['id'];
  if (rid == null && oldIdx >= 0 && oldIdx < prevCells.length) {
    rid = (prevCells[oldIdx] as Map?)?['id'];
  }
  sim.mv = {
    'v': v, 'o': o, 'dirn': dirn, 'steps': steps, 'oldIdx': oldIdx,
    'stepFrom': oldIdx, 'bindAt': bindAt, 'bound': false, '_floating': true, '_t': 0.0, 'subDirn': dirn,
  };

  final events = <(int, String)>[];
  var t = 0;

  // 推进插入动画（400ms 总时长，与真实 AnimationController 一致）
  void advanceInserts(int ms) {
    for (final a in sim.inserts) {
      if (a.done) continue;
      a.t += ms / insertMs;
      if (a.t >= 1.0) {
        a.t = 1.0;
        a.done = true;
      }
    }
  }

  void log(String s) => events.add((t, s));
  void sample(String prefix) {
    final pos = sim.sixPos();
    if (pos != null) events.add((t, '$prefix 6@${(pos / stepW).toStringAsFixed(2)}格'));
  }

  void nextStep() {
    sim.step++;
    if (sim.step > steps) {
      // cleanup：找 id==rid 清掉 → 落位到 to
      final m = sim.mv!;
      final subDirn = (m['subDirn'] as int?) ?? dirn;
      final pushed = m['pushed'] == true;
      final to = (m['bindAt'] as int?) ?? (pushed ? oldIdx : oldIdx + subDirn);
      for (int k = 0; k < sim.animCells.length; k++) {
        final c = sim.animCells[k];
        final isRoller = rid != null ? c['id'] == rid : false;
        if (isRoller) {
          final pv = c['pressedV'];
          if (pv != null && (pv as num) > 0) {
            sim.animCells[k] = {'v': pv.toInt(), 'o': c['pressedO'] as int?};
          } else if (c['bridge'] == true) {
            sim.animCells[k] = {'v': 0, 'o': null, 'bridge': true};
          } else {
            sim.animCells[k] = {'v': 0, 'o': null};
          }
        }
      }
      if (to >= 0 && to < sim.animCells.length) {
        final tc = sim.animCells[to] as Map;
        final tcB = tc['bridge'] == true || tc['onBridge'] == true;
        final tcV = (tc['v'] as num?)?.toInt() ?? 0;
        final tcO = tc['o'] as int?;
        sim.animCells[to] = tcB
            ? {'id': rid, 'v': v, 'o': o, 'bridge': true, 'onBridge': true, 'pressedV': tcV > 0 ? tcV : null, 'pressedO': tcV > 0 ? tcO : null}
            : {'id': rid, 'v': v, 'o': o, 'pressedV': tcV > 0 ? tcV : null, 'pressedO': tcV > 0 ? tcO : null};
      }
      sim.mv!['_floating'] = false;
      log('CLEANUP: to=$to 动画棋盘=${sim.boardLine()}');
      return;
    }
    final rsNow = rollSteps != null && sim.step <= rollSteps.length ? rollSteps[sim.step - 1] : null;
    final isBump = rsNow != null && rsNow['bump'] == true;
    final subDirn = isBump ? 1 : dirn;
    // 修复 3b：实际位置按前 step-1 个子步累计（bump 反向）
    var from = oldIdx;
    for (var i = 1; i < sim.step; i++) {
      final r = rollSteps != null && i <= rollSteps.length ? rollSteps[i - 1] : null;
      from += (r != null && r['bump'] == true) ? 1 : dirn;
    }
    sim.mv!['stepFrom'] = from;
    sim.mv!['subDirn'] = subDirn;
    sim.placeUnit(from, rid, v, o);
    sim.mv!['_floating'] = true;
    sim.mv!['_t'] = 0.0;
    log('STEP${sim.step}: from=$from subDirn=$subDirn 棋盘=${sim.boardLine()}');

    // 平移 260ms，30ms 采样（同时推进插入动画）
    for (var tt = 0; tt <= moveMs; tt += tickMs) {
      sim.mv!['_t'] = tt / moveMs;
      advanceInserts(tickMs);
      sample('  [滑${(tt / 1000).toStringAsFixed(1)}s]');
    }
    t += moveMs;

    sim.applyRollStep(sim.step, rollSteps, oldIdx, dirn, v, o, rid, bindAt);
    if (sim.rollDead) {
      log('  死亡（rollDead） 棋盘=${sim.boardLine()}');
      // 死亡停顿 400ms（推进插入动画）
      for (var tt = 0; tt < pauseDeadMs; tt += tickMs) {
        advanceInserts(tickMs);
        sample('  [死停${(tt / 1000).toStringAsFixed(1)}s]');
      }
      t += pauseDeadMs;
      log('  死停后 cleanup');
      nextStep();
      return;
    }
    if (bindAt != null && sim.mv!['bound'] != true) {
      final bi = bindAt;
      if (bi >= 0 && bi < sim.animCells.length) {
        final c = sim.animCells[bi];
        final pv = (c['v'] as num?)?.toInt() ?? 0;
        final po = c['o'] as int?;
        final cb = c['bridge'] == true || c['onBridge'] == true;
        sim.animCells[bi] = cb
            ? {'id': rid, 'v': v, 'o': o, 'bridge': true, 'onBridge': true, 'pressedV': pv > 0 ? pv : null, 'pressedO': pv > 0 ? po : null}
            : {'id': rid, 'v': v, 'o': o, 'pressedV': pv > 0 ? pv : null, 'pressedO': pv > 0 ? po : null};
      }
      sim.mv!['bound'] = true;
      log('  bind@$bi 棋盘=${sim.boardLine()}');
    }
    final rs = rollSteps != null && sim.step <= rollSteps.length ? rollSteps[sim.step - 1] : null;
    final isCrush = rs != null && rs['crush'] == true && rs['kill'] != true;
    final isBump2 = rs != null && rs['bump'] == true;
    final hasNext = sim.step < steps;
    if (isCrush && hasNext) {
      log('  crush+hasNext → 立即下一步');
      nextStep();
      return;
    }
    if ((isCrush || isBump2) && !hasNext) {
      log('  crush/bump 停顿 ${pauseCrushMs}ms');
      // 停顿期间推进插入动画并采样
      for (var tt = 0; tt < pauseCrushMs; tt += tickMs) {
        advanceInserts(tickMs);
        sample('  [停${(tt / 1000).toStringAsFixed(1)}s]');
      }
      t += pauseCrushMs;
      nextStep();
      return;
    }
    nextStep();
  }

  // 推进插入动画（400ms 总时长，与真实 AnimationController 一致）
  // （已在上方声明 advanceInserts）


  nextStep();

  return events;
}

String boardStr(List<R.AimCell> cells) =>
    cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : (c.o == 0 ? '[${c.v}]' : '{${c.v}}'))).join(' ');

// ── 热座路径：逐步 rollStepOnce + _playRollActs 复刻 ──
void hotseatScenario(List<R.AimCell> initCells, int owner, String label) {
  print('\n════════ 热座 $label ════════');
  final g = R.AimGame(limit: 16);
  g.cells = initCells;
  print('初始棋盘: ${boardStr(g.cells)}');
  var guard = 0;
  while (guard++ < 10) {
    final prev = g.cells.map((c) => c.toMap()).toList();
    final acts = g.rollStepOnce(owner);
    if (acts == null) {
      print('（无更多步骤）');
      break;
    }
    print('规则步 → acts=$acts');
    // ── 复刻 _playRollActs ──
    int from = -1, v = 6, o = 0;
    final f = acts.first['from'];
    if (f is int && f >= 0 && f < prev.length) {
      from = f;
      final c = prev[f] as Map;
      v = (c['v'] as num?)?.toInt() ?? 6;
      o = (c['o'] as num?)?.toInt() ?? 0;
    }
    if (from < 0) break;
    final dirn = o == 1 ? -1 : 1;
    int to = from;
    final hasDead = acts.any((a) => a['op'] == 'dead');
    final subSteps = <Map<String, dynamic>>[];
    int? bindAt;
    for (final act in acts) {
      final op = act['op'] as String?;
      switch (op) {
        case 'move':
          to = (act['to'] as num).toInt();
          bindAt = to;
          break;
        case 'crush':
          final at = (act['at'] as num).toInt();
          final ow = (act['owner'] as num?)?.toInt() ?? o;
          final oldV = (act['oldV'] as num?)?.toInt() ?? 0;
          final newV = (act['newV'] as num?)?.toInt() ?? 0;
          final bridge = act['bridge'] == true;
          if (bridge && !hasDead) {
            to = at + 1;
            bindAt = to;
            subSteps.add({'crush': true, 'owner': ow, 'oldV': oldV, 'newV': newV, 'bridge': true});
          } else if (bridge) {
            to = at + 1;
            subSteps.add({'crush': true, 'owner': ow, 'oldV': oldV, 'newV': newV, 'bridge': true});
            subSteps.add({'bump': true});
          } else {
            to = (act['to'] as num).toInt();
            bindAt = to;
            subSteps.add({'crush': true, 'owner': ow, 'oldV': oldV, 'newV': newV, 'bridge': false});
          }
          break;
        case 'kill':
          final ow = (act['owner'] as num?)?.toInt() ?? o;
          final oldV = (act['oldV'] as num?)?.toInt() ?? 0;
          to = (act['to'] as num).toInt();
          bindAt = to;
          subSteps.add({'crush': true, 'kill': true, 'owner': ow, 'oldV': oldV});
          break;
        case 'dead':
          to = from + dirn;
          bindAt = null;
          subSteps.add({'dead': true, 'bridgeCollapse': act['reason'] == 'bridge'});
          break;
      }
    }
    final steps = hasDead ? subSteps.length : 1;
    print('  动画参数: to=$to bindAt=$bindAt steps=$steps dirn=$dirn');
    final evs = runMove(prev, {'idx': to, 'v': v, 'o': o, 'steps': steps, 'dir': dirn, 'oldIdx': from},
        subSteps.isEmpty ? null : subSteps, bindAt: hasDead ? null : bindAt);
    for (final e in evs) {
      print('  t=${e.$1}ms ${e.$2}');
    }
    if (hasDead) break;
  }
  print('规则最终棋盘: ${boardStr(g.cells)}');
}

// ── 联机路径：_detectRoll 复刻（全量 rollSteps 一次播） ──
void netScenario(String label, List<R.AimCell> initCells, int owner, {required List<Map<String, dynamic>> Function(R.AimGame) getSteps}) {
  print('\n════════ 联机 $label ════════');
  final g = R.AimGame(limit: 16);
  g.cells = initCells;
  final prev = g.cells.map((c) => c.toMap()).toList();
  final steps = getSteps(g);
  print('初始棋盘: ${boardStr(g.cells)}');
  print('rollSteps: ${steps.map((s) => s.toString()).join(' ')}');
  print('规则最终棋盘: ${boardStr(g.cells)}');
  // _detectRoll：按 id 找滚木
  for (final p in prev) {
    if (p['bridge'] == true || (p['v'] as num?)?.toInt() != 6) continue;
    final me = (p['o'] as num?)?.toInt() ?? 0;
    final dirn = me == 1 ? -1 : 1;
    final pid = p['id'];
    if (pid == null) continue;
    final oi = prev.indexOf(p);
    int? ni;
    for (int k = 0; k < g.cells.length; k++) {
      if (g.cells[k].toMap()['id'] == pid) {
        ni = k;
        break;
      }
    }
    if (ni == null) {
      if (steps.isNotEmpty) {
        // 修复 3a：终点按 rollSteps 实际累计（bump 反向、dead 停在死点再往 dirn 一格）
        var deadEnd = oi;
        var hitDead = false;
        for (final rs in steps) {
          if (rs['dead'] == true) {
            hitDead = true;
            break;
          }
          deadEnd += (rs['bump'] == true) ? 1 : dirn;
        }
        if (hitDead) deadEnd += dirn;
        print('滚木死亡路径: deadEnd=$deadEnd steps=${steps.length}（修复后）');
        final evs = runMove(prev, {'idx': deadEnd, 'v': 6, 'o': me, 'steps': steps.length, 'dir': dirn, 'oldIdx': oi}, steps);
        for (final e in evs) {
          print('  t=${e.$1}ms ${e.$2}');
        }
      }
      continue;
    }
    if (oi == ni) continue;
    final evs = runMove(prev, {'idx': ni, 'v': 6, 'o': me, 'steps': (steps.length == 0 ? 1 : steps.length), 'dir': dirn, 'oldIdx': oi}, steps);
    for (final e in evs) {
      print('  t=${e.$1}ms ${e.$2}');
    }
    break;
  }
}

void main() {
  // 场景 A/B：热座
  var c1 = List<R.AimCell>.generate(10, (i) => R.AimCell(0));
  c1[5] = R.AimCell(6, o: 0);
  c1[6] = R.AimCell(2, o: 0);
  hotseatScenario(c1, 0, '左→右 crush+插桥（绑定模型）');

  var c2 = List<R.AimCell>.generate(10, (i) => R.AimCell(0));
  c2[5] = R.AimCell(2, o: 1);
  c2[6] = R.AimCell(6, o: 1);
  hotseatScenario(c2, 1, '右→左 crush+插桥+撞桥死（绑定模型）');

  // 场景 C/D：联机（服务端 autoRoll 全量）
  var c3 = List<R.AimCell>.generate(10, (i) => R.AimCell(0));
  c3[5] = R.AimCell(6, o: 0);
  c3[6] = R.AimCell(2, o: 0);
  netScenario('左→右 crush+插桥（旧路径浮层）', c3, 0, getSteps: (g) {
    // 模拟服务端 autoRoll：直接用本地规则 autoRoll 全量（同语义）
    g.autoRoll(0);
    return g.rollSteps ?? [];
  });

  var c4 = List<R.AimCell>.generate(10, (i) => R.AimCell(0));
  c4[5] = R.AimCell(2, o: 1);
  c4[6] = R.AimCell(6, o: 1);
  netScenario('右→左 crush+插桥+撞桥死（旧路径浮层）', c4, 1, getSteps: (g) {
    g.autoRoll(1);
    return g.rollSteps ?? [];
  });
}
