// 热座端到端模拟：真实 AimGame 引擎 + local_socket 推送序列 + GameScreen 分支选择
// 逐帧输出 6 的渲染位置（浮层/格子），复现牢大报的问题 1/2
// 用法：dart run tools/hotseat_sim.dart
import '../client/lib/game/rules.dart' as R;

const stepW = 40.0;
const layoutW = 800.0; // 手机宽屏：棋盘恒溢出 → centerDelta=0
const moveMs = 260;
const insertMs = 400;
const pauseCrushMs = 660;
const pauseDeadMs = 400;
const tickMs = 30;

double easeOutCubic(double t) => 1 - (1 - t) * (1 - t) * (1 - t);
double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

class InsertAnim {
  int idx;
  double t = 0;
  bool done = false;
  InsertAnim(this.idx);
}

// 渲染模拟：与 game_screen._mapArea 一致
class Renderer {
  List<Map<String, dynamic>>? animCells; // _animCells
  Map<String, dynamic>? state; // s
  Map<String, dynamic>? mv; // _mv
  bool rollPaused = false;
  bool stepCtrlAnimating = false; // _stepCtrl.isAnimating
  final List<InsertAnim> inserts = [];

  double cellOffset(int i) {
    double dx = 0;
    for (final a in inserts) {
      if (a.done) continue;
      final tv = clamp01(a.t / 0.75);
      final t = easeOutCubic(tv);
      if (i > a.idx) dx -= stepW * (1 - t);
    }
    return dx;
  }

  // 6 的渲染位置（格单位），-1 = 不可见
  double sixPos() {
    final cells = (animCells ?? (state?['cells'] as List?)) ?? [];
    final m = mv;
    final moving = m != null && stepCtrlAnimating || (m != null && rollPaused) && m['bound'] != true;
    if (moving && m != null) {
      final fi = m['stepFrom'] as int;
      final t = m['_t'] as double;
      final subDirn = (m['subDirn'] as int?) ?? (m['dirn'] as int);
      final pushed = m['pushed'] == true;
      var left = fi * stepW + (pushed ? 0.0 : t * subDirn * stepW) + cellOffset(fi);
      return left / stepW;
    }
    for (int i = 0; i < cells.length; i++) {
      final c = cells[i] as Map;
      if (c['v'] == 6 && c['bridge'] != true && c['o'] != null) {
        return (i * stepW + cellOffset(i)) / stepW;
      }
    }
    return -1; // 棋盘里没有 6（死了或隐藏）
  }

  String board() {
    final cells = (animCells ?? (state?['cells'] as List?)) ?? [];
    return cells
        .map((c) => c['bridge'] == true ? '-' : (c['o'] == null ? '0' : (c['o'] == 0 ? '[${c['v']}]' : '{${c['v']}}')))
        .join(' ');
  }
}

// GameScreen 动画播放器（复刻 didUpdateWidget 分支 + _playRollActs + _startMoveAnim 核心）
class AnimPlayer {
  final Renderer r = Renderer();
  final List<String> frames = [];
  int _lastRollStepSeq = 0;
  int _lastRollSeq = 0;
  bool _rollActsDriven = false; // 修复 1：本回合已由 rollActs 逐步驱动，跳过全量重放
  int _lastSeq = 0;
  bool animLock = false;
  int t = 0; // 全局时间 ms
  Map<String, dynamic>? deferredRoll;
  final List<Map<String, dynamic>> pushedStates = []; // 模拟 socket 推送
  int stateIdx = 0;
  List<dynamic>? prevCells; // 客户端缓存的上一 state cells
  Map<String, dynamic>? state;

  void tick(int ms) {
    // 推进 step 控制器与插入动画（简化：由 playRollActs 内部驱动）
  }

