// 教程引擎：本地状态机（不连服务器）
// 棋盘 + 迷你规则 + 剧本指令执行 + 玩家交互校验
//
// 玩家视角：始终是玩家0（左，朝右 +1）；敌方 = 玩家1（右，朝左 -1）
//
// 指令类型（Map 列表）：
//   {'say': '说话人', 'text': '台词'}
//   {'choice': ['选项1','选项2'], 'branch': {'选项1': [...], '选项2': [...]}}
//   {'board': ['8','0','{1}',...]}          // 设置棋盘快照；{x}=敌方，- = 桥
//   {'highlight': [0,1], 'arrow': 0}        // 高亮格子（可带箭头起始格）
//   {'stats': {'1': '伤害1 生命1'}}          // 显示人物词条
//   {'wait': 'select'|'action'|'target'|'tap', 'cell': i, 'action': 'produce', 'target': j}
//   {'auto': 'produce'|'move'|'attack'|'devour'|'split'|'roll'|'walk', 'i':, 'steps':, 'j':, 'keep':, 'owner':}
//   {'popup': '标题', 'lines': ['...']}
//   {'end': true}
//   {'clear': true}                          // 清空高亮

import 'dart:math' as math;

class TutCell {
  int v;         // 0=空地, 1..9
  int? o;        // 0=我方 1=敌方 null=无人
  bool bridge;
  bool onBridge;
  bool auto;     // 滚木已激活
  int id;        // 稳定身份（元素思维：移动/合并时 id 跟随，删除时消失）
  int? pressedV; // 滚木脚下压着的单位值（对齐游戏 AimCell.pressedV：滚木走开时转正显示）
  int? pressedO; // 滚木脚下压着的单位归属
  static int _idSeq = 1;
  TutCell(this.v,
      {this.o, this.bridge = false, this.onBridge = false, this.auto = false,
      this.pressedV, this.pressedO})
      : id = _idSeq++;
  TutCell.withId(this.v, this.id,
      {this.o, this.bridge = false, this.onBridge = false, this.auto = false,
      this.pressedV, this.pressedO});

  TutCell copy() => TutCell.withId(v, id,
      o: o, bridge: bridge, onBridge: onBridge, auto: auto,
      pressedV: pressedV, pressedO: pressedO);

  // 滚木脚下压着单位：棋盘格显示滚木，走开时转正露出（对齐游戏 _unpress）
  bool get isPressing => pressedV != null && pressedV! > 0;
  bool get isUnit => !bridge && v >= 1;
  bool get isB => bridge;
  static TutCell fromSpec(String s) {
    if (s == '-') return TutCell(0, bridge: true);
    if (s == '0') return TutCell(0, o: null);
    if (s.startsWith('{')) {
      return TutCell(int.parse(s.substring(1, s.length - 1)), o: 1);
    }
    return TutCell(int.parse(s), o: 0);
  }
}

class TutEngine extends ChangeNotifierWrapper {
  // —— 棋盘 ——
  List<TutCell> cells = [];
  int limit = 16;

  // —— 剧本 ——
  List<Map<String, dynamic>> script = [];
  int stepIdx = 0;
  bool waiting = false;        // 是否在等待玩家操作
  String waitType = '';        // select/action/target/tap
  int? waitCell;
  String? waitAction;
  int? waitTarget;
  Map<String, dynamic> currentStep = {};

  // —— UI 状态 ——
  int? selUnit;
  String? selAction;           // 选目标模式
  int? splitKeep;
  int? waitKeep; // wait action split 的指定拆法（教学剧情要求拆成固定值）
  bool splitMode = false;
  List<int> highlightCells = [];
  int? arrowFrom;
  int? arrowTo;
  Map<String, String> stats = {};
  String? popupTitle;
  List<String> popupLines = [];
  bool popupOpen = false;
  bool finished = false;
  bool storyMode = false;      // 剧情场景（棋盘暗置）
  bool _firstBoard = true;     // 章节首个 board（触发退场+入场动画），章节内 board 直接更新
  bool autoPause = false;      // 自动演示后暂停（点击继续）
  // 棋盘切换动画：board 指令先暂存，UI 播完退场后调 applyPendingBoard()
  List<String>? pendingBoard;
  bool boardPending = false;
  // board 状态更新 diff（元素思维：同位置复用 id，变化/新增/删除标记出来，UI 播动画）
  Map<String, dynamic>? boardDiff;
  // 剧本驱动（与对战服务端同格式）：每次操作记录 lastAction，UI 照着演
  Map<String, dynamic>? lastAction;
  int lastSeq = 0;
  // 滚木逐子步碾压结果（与对战服务端 rollSteps 同格式）：压到即更新，不是滚完统一处理
  List<Map<String, dynamic>> lastRollSteps = [];
  // 本轮滚动已碾压的单位 id（对齐游戏 rules._rsRolled：溢出被顶开的单位不再重复碾）
  final Set<int> _rolledIds = {};

  // 演示队列：连续 auto 指令收集后由 UI 逐格播放（一格一停）
  final List<Map<String, dynamic>> demoQueue = [];
  bool demoReady = false;      // 有演示待播放
  bool _demoAdvance = false;   // 演示播完是否推进脚本（auto 指令/wait 操作推进；普通模式移动不推进）
  List<String> log = [];       // 战报（仿游戏）
  int round = 1;

  // ══════════ 统计（仿游戏信息栏） ══════════
  int get mySum => cells.where((c) => c.isUnit && c.o == 0).fold(0, (s, c) => s + c.v);
  int get enemySum => cells.where((c) => c.isUnit && c.o == 1).fold(0, (s, c) => s + c.v);
  int get myBases => cells.where((c) => c.isUnit && c.o == 0 && c.v == 8).length;
  int get myHqs => cells.where((c) => c.isUnit && c.o == 0 && c.v == 9).length;
  int get enemyBases => cells.where((c) => c.isUnit && c.o == 1 && c.v == 8).length;
  int get enemyHqs => cells.where((c) => c.isUnit && c.o == 1 && c.v == 9).length;
  int get mapLen => cells.length;

  void _log(String s) {
    log.add(s);
    if (log.length > 8) log.removeAt(0);
  }

  // —— 对话状态 ——
  String? currentSpeaker;
  String? currentText;
  List<String>? choiceOptions;
  Map<String, List<dynamic>>? choiceBranches;

  // 迷你规则常量
  static const _dir = 1;                       // 我方朝右
  static const _enemyDir = -1;                 // 敌方朝左
  static const _range = {3: 2, 4: 3};
  static const _cavalry = {2, 5};
  static const _bridgeOk = {1, 2, 3, 4};

  TutEngine() {
    cells = []; // 初始无地图（剧本 board 指令出现后才展开）
  }

  int get dir => _dir;
  int get enemyDir => _enemyDir;

  bool isUnitAt2(int i) => i >= 0 && i < cells.length && cells[i].isUnit;

  // ══════════ 剧本加载 ══════════
  void load(List<Map<String, dynamic>> script) {
    this.script = script;
    stepIdx = 0;
    finished = false;
    demoQueue.clear();
    demoReady = false;
    pendingBoard = null;
    boardPending = false;
    _firstBoard = true;
    runStep();
  }

  void runStep() {
    if (stepIdx >= script.length) {
      finished = true;
      notify();
      return;
    }
    currentStep = script[stepIdx];
    final s = currentStep;
    waiting = false;
    waitType = '';
    waitCell = null;
    waitAction = null;
    waitTarget = null;
    choiceOptions = null;
    choiceBranches = null;
    currentSpeaker = null;
    currentText = null;
    stats = {};
    popupOpen = false;
    autoPause = false;

    if (s.containsKey('say')) {
      currentSpeaker = s['say'] as String?;
      currentText = s['text'] as String?;
    } else if (s.containsKey('choice')) {
      choiceOptions = (s['choice'] as List).cast<String>();
      // 宽松类型：单选项的空 branch（[]）也能存（主角留白选项）
      choiceBranches = (s['branch'] as Map).map((k, v) => MapEntry(k as String, v as List));
    } else if (s.containsKey('wait')) {
      // ⚠️ wait 指令可能同时带 highlight key（如 wait select + highlight），
      // 必须放在 highlight 分支前面，否则会被误判成纯高亮步骤、waiting 永远不置位！
      waiting = true;
      waitType = s['wait'] as String;
      waitCell = s['cell'] as int?;
      waitAction = s['action'] as String?;
      waitTarget = s['target'] as int?;
      waitKeep = s['keep'] as int?; // 可选：拆分目标 keep（教学锁定拆法）
      highlightCells = s['highlight'] as List<int>? ?? [];
    } else if (s.containsKey('board')) {
      if (_firstBoard) {
        // 章节首屏：触发退场+入场动画（棋盘出现效果）
        _firstBoard = false;
        pendingBoard = (s['board'] as List).cast<String>();
        boardPending = true;
        notify();
        return;
      }
      // 章节内 board：直接应用棋盘（状态更新，不做全盘重载——牢大：只需要更新状态）
      applyBoard((s['board'] as List).cast<String>());
      stepIdx++;
      runStep();
      return;
    } else if (s.containsKey('highlight')) {
      highlightCells = (s['highlight'] as List).cast<int>();
      arrowFrom = s['arrow'];
      arrowTo = (arrowFrom != null) ? arrowFrom! + dir : null;
    } else if (s.containsKey('stats')) {
      stats = (s['stats'] as Map).cast<String, String>();
    } else if (s.containsKey('auto')) {
      // 演示队列：收集连续 auto 指令，交给 UI 逐格播放（一格一停）
      demoQueue.add(s);
      stepIdx++;
      if (stepIdx < script.length && script[stepIdx].containsKey('auto')) {
        runStep(); // 递归收集下一条 auto（连贯演示）
        return;
      }
      demoReady = true;
      _demoAdvance = true; // auto 指令演示：播完推进
      // 播放完后由 UI 调用 demoDone() 继续
    } else if (s.containsKey('popup')) {
      popupTitle = s['popup'] as String?;
      popupLines = (s['lines'] as List).cast<String>();
      popupOpen = true;
    } else if (s.containsKey('clear')) {
      highlightCells = [];
      arrowFrom = null;
      arrowTo = null;
      selUnit = null;
      selAction = null;
    } else if (s.containsKey('end')) {
      finished = true;
    }
    notify();
  }

  void advance() {
    if (waiting) return; // 等待玩家操作时不能推进
    if (choiceOptions != null) return; // 等待选择
    if (popupOpen) {
      popupOpen = false;
    }
    stepIdx++;
    runStep();
  }

  void dismissPopup() {
    if (popupOpen) {
      popupOpen = false;
      stepIdx++;
      runStep();
    }
  }