  void pushState(Map<String, dynamic> s) {
    prevCells = state?['cells'] as List<dynamic>?;
    state = s;
    // didUpdateWidget 分支
    final la = s['lastAction'];
    final seq = (s['lastSeq'] as num?)?.toInt() ?? 0;
    if (la != null && seq != _lastSeq) {
      _lastSeq = seq;
      // _playLastAction 忽略（非滚木行动，本模拟不涉及）
    }
    final rseq = (s['rollStepSeq'] as num?)?.toInt() ?? 0;
    final rActs = s['rollActs'];
    if (rseq != 0 && rseq != _lastRollStepSeq && rActs is List && rActs.isNotEmpty) {
      _lastRollStepSeq = rseq;
      _rollActsDriven = true;
      final pc = prevCells ?? [];
      playRollActs(rActs.cast<Map<String, dynamic>>(), pc, s['cells'] as List);
    } else if (s['rollPending'] == true && rseq == _lastRollStepSeq && !animLock) {
      frames.add('t=$t 请求 roll_step');
      onRollStepRequest?.call();
    } else {
      final rollSeq = (s['rollSeq'] as num?)?.toInt() ?? 0;
      if (rollSeq != 0 && rollSeq != _lastRollSeq) {
        _lastRollSeq = rollSeq;
        if (_rollActsDriven) {
          frames.add('t=$t ✅ 修复1：跳过 _detectRoll（rollActs 已逐步播完）');
          _rollActsDriven = false;
        } else if (animLock) {
          deferredRoll = <String, dynamic>{'prevCells': prevCells ?? const [], 'newCells': s['cells'] as List, 'rollSteps': s['rollSteps'] as List?};
          frames.add('t=$t 缓存 deferredRoll（动画锁）');
        } else {
          detectRoll(prevCells ?? [], s['cells'] as List, rollSteps: s['rollSteps'] as List?);
        }
      }
    }
  }

  // ── _detectRoll 复刻 ──
  void detectRoll(List prevCells, List newCells, {List? rollSteps}) {
    for (final p in prevCells) {
      if (p['bridge'] == true || (p['v'] as num?)?.toInt() != 6) continue;
      final me = (p['o'] as num?)?.toInt() ?? 0;
      final dirn = me == 1 ? -1 : 1;
      final pid = p['id'];
      if (pid == null) continue;
      final oi = prevCells.indexOf(p);
      int? ni;
      for (int k = 0; k < newCells.length; k++) {
        if (newCells[k]['id'] == pid) {
          ni = k;
          break;
        }
      }
      if (ni == null) {
        if (rollSteps != null && rollSteps.isNotEmpty) {
          final steps = rollSteps.length;
          final deadIdx = oi + dirn * steps;
          frames.add('t=$t ⚠️ _detectRoll 死亡路径: deadIdx=$deadIdx steps=$steps（滚木@$oi 消失）');
          startMove(prevCells, {'idx': deadIdx, 'v': 6, 'o': me, 'steps': steps, 'dir': dirn, 'oldIdx': oi}, rollSteps, bindAt: null);
        }
        continue;
      }
      if (oi == ni) continue;
      frames.add('t=$t _detectRoll 重放: ${oi}→$ni steps=${rollSteps?.length}');
      startMove(prevCells, {'idx': ni, 'v': 6, 'o': me, 'steps': (rollSteps?.length ?? 1), 'dir': dirn, 'oldIdx': oi}, rollSteps, bindAt: null);
      break;
    }
  }