  // 演示队列播放完成：继续执行下一条指令（或仅刷新）
  void demoDone() {
    final adv = _demoAdvance;
    _demoAdvance = false;
    demoQueue.clear();
    demoReady = false;
    if (adv) {
      runStep();
    } else {
      notify();
    }
  }

  void chooseOption(String opt) {
    final branch = choiceBranches?[opt];
    if (branch == null || branch.isEmpty) {
      // 空分支（单选项纯推进）：跳过 choice，继续下一句
      choiceOptions = null;
      choiceBranches = null;
      advance();
      return;
    }
    final steps = branch.cast<Map<String, dynamic>>();
    final rest = script.sublist(stepIdx + 1);
    script = [...steps, ...rest];
    stepIdx = 0;
    runStep();
  }

  // ══════════ 棋盘 ══════════
  // 元素思维：与旧棋盘同位置的格子复用 id（内容变化仅改值，id 稳定），
  // 新棋盘多出的格子分配新 id，旧棋盘多出的格子标记删除——UI 据此播转变/插入/删除动画
  void applyBoard(List<String> spec) {
    final old = cells;
    final fresh = spec.map(TutCell.fromSpec).toList();
    final changed = <Map<String, dynamic>>[]; // 同位置内容变化：{idx, from, to}
    final inserted = <int>[]; // 新棋盘多出的格子索引
    final removed = <int>[]; // 旧棋盘多出的格子索引（相对新棋盘）
    for (int k = 0; k < fresh.length; k++) {
      if (k < old.length) {
        final o = old[k];
        final n = fresh[k];
        if (o.v != n.v || o.o != n.o || o.bridge != n.bridge || o.onBridge != n.onBridge || o.auto != n.auto) {
          changed.add({'idx': k, 'from': o.v, 'to': n.v});
        }
        fresh[k] = TutCell.withId(n.v, o.id, o: n.o, bridge: n.bridge, onBridge: n.onBridge, auto: n.auto);
      } else {
        inserted.add(k);
      }
    }
    for (int k = fresh.length; k < old.length; k++) {
      removed.add(k);
    }
    cells = fresh;
    limit = math.max(cells.length, 16);
    selUnit = null;
    selAction = null;
    splitMode = false;
    highlightCells = [];
    if (changed.isNotEmpty || inserted.isNotEmpty || removed.isNotEmpty) {
      boardDiff = {
        'prevCells': old.map((c) => c.copy()).toList(), // 旧棋盘快照（删除动画用）
        'changed': changed,
        'inserted': inserted,
        'removed': removed,
      };
    } else {
      boardDiff = null;
    }
  }

  // UI 播完 board diff 动画后调用：清空标记，避免重复播放
  void clearBoardDiff() {
    boardDiff = null;
  }

  // UI 退场动画完成后调用：应用新棋盘并继续推进剧本
  // ⚠️ 不能把 _firstBoard 重置回 true！_firstBoard 只在 load()（章节加载）时置 true，
  // 章节内后续 board 指令应直接 applyBoard（状态更新），不再触发退场+入场动画。
  // （曾在此处 _firstBoard = true，导致第一章每次加单位都重新展开战场——牢大反馈的 bug）
  void applyPendingBoard() {
    if (!boardPending || pendingBoard == null) return;
    applyBoard(pendingBoard!);
    pendingBoard = null;
    boardPending = false;
    boardDiff = null; // 首屏由展开动画覆盖，不播 diff
    stepIdx++;
    runStep();
  }

  // 跳过：直接跳到本章实操教学（第一个 wait/auto）或章末总结（popup）
  // 跳过中间剧情对话：快进最近一次 board（棋盘状态到位），目标步骤直接开始
  void skipTo(String target) {
    // 清理进行中状态（演示队列/等待/选择/弹窗/待应用棋盘）
    demoQueue.clear();
    demoReady = false;
    _demoAdvance = false;
    pendingBoard = null;
    boardPending = false;
    boardDiff = null;
    lastAction = null;
    waiting = false;
    waitType = '';
    waitCell = null;
    waitAction = null;
    waitTarget = null;
    choiceOptions = null;
    choiceBranches = null;
    autoPause = false;
    selUnit = null;
    selAction = null;
    splitMode = false;
    _firstBoard = false; // 已跳过首屏：后续 board 一律状态更新（不触发退场+入场动画）

    int? idx;
    if (target == 'practice') {
      for (int k = 0; k < script.length; k++) {
        final st = script[k];
        if (st.containsKey('wait') || st.containsKey('auto')) {
          idx = k;
          break;
        }
      }
    } else if (target == 'summary') {
      for (int k = 0; k < script.length; k++) {
        if (script[k].containsKey('popup')) {
          idx = k;
          break;
        }
      }
    }
    if (idx == null) return; // 找不到目标（本章无实操/无总结）就不跳

    // 快进棋盘：应用目标步骤前最近的 board 指令（跳过剧情但棋盘状态到位）
    for (int k = idx - 1; k >= 0; k--) {
      if (script[k].containsKey('board')) {
        applyBoard((script[k]['board'] as List).cast<String>());
        break;
      }
    }
    boardDiff = null; // 快进直接到位，不播 diff 动画

    stepIdx = idx;
    runStep();
  }

  // 移动目标格
  int moveTarget(int i, int steps) => i + dir * steps;

  // 某个我方单位能移动到的格（供 UI 高亮/校验）
  int? unitMoveTarget(int i) {
    final c = cells[i];
    if (!c.isUnit || c.o != 0 || c.auto) return null;
    final v = c.v;
    if (v == 8 || v == 9) return null; // 建筑不可移动
    if (_cavalry.contains(v)) {
      final s1 = i + dir;
      if (s1 < 0 || s1 >= cells.length) return null;
      // 骑兵遇桥：能过桥就继续走（走2格跨过桥到桥后一格）
      if (cells[s1].isB) {
        if (!_bridgeOk.contains(v)) return null;
        final s2 = i + 2 * dir;
        if (s2 < 0 || s2 >= cells.length) return s1; // 桥是尽头：停在桥上
        if (cells[s2].isUnit && !cells[s2].isB) return s1; // 桥后有人：停桥上
        return canStand(s2, v) ? s2 : s1; // 桥后可站：跨过桥；否则停桥上
      }
      if (!canStand(s1, v)) return null;
      final s2 = i + 2 * dir;
      if (s2 < 0 || s2 >= cells.length) return s1;
      if (cells[s2].isUnit && !cells[s2].isB) return s1;
      return canStand(s2, v) ? s2 : s1;
    } else {
      final s1 = i + dir;
      if (s1 < 0 || s1 >= cells.length) return null;
      if (cells[s1].isB) {
        return _bridgeOk.contains(v) ? s1 : null;
      }
      return canStand(s1, v) ? s1 : null;
    }
  }

  bool canStand(int i, int v) {
    if (i < 0 || i >= cells.length) return false;
    final c = cells[i];
    if (c.v == 0 && !c.isB) return true;
    if (c.isB) return _bridgeOk.contains(v);
    return false;
  }

  // ══════════ 玩家交互 ══════════
  // 返回是否消费了操作
  bool tapCell(int i) {
    if (waiting) {
      switch (waitType) {
        case 'select':
          if (waitCell == null || waitCell == i) {
            // 点击我方单位 → 选中
            if (cells[i].isUnit && cells[i].o == 0) {
              selUnit = i;
              waiting = false;
              stepIdx++;
              runStep();
              return true;
            }
            // 基地造兵场景：点基地选中
            if (cells[i].v == 8 && cells[i].o == 0) {
              selUnit = i;
              waiting = false;
              stepIdx++;
              runStep();
              return true;
            }
          }
          return false;
        case 'action':
          // 等待按按钮：点棋盘不处理（防止误点取消选中导致按钮消失）
          return false;
        case 'target':
          if (waitTarget != null && waitTarget != i) return false;
          // 执行当前挂起操作（补上目标格 j）
          final act = _pendingAction;
          if (act != null) {
            _execute({...act, 'j': i});
            _pendingAction = null;
            waiting = false;
            stepIdx++;
            runStep();
            return true;
          }
          return false;
        case 'tap':
          if (waitCell != null && waitCell != i) return false;
          // 造兵场景：第一次点选中基地，第二次点执行造兵（仿游戏：点两下 8）
          if (waitAction == 'produce') {
            if (cells[i].v == 8 && cells[i].o == 0) {
              if (selUnit == null) {
                selUnit = i;
                notify();
                return true; // 第一次：选中
              }
              if (selUnit == i) {
                _execute({'type': 'produce', 'i': i});
                selUnit = null;
                waiting = false;
                stepIdx++;
                runStep();
                return true; // 第二次：造兵
              }
            }
            return false;
          }
          waiting = false;
          stepIdx++;
          runStep();
          return true;
      }
      return false;
    }

    // 非等待：普通点击（选中/执行）
    if (selUnit != null) {
      if (i == selUnit) {
        // 点同一格：基地=造兵（仿游戏），其他=取消选中
        final c = cells[i];
        if (c.v == 8 && c.o == 0) {
          _execute({'type': 'produce', 'i': i});
        }
        selUnit = null;
        selAction = null;
        notify();
        return true;
      }
      // 选目标模式
      if (selAction != null) {
        if (_validTarget(selUnit!, i, selAction!)) {
          _execute({'type': selAction, 'i': selUnit, 'j': i});
          selUnit = null;
          selAction = null;
          notify();
          return true;
        }
        return false;
      }
      // 点移动目标
      final mt = unitMoveTarget(selUnit!);
      if (mt != null && mt == i) {
        final steps = (mt - selUnit!).abs();
        _execute({'type': 'move', 'i': selUnit, 'steps': steps});
        selUnit = null;
        notify();
        return true;
      }
      // 点攻击/吞噬目标
      for (final t in ['attack', 'devour']) {
        if (_validTarget(selUnit!, i, t)) {
          _execute({'type': t, 'i': selUnit, 'j': i});
          selUnit = null;
          notify();
          return true;
        }
      }
      selUnit = null;
      notify();
      return true;
    }
    if (cells[i].isUnit && cells[i].o == 0 && !cells[i].auto) {
      selUnit = i;
      notify();
      return true;
    }
    return false;
  }