  // ── _playRollActs 复刻（含 dead 分支）──
  void playRollActs(List<Map<String, dynamic>> acts, List prevCells, List newCells) {
    int from = -1, v = 6, o = 0;
    final first = acts.isNotEmpty ? acts.first : null;
    final f = first?['from'];
    if (f is int && f >= 0 && f < prevCells.length) {
      from = f;
      final c = prevCells[f] as Map;
      v = (c['v'] as num?)?.toInt() ?? 6;
      o = (c['o'] as num?)?.toInt() ?? 0;
    }
    if (from < 0) return;
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
          subSteps.add({'dead': true, 'bridgeCollapse': act['reason'] == 'bridge' || act['reason'] == 'fall'});
          break;
      }
    }
    final steps = hasDead ? subSteps.length : 1;
    frames.add('t=$t _playRollActs: acts=$acts → to=$to bindAt=$bindAt steps=$steps hasDead=$hasDead');
    startMove(prevCells, {'idx': to, 'v': v, 'o': o, 'steps': steps, 'dir': dirn, 'oldIdx': from}, subSteps.isEmpty ? null : subSteps, bindAt: hasDead ? null : bindAt, onDone: () {
      frames.add('t=$t 动画播完 → 请求下一步 roll_step');
      onRollStepRequest?.call();
    });
  }

  // 占位：由外部驱动（模拟 socket）
  void Function()? onRollStepRequest;
  int _pendingSteps = 0;

  void advanceInserts(int ms) {
    for (final a in r.inserts) {
      if (a.done) continue;
      a.t += ms / insertMs;
      if (a.t >= 1.0) {
        a.t = 1.0;
        a.done = true;
      }
    }
  }

  // ── _startMoveAnim 复刻 ──
  void startMove(List prevCells, Map<String, dynamic> moved, List? rollSteps, {int? bindAt, void Function()? onDone}) {
    final v = moved['v'] as int;
    final o = moved['o'] as int;
    final dirn = moved['dir'] as int;
    final steps = moved['steps'] as int;
    final oldIdx = moved['oldIdx'] as int;
    dynamic rid = moved['id'];
    if (rid == null && oldIdx >= 0 && oldIdx < prevCells.length) {
      rid = (prevCells[oldIdx] as Map?)?['id'];
    }
    var anim = prevCells.map((c) => Map<String, dynamic>.from(c)).toList();
    r.animCells = anim;
    r.mv = {'v': v, 'o': o, 'dirn': dirn, 'steps': steps, 'oldIdx': oldIdx, 'stepFrom': oldIdx, 'bindAt': bindAt, 'bound': false, '_t': 0.0, 'subDirn': dirn};
    animLock = true;
    var step = 0;
    var fakeId = -1;

    void placeUnit(int from) {
      for (int k = 0; k < anim.length; k++) {
        final c = anim[k];
        final isRoller = rid != null ? c['id'] == rid : (k == from && c['v'] == v && c['o'] == o);
        if (isRoller) {
          final pv = c['pressedV'];
          if (pv != null && (pv as num) > 0) {
            anim[k] = {'v': pv.toInt(), 'o': c['pressedO'] as int?, 'id': fakeId--};
          } else if (c['bridge'] == true || c['onBridge'] == true) {
            anim[k] = {'v': 0, 'o': null, 'bridge': true, 'id': fakeId--};
          } else {
            anim[k] = {'v': 0, 'o': null, 'id': fakeId--};
          }
        }
      }
      r.animCells = anim.map((c) => Map<String, dynamic>.from(c)).toList();
    }

    void applyRollStep(int s) {
      if (rollSteps == null || s < 1 || s > rollSteps.length) return;
      final rs = rollSteps[s - 1] as Map;
      if (rs['dead'] == true) {
        r.rollPaused = true;
        r.mv!['_dead'] = true;
        return;
      }
      if (rs['bump'] == true || rs['crush'] != true) return;
      final arrival = oldIdx + dirn * s;
      if (arrival < 0 || arrival >= anim.length) return;
      final origId = anim[arrival]['id'];
      final owner = rs['owner'] as int?;
      if (rs['kill'] == true) {
        anim[arrival] = {'v': 0, 'o': null, 'id': origId};
      } else if (rs['bridge'] == true) {
        if (bindAt != null) {
          anim[arrival] = {'id': rid, 'v': v, 'o': o, 'pressedV': rs['newV'] as int, 'pressedO': owner};
          anim.insert(arrival, {'v': 0, 'o': null, 'bridge': true, 'id': fakeId--});
          r.inserts.add(InsertAnim(arrival));
          r.mv!['bound'] = true;
        } else {
          anim.insert(arrival, {'v': 0, 'o': null, 'bridge': true, 'id': fakeId--});
          if (arrival + 1 < anim.length) {
            anim[arrival + 1] = {'v': rs['newV'] as int, 'o': owner, 'id': origId};
          }
          r.inserts.add(InsertAnim(arrival));
        }
      } else {
        anim[arrival] = {'v': rs['newV'] as int, 'o': owner, 'id': origId};
      }
      r.animCells = anim.map((c) => Map<String, dynamic>.from(c)).toList();
    }

    void cleanup() {
      final doneCells = r.animCells;
      r.animCells = null;
      animLock = false;
      final m = r.mv;
      r.mv = null;
      r.rollPaused = false;
      if (doneCells != null && m != null) {
        final subDirn = (m['subDirn'] as int?) ?? dirn;
        final pushed = m['pushed'] == true;
        final to = (m['bindAt'] as int?) ?? (pushed ? oldIdx : oldIdx + subDirn);
        for (int k = 0; k < doneCells.length; k++) {
          final c = doneCells[k] as Map;
          final isRoller = rid != null ? c['id'] == rid : false;
          if (isRoller) {
            final pv = c['pressedV'];
            if (pv != null && (pv as num) > 0) {
              doneCells[k] = {'v': pv.toInt(), 'o': c['pressedO'] as int?};
            } else if (c['bridge'] == true || c['onBridge'] == true) {
              doneCells[k] = {'v': 0, 'o': null, 'bridge': true};
            } else {
              doneCells[k] = {'v': 0, 'o': null};
            }
          }
        }
        if (to >= 0 && to < doneCells.length) {
          final tc = doneCells[to] as Map;
          final tcB = tc['bridge'] == true || tc['onBridge'] == true;
          final tcV = (tc['v'] as num?)?.toInt() ?? 0;
          final tcO = tc['o'] as int?;
          doneCells[to] = tcB
              ? {'id': rid, 'v': v, 'o': o, 'bridge': true, 'onBridge': true, 'pressedV': tcV > 0 ? tcV : null, 'pressedO': tcV > 0 ? tcO : null}
              : {'id': rid, 'v': v, 'o': o, 'pressedV': tcV > 0 ? tcV : null, 'pressedO': tcV > 0 ? tcO : null};
        }
      }
      frames.add('t=$t cleanup 完成，切规则棋盘: ${r.board()}');
      onDone?.call();
    }

    void nextStep() {
      step++;
      if (step > steps) {
        cleanup();
        return;
      }
      final rsNow = rollSteps != null && step <= rollSteps.length ? rollSteps[step - 1] : null;
      final isBump = rsNow != null && rsNow['bump'] == true;
      final subDirn = isBump ? 1 : dirn;
      final from = oldIdx + dirn * (step - 1);
      r.mv!['stepFrom'] = from;
      r.mv!['subDirn'] = subDirn;
      placeUnit(from);
      r.mv!['_t'] = 0.0;
      r.stepCtrlAnimating = true;
      frames.add('t=$t  滑行 ${from}→${from + subDirn}（棋盘: ${r.board()}）');
      // 平移 260ms
      for (var tt = 0; tt <= moveMs; tt += tickMs) {
        r.mv!['_t'] = tt / moveMs;
        r.stepCtrlAnimating = true;
        advanceInserts(tickMs);
        frames.add('t=${t + tt}    6@${r.sixPos().toStringAsFixed(2)}格');
      }
      t += moveMs;
      r.stepCtrlAnimating = false;
      applyRollStep(step);
      if (r.mv!['_dead'] == true) {
        frames.add('t=$t  死亡停顿 400ms（棋盘: ${r.board()}）');
        for (var tt = 0; tt < pauseDeadMs; tt += tickMs) {
          advanceInserts(tickMs);
          frames.add('t=${t + tt}    6@${r.sixPos().toStringAsFixed(2)}格');
        }
        t += pauseDeadMs;
        nextStep();
        return;
      }
      if (bindAt != null && r.mv!['bound'] != true) {
        final bi = bindAt;
        if (bi >= 0 && bi < anim.length) {
          final c = anim[bi];
          final pv = (c['v'] as num?)?.toInt() ?? 0;
          final po = c['o'] as int?;
          final cb = c['bridge'] == true || c['onBridge'] == true;
          anim[bi] = cb
              ? {'id': rid, 'v': v, 'o': o, 'bridge': true, 'onBridge': true, 'pressedV': pv > 0 ? pv : null, 'pressedO': pv > 0 ? po : null}
              : {'id': rid, 'v': v, 'o': o, 'pressedV': pv > 0 ? pv : null, 'pressedO': pv > 0 ? po : null};
        }
        r.mv!['bound'] = true;
        frames.add('t=$t  bind@$bi（棋盘: ${r.board()}）');
      }
      final rs = rollSteps != null && step <= rollSteps.length ? rollSteps[step - 1] : null;
      final isCrush = rs != null && rs['crush'] == true && rs['kill'] != true;
      final isBump2 = rs != null && rs['bump'] == true;
      final hasNext = step < steps;
      if (isCrush && hasNext) {
        nextStep();
        return;
      }
      if ((isCrush || isBump2) && !hasNext) {
        frames.add('t=$t  压单位停顿 660ms');
        for (var tt = 0; tt < pauseCrushMs; tt += tickMs) {
          advanceInserts(tickMs);
          frames.add('t=${t + tt}    6@${r.sixPos().toStringAsFixed(2)}格');
        }
        t += pauseCrushMs;
        nextStep();
        return;
      }
      nextStep();
    }

    nextStep();
  }
}