  // 操作按钮
  bool tapButton(String action) {
    if (waiting && waitType == 'action') {
      if (waitAction != null && waitAction != action) return false;
      if (selUnit == null) {
        // 有些场景 wait action 时已选中（如造兵需先点基地）
        if (waitCell != null) selUnit = waitCell;
      }
      waiting = false;
      _pendingAction = {'type': action, 'i': selUnit};
      // produce 直接执行；其他需要选目标
      if (action == 'produce') {
        _execute(_pendingAction!);
        _pendingAction = null;
        selUnit = null;
        stepIdx++;
        runStep();
      } else if (action == 'move') {
        final mt = selUnit != null ? unitMoveTarget(selUnit!) : null;
        if (mt != null) {
          // 逐格动画：加入演示队列，由 UI 一格一格播放（不瞬移）
          final steps = (mt - selUnit!).abs();
          demoQueue.add({'auto': 'move', 'i': selUnit, 'steps': steps, 'owner': 0});
          _pendingAction = null;
          selUnit = null;
          stepIdx++;
          demoReady = true;
          _demoAdvance = true; // wait 操作移动：播完推进下一条
          notify();
        }
      } else if (action == 'split') {
        // 拆分：进入拆分面板，waiting 保持 true，确认后推进
        splitMode = true;
        // 教学锁定拆法：waitKeep 优先；否则默认拆出轻骑兵（5→3+2）
        if (waitKeep != null) {
          splitKeep = waitKeep;
        } else {
          final sv = (selUnit ?? waitCell) != null && (selUnit ?? waitCell)! < cells.length
              ? cells[(selUnit ?? waitCell)!].v
              : 5;
          splitKeep = sv >= 5 ? (sv - 2).clamp(1, sv - 1) : 1;
        }
        selUnit = selUnit ?? waitCell;
        notify(); // 必须通知 UI 刷新，否则拆分面板不出现/不更新
        return true;
      } else if (action == 'devour') {
        // 吞噬：只作用于前方一格，目标唯一 → 点按钮直接执行，无需选目标
        final u = selUnit ?? waitCell;
        if (u != null && u >= 0 && u < cells.length) {
          final j = u + dir;
          if (j >= 0 && j < cells.length && cells[j].isUnit && cells[j].v <= cells[u].v) {
            _execute({'type': 'devour', 'i': u, 'j': j});
          }
        }
        _pendingAction = null;
        selUnit = null;
        stepIdx++;
        runStep();
      } else {
        // attack：进入选目标模式（射程内可能多目标）
        selAction = action;
        stepIdx++;
        runStep(); // 下一指令应为 wait target
      }
      return true;
    }
    // 普通按钮
    if (selUnit == null) return false;
    switch (action) {
      case 'move':
        final mt = unitMoveTarget(selUnit!);
        if (mt != null) {
          // 逐格动画：加入演示队列，由 UI 一格一格播放（不瞬移）
          final steps = (mt - selUnit!).abs();
          demoQueue.add({'auto': 'move', 'i': selUnit, 'steps': steps, 'owner': 0});
          selUnit = null;
          demoReady = true;
          _demoAdvance = false; // 普通模式移动：只播动画不推进脚本
          notify();
        }
        break;
      case 'attack':
        selAction = action;
        notify();
        break;
      case 'devour':
        // 吞噬目标唯一（前方一格），直接执行
        if (selUnit != null && selUnit! >= 0 && selUnit! < cells.length) {
          final j = selUnit! + dir;
          if (j >= 0 && j < cells.length && cells[j].isUnit && cells[j].v <= cells[selUnit!].v) {
            _execute({'type': 'devour', 'i': selUnit, 'j': j});
          }
        }
        selUnit = null;
        notify();
        break;
      case 'split':
        splitMode = true;
        splitKeep = 1;
        selUnit = null;
        notify();
        break;
      case 'produce':
        if (selUnit != null && cells[selUnit!].v == 8) {
          _execute({'type': 'produce', 'i': selUnit});
          selUnit = null;
          notify();
        }
        break;
    }
    return true;
  }

  void confirmSplit() {
    if (!splitMode) return;
    final i = _splitUnit ?? selUnit;
    if (i != null) {
      _execute({'type': 'split', 'i': i, 'keep': splitKeep ?? 1});
    }
    splitMode = false;
    selUnit = null;
    if (waiting && waitType == 'action' && waitAction == 'split') {
      waiting = false;
      stepIdx++;
      runStep();
    } else {
      notify();
    }
  }

  void cancelSplit() {
    splitMode = false;
    notify();
  }

  // 拆分目标单位（当前选中或等待中的单位）
  int? get _splitUnit {
    if (waiting && waitCell != null) return waitCell;
    return selUnit;
  }

  // 公开版（供 UI 用）
  int? get splitUnitIdx {
    if (waiting && waitCell != null) return waitCell;
    return selUnit;
  }

  Map<String, dynamic>? _pendingAction;

  // ══════════ 迷你规则 ══════════
  // 与对战端一致：操作前记录旧棋盘快照（prevCells），UI 基于旧棋盘演动画
  // （否则 UI 拿操作后的 cells 当基底，插桥/删格会重复/错位）
  void _execute(Map<String, dynamic> a) {
    final prev = cells.map((c) => c.copy()).toList();
    switch (a['type']) {
      case 'move':
        doMove(a['i'] as int, (a['steps'] as int?) ?? 1);
        break;
      case 'attack':
        doAttack(a['i'] as int, a['j'] as int);
        break;
      case 'devour':
        doDevour(a['i'] as int, a['j'] as int);
        break;
      case 'split':
        doSplit(a['i'] as int, a['keep'] as int);
        break;
      case 'produce':
        doProduce(a['i'] as int);
        break;
      case 'roll':
        autoRoll((a['owner'] as int?) ?? 1);
        break;
    }
    if (lastAction != null) {
      lastAction!['prevCells'] = prev;
    }
  }

  void doMove(int i, int steps, {int owner = 0}) {
    final c = cells[i];
    if (!c.isUnit) return;
    final v = c.v;
    // 方向按归属方：我方朝右(+1)，敌方朝左(-1)
    final d = owner == 0 ? dir : enemyDir;
    final startBridge = c.onBridge || c.isB;
    // 重单位走桥：桥塌人亡
    for (int k = 1; k <= steps; k++) {
      final p = i + d * k;
      if (p < 0 || p >= cells.length) return;
      if (cells[p].isB && !_bridgeOk.contains(v)) {
        cells.removeAt(p);
        final ui = cells.indexOf(c);
        if (ui >= 0) cells.removeAt(ui);
        lastSeq++;
        lastAction = {'type': 'move', 'i': i, 'steps': steps, 'bridgeCollapse': p, 'owner': owner};
        return;
      }
      if (!canStand(p, v)) return;
    }
    final target = i + d * steps;
    if (target < 0 || target >= cells.length) return;
    if (cells[target].isB) {
      cells[target] = TutCell(v, o: c.o, onBridge: true, auto: c.auto);
    } else {
      cells[target] = c;
    }
    if (startBridge) {
      cells[i] = v == 1 ? TutCell(0) : TutCell(0, bridge: true);
      if (v == 1) _log('小兵拆掉了独木桥');
    } else {
      cells[i] = TutCell(0);
    }
    _log('单位$v前进$steps格');
    lastSeq++;
    lastAction = {'type': 'move', 'i': i, 'steps': steps, 'bridgeCollapse': null, 'owner': owner};
  }

  void doAttack(int i, int j) {
    if (i < 0 || j < 0 || i >= cells.length || j >= cells.length) return;
    final att = cells[i];
    final t = cells[j];
    if (!att.isUnit || !t.isUnit) return;
    final dmg = _range.containsKey(att.v) ? 1 : att.v;
    final oldV = t.v; // 操作前值（供转变动画）
    t.v -= dmg;
    var overflowed = false; // 溢出（伤害超过生命）
    if (t.v == 0) {
      if (t.onBridge) {
        cells[j] = TutCell(0, bridge: true);
      } else {
        t.o = null;
      }
    } else if (t.v < 0) {
      overflowed = true; // ⚠️ 必须先记录再转正，否则后面判断永远 false
      t.v = -t.v;
      if (cells.length < limit) {
        cells.insert(j, TutCell(0, bridge: true));
        _log('伤害溢出：${att.v}攻击，砸出独木桥');
      }
    }
    if (t.v != 6) t.auto = false;
    _log('${att.v}攻击${j}，造成$dmg伤害');
    lastSeq++;
    // 插桥：溢出时在 j 位置插入桥，目标右移
    final ins = (overflowed && cells.length < limit) ? j : null;
    final tj = ins != null ? j + 1 : j;
    final newV = tj < cells.length ? cells[tj].v : 0;
    lastAction = {'type': 'attack', 'i': i, 'j': j, 'old': oldV, 'newV': newV, 'insertedAt': ins, 'owner': 0};
  }

  void doDevour(int i, int j) {
    if (i < 0 || j < 0 || i >= cells.length || j >= cells.length) return;
    final me = cells[i];
    final t = cells[j];
    if (!me.isUnit || !t.isUnit || t.v > me.v) return;
    final oldI = me.v; // 操作前值（供转变动画）
    final oldJ = t.v;
    final sum = me.v + t.v;
    if (sum <= 9) {
      me.v = sum;
      cells.removeAt(j);
      _log('吞噬：${sum - t.v}+${t.v}=$sum');
    } else {
      me.v = sum ~/ 10;
      final ones = sum % 10;
      cells[j] = TutCell(ones, o: ones == 0 ? null : me.o);
      _log('吞噬超9：$sum → ${me.v}+$ones');
    }
    var collapsed = false;
    if (me.onBridge && me.v >= 5) {
      final idx = cells.indexOf(me);
      if (idx >= 0) cells[idx] = TutCell(0);
      _log('桥上吞噬后${me.v}≥5：桥毁人亡');
      collapsed = true;
    }
    lastSeq++;
    lastAction = {
      'type': 'devour', 'i': i, 'j': j, 'sum': sum,
      'oldI': oldI, 'oldJ': oldJ,
      'spliced': sum <= 9, 'collapsed': collapsed, 'owner': 0,
    };
  }

  void doSplit(int i, int keep) {
    if (i < 0 || i >= cells.length) return;
    final c = cells[i];
    if (!c.isUnit || c.v < 5) return;
    if (keep < 1 || keep >= c.v) return;
    final oldV = c.v; // 操作前值
    final other = c.v - keep;
    final v = c.v;
    if (cells.length >= limit) {
      c.v = keep;
      _log('满员拆分：只保留$keep');
      lastSeq++;
      lastAction = {'type': 'split', 'i': i, 'keep': keep, 'other': other, 'full': true, 'owner': 0};
      return;
    }
    cells.insert(i + 1, TutCell(other, o: c.o));
    c.v = keep;
    _log('拆分$v → $keep+$other');
    lastSeq++;
    lastAction = {'type': 'split', 'i': i, 'keep': keep, 'other': other, 'old': oldV, 'full': false, 'owner': 0};
  }