String boardStr(List<R.AimCell> cells) =>
    cells.map((c) => c.bridge ? '-' : (c.o == null ? '0' : (c.o == 0 ? '[${c.v}]' : '{${c.v}}'))).join(' ');

void main() {
  // ── 场景 1：热座 右→左 crush 插桥 + 撞桥死 ──
  print('════════ 热座 右→左 crush插桥+撞桥死（端到端） ════════');
  final g = R.AimGame(limit: 16);
  g.cells = List<R.AimCell>.generate(10, (i) => R.AimCell(0));
  g.cells[5] = R.AimCell(2, o: 1);
  g.cells[6] = R.AimCell(6, o: 1);
  print('初始: ${boardStr(g.cells)}');

  final player = AnimPlayer();
  var requests = 0;
  player.onRollStepRequest = () {
    requests++;
    if (requests > 8) return;
    final acts = g.rollStepOnce(g.turn);
    player.pushState(g.viewFor(g.turn));
    if (acts == null) g.clearPendingRoll();
  };

  // 模拟 endTurn：deferRoll 推未滚棋盘 → 客户端逐步驱动（递归：每步播完自动请求下一步）
  g.endTurn(0, deferRoll: true);
  player.pushState(g.viewFor(g.turn));
  print('\n--- 6 位置全帧 ---');
  for (final f in player.frames) {
    if (f.contains('6@')) print(f);
  }

  // ── 场景 2：热座 左→右 crush 插桥 + 继续滚存活（验证 _detectRoll 重放）──
  print('\n════════ 热座 左→右 crush插桥+继续滚存活 ════════');
  final g2 = R.AimGame(limit: 16);
  g2.cells = List<R.AimCell>.generate(10, (i) => R.AimCell(0));
  g2.cells[5] = R.AimCell(6, o: 0);
  g2.cells[6] = R.AimCell(2, o: 0);
  print('初始: ${boardStr(g2.cells)}');

  final player2 = AnimPlayer();
  var requests2 = 0;
  player2.onRollStepRequest = () {
    requests2++;
    if (requests2 > 10) return;
    final acts = g2.rollStepOnce(g2.turn);
    player2.pushState(g2.viewFor(g2.turn));
    if (acts == null) g2.clearPendingRoll();
  };
  g2.endTurn(0, deferRoll: true); // 玩家0 结束 → 轮到玩家1（无滚木）
  player2.pushState(g2.viewFor(g2.turn));
  g2.endTurn(1, deferRoll: true); // 玩家1 结束 → 轮到玩家0 → 玩家0 的滚木待滚
  player2.pushState(g2.viewFor(g2.turn));
  print('\n--- 关键帧 ---');
  for (final f in player2.frames) {
    if (f.contains('⚠️') || f.contains('_detectRoll') || f.contains('_playRollActs') || f.contains('滑行')) print(f);
  }
  // ── 场景 3：热座 多滚木 A死B活（A 压单位插桥后撞桥死，B 滚满存活）——验证修复 1+2 ──
  print('\n════════ 热座 多滚木：A 死 B 活（修复 1+2） ════════');
  final g3 = R.AimGame(limit: 16);
  g3.cells = List<R.AimCell>.generate(10, (i) => R.AimCell(0));
  g3.cells[1] = R.AimCell(2, o: 1); // A 压这个
  g3.cells[2] = R.AimCell(6, o: 1); // A（右→左，先收集先滚）
  g3.cells[8] = R.AimCell(6, o: 1); // B（右→左）
  g3.cells[0] = R.AimCell(8, o: 0);
  g3.cells[9] = R.AimCell(8, o: 1);
  print('初始: ${boardStr(g3.cells)}');

  final player3 = AnimPlayer();
  var requests3 = 0;
  player3.onRollStepRequest = () {
    requests3++;
    if (requests3 > 12) return;
    final acts = g3.rollStepOnce(g3.turn);
    player3.pushState(g3.viewFor(g3.turn));
    if (acts == null) g3.clearPendingRoll();
  };
  g3.endTurn(0, deferRoll: true);
  player3.pushState(g3.viewFor(g3.turn));
  print('\n--- 关键帧 ---');
  for (final f in player3.frames) {
    if (f.contains('⚠️') || f.contains('_detectRoll') || f.contains('_playRollActs') || f.contains('修复1')) print(f);
  }
  final bad = player3.frames.where((f) => f.contains('⚠️') || f.contains('重放')).toList();
  print(bad.isEmpty ? '\n✅ 无 _detectRoll 重放（修复 1 生效）' : '\n❌ 仍有重放: $bad');
}