  void doProduce(int i) {
    if (i < 0 || i >= cells.length) return;
    final base = cells[i];
    if (base.v != 8 || base.o != 0) return;
    final j = i + dir;
    if (j < 0 || j >= cells.length) return;
    final t = cells[j];
    if (t.isB) return;
    if (t.isUnit && t.o != 0) {
      t.v -= 1;
      if (t.v == 0) {
        t.o = null;
      } else if (t.v < 0) {
        t.v = -t.v;
      }
      _log('造兵攻击：敌方单位-1');
      lastSeq++;
      lastAction = {'type': 'produce', 'j': j, 'attacked': true, 'owner': 0};
    } else {
      t.v += 1;
      t.o = 0;
      _log('造兵：基地前${t.v - 1} → ${t.v}');
      lastSeq++;
      lastAction = {'type': 'produce', 'j': j, 'attacked': false, 'newV': t.v, 'owner': 0};
    }
  }

  // 在 [i] 格施加 [dmg] 伤害（对齐游戏 rules.applyDamage）：
  // 返回 {insertedAt: int?}（溢出插桥位置；插桥后单位被顶到桥右）
  Map<String, dynamic> _applyDamageAt(int i, int dmg) {
    final c = cells[i];
    if (!c.isUnit || c.v == 0) return {'insertedAt': null};
    c.v -= dmg;
    if (c.v != 6) c.auto = false;
    if (c.v > 0) return {'insertedAt': null};
    if (c.v == 0) {
      if (c.onBridge) {
        cells[i] = TutCell(0, bridge: true);
      } else {
        c.v = 0;
        c.o = null;
      }
      return {'insertedAt': null};
    }
    // 溢出：数字变绝对值，桥插在单位位置（单位被顶到桥右 idx+1）
    c.v = -c.v;
    if (c.v != 6) c.auto = false;
    if (cells.length < limit) {
      cells.insert(i, TutCell(0, bridge: true));
      return {'insertedAt': i};
    }
    return {'insertedAt': null};
  }

  // 滚木自动滚动（owner: 滚木归属方）——对齐游戏 rules._rollOneStep 语义：
  // 每步先露出脚下压着的单位（滚木走开），再往前看：
  //   撞桥/建筑/越界 → 死；第三格 → 抹杀；第一二格 → 压6伤
  //   （溢出插桥：滚木站到桥右压着被顶单位，下一步走开露出——不是跳过两格）
  // UI 逐格调用（step=1..3），step==1 表示新一轮滚动开始（清空已碾压记录）
  void rollStep(int owner, int step) {
    if (step == 1) _rolledIds.clear();
    lastRollSteps = [];
    final d = owner == 0 ? dir : enemyDir;
    final rollers = <TutCell>[];
    for (final c in cells) {
      if (c.isUnit && c.o == owner && c.v == 6 && !rollers.contains(c)) rollers.add(c);
    }
    for (final roller in rollers) {
      var pos = cells.indexOf(roller);
      if (pos < 0) continue;
      // 1) 滚木走开：露出脚下压着的单位（对齐游戏 _unpress）
      if (roller.pressedV != null && roller.pressedV! > 0) {
        cells[pos] = TutCell(roller.pressedV!, o: roller.pressedO, auto: roller.pressedV == 6);
      } else if (cells[pos].isB || cells[pos].onBridge) {
        cells[pos] = TutCell(0, bridge: true);
      } else {
        cells[pos] = TutCell(0);
      }
      roller.pressedV = null;
      roller.pressedO = null;
      final p = pos + d;
      if (p < 0 || p >= cells.length) {
        // 滚出地图
        lastRollSteps.add({'dead': true});
        _log('滚木滚出地图');
        continue;
      }
      final t = cells[p];
      if (t.isB) {
        // 撞桥：桥塌，滚木消失
        lastRollSteps.add({'dead': true, 'bridgeCollapse': true});
        cells.removeAt(p);
        _log('滚木砸塌独木桥');
        continue;
      }
      if (t.v == 8 || t.v == 9) {
        // 撞建筑：滚木消失
        lastRollSteps.add({'dead': true, 'building': true});
        _log('滚木撞上建筑消失');
        continue;
      }
      if (t.isUnit) {
        if (_rolledIds.contains(t.id)) {
          // 已被本滚木碾压过（溢出被顶开）：滚木站上去压着，不再碾
          lastRollSteps.add({'crush': false});
          cells[p] = roller;
          roller.pressedV = t.v;
          roller.pressedO = t.o;
          roller.auto = true;
          continue;
        }
        _rolledIds.add(t.id);
        if (step == 3) {
          // 第三格：抹杀（单位死，滚木停在目标格）
          lastRollSteps.add({'crush': true, 'kill': true, 'owner': t.o, 'oldV': t.v});
          cells[p] = roller;
          roller.auto = true;
          _log('滚木抹杀${t.v}');
          continue;
        }
        // 第一、二格：压到单位，受6伤
        final oldV = t.v;
        final r = _applyDamageAt(p, 6);
        final newV = t.v; // 单位新值（_applyDamageAt 直接改 t：溢出后 t 被顶到 p+1，值已转正）
        if (r['insertedAt'] != null) {
          // 溢出插桥：桥插单位位置（splice），变值单位被顶到桥右（p+1），滚木站到桥右压着它
          lastRollSteps.add({'crush': true, 'owner': t.o, 'oldV': oldV, 'newV': newV, 'bridge': true});
          lastRollSteps.add({'bump': true});
          final stand = p + 1;
          if (stand >= 0 && stand < cells.length) {
            cells[stand] = roller;
            roller.pressedV = newV;
            roller.pressedO = t.o;
            roller.auto = true;
            _log('滚木碾过：$oldV受6伤，砸出独木桥');
          } else {
            lastRollSteps.add({'dead': true});
            _log('滚木被顶出地图');
          }
        } else {
          // 非溢出：单位原地变值，滚木站到单位上压着（棋盘显示滚木）
          lastRollSteps.add({'crush': true, 'owner': t.o, 'oldV': oldV, 'newV': newV, 'bridge': false});
          cells[p] = roller;
          roller.pressedV = newV;
          roller.pressedO = t.o;
          roller.auto = true;
          _log('滚木碾过：$oldV受6伤');
        }
      } else {
        // 空地：滚木前进一格
        cells[p] = roller;
        roller.auto = true;
        lastRollSteps.add({'crush': false});
      }
    }
  }

  // 一次滚完三步（对齐游戏 autoRoll = 循环 rollStepOnce）
  void autoRoll(int owner) {
    for (int k = 1; k <= 3; k++) {
      rollStep(owner, k);
    }
  }

  // 演示：所有兵朝右走并消失（终章）
  void walkOff(int owner) {
    for (int pass = 0; pass < cells.length; pass++) {
      for (int i = 0; i < cells.length; i++) {
        final c = cells[i];
        if (c.isUnit && c.o == owner) {
          cells[i] = TutCell(0);
        }
      }
    }
  }

  // 终章列队离场：每步所有我方单位右移一格；走到最右边界（超出地图）消失
  // 由 UI 逐格调用；返回 true 表示还有单位在场（继续走）
  bool walkStep(int owner) {
    final d = dir; // 我方朝右
    final units = <TutCell>[];
    for (final c in cells) {
      if (c.isUnit && c.o == owner && !units.contains(c)) units.add(c);
    }
    if (units.isEmpty) return false;
    for (final u in units) {
      var pos = cells.indexOf(u);
      if (pos < 0) continue;
      final p = pos + d;
      if (p >= cells.length) {
        // 走出地图 → 消失
        cells[pos] = TutCell(0);
      } else if (!cells[p].isUnit) {
        cells[p] = u;
        cells[pos] = TutCell(0);
      }
    }
    return cells.any((c) => c.isUnit && c.o == owner);
  }

  // 校验：selUnit 是否可对 j 执行 t
  bool _validTarget(int i, int j, String t) {
    if (i < 0 || j < 0 || i >= cells.length || j >= cells.length) return false;
    final c = cells[i];
    if (!c.isUnit || c.o != 0 || c.auto) return false;
    if (t == 'attack') {
      if (!cells[j].isUnit) return false;
      final r = _range[c.v] ?? 1;
      return (j - i).abs() <= r && (j - i) * dir > 0;
    }
    if (t == 'devour') {
      return j == i + dir && cells[j].isUnit && cells[j].v <= c.v;
    }
    return false;
  }

  void runAuto(Map<String, dynamic> s) {
    final type = s['auto'] as String;
    final owner = (s['owner'] as int?) ?? 0;
    final prev = cells.map((c) => c.copy()).toList(); // 与 _execute 一致：操作前快照
    switch (type) {
      case 'produce':
        doProduce(s['i'] as int);
        break;
      case 'move':
        doMove(s['i'] as int, (s['steps'] as int?) ?? 1, owner: owner);
        break;
      case 'attack':
        doAttack(s['i'] as int, s['j'] as int);
        break;
      case 'devour':
        doDevour(s['i'] as int, s['j'] as int);
        break;
      case 'split':
        doSplit(s['i'] as int, s['keep'] as int);
        break;
      case 'roll':
        autoRoll(owner);
        break;
      case 'walk':
        walkOff(owner);
        break;
    }
    if (lastAction != null) {
      lastAction!['prevCells'] = prev;
    }
  }

  // 可执行操作列表（供按钮区显示，仿游戏：建筑只有拆分，无造兵按钮）
  List<String> availableActions(int i) {
    if (i < 0 || i >= cells.length) return [];
    final c = cells[i];
    if (!c.isUnit || c.o != 0 || c.auto) return [];
    final acts = <String>[];
    // 建筑 8/9：不可移动/攻击/吞噬，只能拆分
    if (c.v == 8 || c.v == 9) {
      if (c.v >= 5) acts.add('split');
      return acts;
    }
    final mt = unitMoveTarget(i);
    if (mt != null) acts.add('move');
    final r = _range[c.v] ?? 1;
    for (int k = 1; k <= r; k++) {
      final j = i + dir * k;
      if (j >= 0 && j < cells.length && cells[j].isUnit) {
        acts.add('attack');
        break;
      }
    }
    final j = i + dir;
    if (j >= 0 && j < cells.length && cells[j].isUnit && cells[j].v <= c.v) {
      acts.add('devour');
    }
    if (c.v >= 5) acts.add('split');
    return acts;
  }
}

// 简易通知包装（避免依赖 flutter 的 ChangeNotifier 于引擎层）
abstract class ChangeNotifierWrapper {
  final List<void Function()> _listeners = [];
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}
