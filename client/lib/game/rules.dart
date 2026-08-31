// AIM 数字大战 — 规则引擎（Dart 本地版）
// 与 server/src/game/rules.js 逐行对应移植，供热座/局域网主机使用
// 纯逻辑无 IO；输出 lastAction/rollSteps 与联机服务端同格式，客户端动画通用

// ── 常量 ──
const List<int> kDir = [1, -1]; // 玩家0朝右(+1)，玩家1朝左(-1)
const Map<int, int> kRange = {3: 2, 4: 3}; // 3弓手射程2，4炮手射程3，其余1
const Set<int> kCavalry = {2, 5}; // 骑兵
const Set<int> kBridgeOk = {1, 2, 3}; // 能过桥的轻单位（4炮手改重装，不可过桥）
const int kSplitMin = 5; // 可拆分的最小值

class AimCell {
  int v; // 0=空地, 1..9
  int? o; // 0=玩家0 1=玩家1 null=无人
  bool bridge;
  bool onBridge;
  bool auto; // 滚木已激活
  int id; // 稳定身份（移动/合并 id 跟随，删除消失）
  // 滚木脚下压着的单位（滚木压在单位上时，棋盘只显示滚木，走开才露出）
  int? pressedV;
  int? pressedO;

  AimCell(this.v, {this.o, this.bridge = false, this.onBridge = false, this.auto = false})
      : id = AimGame.nextCellId();

  bool get isB => bridge;
  bool get isUnit => !bridge && v >= 1;

  Map<String, dynamic> toMap() => {
        'v': v,
        'o': o,
        'bridge': bridge,
        'onBridge': onBridge,
        'auto': auto,
        'id': id,
        'pressedV': pressedV,
        'pressedO': pressedO,
      };

  /// 深拷贝（保持 id 稳定，供前瞻模拟克隆棋盘用）
  AimCell clone() {
    final c = AimCell(v, o: o, bridge: bridge, onBridge: onBridge, auto: auto);
    c.id = id;
    c.pressedV = pressedV;
    c.pressedO = pressedO;
    return c;
  }

  static AimCell fromMap(Map<String, dynamic> m) {
    final c = AimCell(
      (m['v'] as num?)?.toInt() ?? 0,
      o: (m['o'] as num?)?.toInt(),
      bridge: m['bridge'] == true,
      onBridge: m['onBridge'] == true,
      auto: m['auto'] == true,
    );
    c.pressedV = (m['pressedV'] as num?)?.toInt();
    c.pressedO = (m['pressedO'] as num?)?.toInt();
    return c;
  }
}

class AimGame {
  static int _cellId = 1;
  static int nextCellId() => _cellId++;

  late List<AimCell> cells;
  late int limit;
  final bool allowOwnRollerAttack; // 规则开关：己方能否攻击己方滚木（默认可，保持「敌我皆可」）
  int turn = 0;
  String? phase; // 'action' | 'produce' | null
  int points = 0;
  int produceLeft = 0;
  int? winner;
  List<String> log = [];
  Map<String, dynamic>? lastAction;
  int lastSeq = 0;
  int rollSeq = 0;
  List<Map<String, dynamic>>? rollSteps;

  // ── 对局统计（结算页用）──
  Map<String, dynamic> stats = {
    'kills': [0, 0], // 每方击杀（攻击/吞噬/造兵攻击致死）
    'losses': [0, 0], // 每方损失（含滚木碾死）
    'produce': [0, 0], // 每方造兵数
  };
  int turnCount = 0; // 已过回合数

  // ── 重复操作判负（象棋式「三次重复」，牢大定）──
  // 指纹 = 玩家 | 操作签名 | 操作后棋盘快照；同一指纹第 3 次出现 → 制造循环者判负
  Map<String, int> _opHistory = {};
  bool _lastOpRepeatWarn = false; // 本次操作是否触发了第 2 次重复警告（applyAction 返回给 UI）

  List<int> _statsList(String key) => (stats[key] as List).cast<int>();

  AimGame({int limit = 16, this.allowOwnRollerAttack = true}) {
    this.limit = limit;
    final init = limit ~/ 2;
    cells = List.generate(init, (_) => AimCell(0));
    cells[0] = AimCell(8, o: 0); // 玩家0基地（左端）
    cells[init - 1] = AimCell(8, o: 1); // 玩家1基地（右端）
  }

  /// 深拷贝（前瞻模拟用）：克隆全部可变状态，滚木引用按 id 重新映射
  AimGame clone() {
    final g = AimGame(limit: limit, allowOwnRollerAttack: allowOwnRollerAttack);
    g.cells = cells.map((c) => c.clone()).toList();
    g.turn = turn;
    g.phase = phase;
    g.points = points;
    g.produceLeft = produceLeft;
    g.winner = winner;
    g.log = List.of(log);
    g.lastAction = lastAction == null ? null : Map<String, dynamic>.of(lastAction!);
    g.lastSeq = lastSeq;
    g.rollSeq = rollSeq;
    g.rollSteps = rollSteps == null
        ? null
        : rollSteps!.map((m) => Map<String, dynamic>.of(m)).toList();
    g.stats = {
      'kills': List<int>.of((stats['kills'] as List).cast<int>()),
      'losses': List<int>.of((stats['losses'] as List).cast<int>()),
      'produce': List<int>.of((stats['produce'] as List).cast<int>()),
    };
    g.turnCount = turnCount;
    g._opHistory = Map<String, int>.of(_opHistory);
    g._lastOpRepeatWarn = _lastOpRepeatWarn;
    // 滚木逐步状态（引用按 id 映射到克隆后的新 cells）
    g._rsOwner = _rsOwner;
    g._rsRollers = _rsRollers
        ?.map((c) => cells.firstWhere((x) => x.id == c.id, orElse: () => c))
        .toList();
    g._rsIdx = _rsIdx;
    g._rsPos = _rsPos;
    g._rsStep = _rsStep;
    g._rsRolled.addAll(_rsRolled);
    g._rsDone.addAll(_rsDone);
    g._rsActive = _rsActive;
    g._rsLogs.addAll(_rsLogs);
    g._rsSteps.addAll(_rsSteps.map((m) => Map<String, dynamic>.of(m)));
    g._lastRollActs = _lastRollActs == null
        ? null
        : _lastRollActs!.map((m) => Map<String, dynamic>.of(m)).toList();
    g._rollStepSeq = _rollStepSeq;
    g._pendingRoll = _pendingRoll;
    return g;
  }

  int dirOf(int owner) => kDir[owner];

  bool isBridge(AimCell? c) => c != null && c.bridge;
  bool isUnit(AimCell? c) => c != null && !c.bridge && c.v >= 1;
  bool isOwnedUnit(AimCell? c, int owner) => isUnit(c) && c!.o == owner;

  int sumOf(int owner) {
    var s = 0;
    for (final c in cells) {
      if (isOwnedUnit(c, owner)) s += c.v;
      // 滚木脚下压着的单位也算（棋盘不显示，但数值参与胜利判定）
      if (c.v == 6 && c.pressedV != null && c.pressedO == owner) s += c.pressedV!;
    }
    return s;
  }
  int countOf(int owner, int v) => cells.where((c) => isOwnedUnit(c, owner) && c.v == v).length;

  // ── 伤害 ──
  // 返回 {insertedAt: int?}（插桥位置）；byOwner 非空时记录击杀（攻击/吞噬/造兵攻击）
  Map<String, dynamic> applyDamage(int idx, int dmg, {int? byOwner}) {
    final c = cells[idx];
    if (!isUnit(c) || c.v == 0) return {'insertedAt': null};
    final killedOwner = c.o;
    c.v -= dmg;
    if (c.v != 6) c.auto = false;
    if (c.v > 0) return {'insertedAt': null};
    if (c.v == 0) {
      // 阵亡
      if (killedOwner != null) {
        _statsList('losses')[killedOwner]++;
        if (byOwner != null) _statsList('kills')[byOwner]++;
      }
      if (c.onBridge) {
        cells[idx] = AimCell(0, bridge: true);
      } else {
        c.v = 0;
        c.o = null;
      }
      return {'insertedAt': null};
    }
    // 溢出：数字变绝对值，桥插在单位位置
    c.v = -c.v;
    if (c.v != 6) c.auto = false;
    if (cells.length < limit) {
      // 2026-08-19 修复：单位被新桥挤到 idx+1，onBridge 标志按新位置脚下重新判定——
      // 否则残留 onBridge=true，单位走开时原地凭空造桥（幽灵格子/多桥）
      final nextIsBridge = (idx + 1 < cells.length) && cells[idx + 1].bridge;
      cells.insert(idx, AimCell(0, bridge: true));
      c.onBridge = nextIsBridge;
      return {'insertedAt': idx};
    }
    return {'insertedAt': null};
  }

  // ── 合法性 ──
  bool canPass(int idx, int owner) {
    if (idx < 0 || idx >= cells.length) return false;
    final c = cells[idx];
    if (isBridge(c)) return kBridgeOk.contains(c.v);
    if (c.v == 0) return true;
    return false;
  }

  bool canStand(int idx, int unitV) {
    if (idx < 0 || idx >= cells.length) return false;
    final c = cells[idx];
    if (c.v == 0 && !c.bridge) return true;
    if (isBridge(c)) return kBridgeOk.contains(unitV);
    return false;
  }

  // ── 合法行动 ──
  List<Map<String, dynamic>> getLegalActions(int owner) {
    if (winner != null || turn != owner) return [];
    final acts = <Map<String, dynamic>>[];
    final dir = dirOf(owner);
    if (phase == null) {
      final out = <Map<String, dynamic>>[
        {'type': 'choosePhase', 'phase': 'action'},
        {'type': 'choosePhase', 'phase': 'produce'},
      ];
      final tmpPoints = countOf(owner, 9) + 1;
      if (tmpPoints > 0) {
        genUnitActions(owner, acts);
        out.addAll(acts);
      }
      return out;
    }
    if (phase == 'produce') {
      if (produceLeft <= 0) return [{'type': 'endTurn'}];
      for (int i = 0; i < cells.length; i++) {
        final c = cells[i];
        if (!isOwnedUnit(c, owner) || c.v != 8) continue;
        final j = i + dir;
        if (j < 0 || j >= cells.length) continue;
        if (isBridge(cells[j])) continue;
        acts.add({'type': 'produce', 'i': i, 'j': j});
      }
      return acts;
    }
    if (points <= 0) return [{'type': 'endTurn'}];
    genUnitActions(owner, acts);
    return acts;
  }

  void genUnitActions(int owner, List<Map<String, dynamic>> acts) {
    final dir = dirOf(owner);
    for (int i = 0; i < cells.length; i++) {
      final c = cells[i];
      if (!isOwnedUnit(c, owner)) continue;
      final v = c.v;
      if (v == 6 && c.auto) continue;
      if (v == 8 || v == 9) {
        for (int keep = 1; keep < v; keep++) {
          acts.add({'type': 'split', 'i': i, 'keep': keep, 'a': keep, 'b': v - keep});
        }
        continue;
      }
      // 移动
      if (kCavalry.contains(v)) {
        final s1 = i + dir, s2 = i + 2 * dir;
        if (s1 >= 0 && s1 < cells.length && isBridge(cells[s1])) {
          if (kBridgeOk.contains(v)) acts.add({'type': 'move', 'i': i, 'steps': 1});
          else acts.add({'type': 'move', 'i': i, 'steps': 1, 'fatal': true});
        } else if (canStand(s1, v)) {
          if (s2 >= 0 && s2 < cells.length && isUnit(cells[s2]) && !isBridge(cells[s2])) {
            acts.add({'type': 'move', 'i': i, 'steps': 1});
          } else if (s2 >= 0 && s2 < cells.length && isBridge(cells[s2]) && !kBridgeOk.contains(v)) {
            acts.add({'type': 'move', 'i': i, 'steps': 2, 'fatal': true});
          } else if (canStand(s2, v)) {
            acts.add({'type': 'move', 'i': i, 'steps': 2});
          }
        }
      } else {
        final s1 = i + dir;
        if (s1 >= 0 && s1 < cells.length && isBridge(cells[s1])) {
          if (kBridgeOk.contains(v)) acts.add({'type': 'move', 'i': i, 'steps': 1});
          else if (v == 5 || v == 7 || v == 4) acts.add({'type': 'move', 'i': i, 'steps': 1, 'fatal': true});
        } else if (canStand(s1, v)) {
          acts.add({'type': 'move', 'i': i, 'steps': 1});
        }
      }
      // 攻击（敌我皆可，但规则开关可禁止己方攻击己方滚木）
      final r = kRange[v] ?? 1;
      for (int k = 1; k <= r; k++) {
        final j = i + dir * k;
        if (j < 0 || j >= cells.length) break;
        if (!isUnit(cells[j])) continue;
        if (!allowOwnRollerAttack && cells[j].v == 6 && cells[j].o == owner) continue;
        acts.add({'type': 'attack', 'i': i, 'j': j});
      }
      // 拆分
      if (v >= kSplitMin) {
        for (int keep = 1; keep < v; keep++) {
          acts.add({'type': 'split', 'i': i, 'keep': keep, 'a': keep, 'b': v - keep});
        }
      }
      // 吞噬
      final j = i + dir;
      if (j >= 0 && j < cells.length && isUnit(cells[j]) && cells[j].v <= v) {
        acts.add({'type': 'devour', 'i': i, 'j': j});
      }
    }
  }

  // ── 执行 ──
  bool doMove(int owner, int i, int steps) {
    final dir = dirOf(owner);
    final unit = cells[i];
    if (unit.auto && unit.v == 6) return false; // 只有激活滚木不可操控（滚木滚出来的非6单位可正常行动）
    final v = unit.v;
    final path = <int>[];
    for (int k = 1; k <= steps; k++) {
      path.add(i + dir * k);
    }
    for (final p in path) {
      if (p < 0 || p >= cells.length) return false;
      if (isBridge(cells[p]) && !kBridgeOk.contains(v)) {
        // 桥塌人亡（牢大 2026-08-19）：单位原地变空（不是删格），桥格删除——
        // 棋盘只少 1 格（850-128 中 5 走两步 → 800128），旧实现删 2 格变 80128
        final ui = cells.indexOf(unit);
        if (ui >= 0) cells[ui] = AimCell(0);
        cells.removeAt(p);
        log.add('单位$v走桥：桥塌人亡');
        lastSeq++;
        lastAction = {'type': 'move', 'i': i, 'steps': steps, 'bridgeCollapse': p, 'owner': owner};
        return true;
      }
      if (!canStand(p, v)) return false;
    }
    final target = path[path.length - 1];
    final startIsBridge = cells[i].onBridge || isBridge(cells[i]);
    if (isBridge(cells[target])) {
      cells[target] = AimCell(v, o: owner, onBridge: true);
    } else {
      // 目标不是桥：单位已离开桥，清掉残留的 onBridge，避免离桥后仍被判“在桥上”
      // （否则桥正前方吞噬>=5 会误触发桥毁人亡）
      cells[target] = cells[i];
      cells[target].onBridge = false;
    }
    if (startIsBridge) {
      cells[i] = v == 1 ? AimCell(0) : AimCell(0, bridge: true);
      if (v == 1) log.add('小兵拆掉了独木桥');
    } else {
      cells[i] = AimCell(0);
    }
    lastSeq++;
    lastAction = {'type': 'move', 'i': i, 'steps': steps, 'bridgeCollapse': null, 'owner': owner};
    return true;
  }

  // 盾兵屏障：目标本身是7，或目标朝敌方方向有己方盾兵7挡在箭路上
  bool isShieldCovered(int j, int i, AimCell t) {
    final defDir = kDir[t.o!];
    for (int k = j; k != i; k += defDir) {
      if (k < 0 || k >= cells.length) break;
      final c = cells[k];
      if (isOwnedUnit(c, t.o!) && c.v == 7) return true;
    }
    return false;
  }

  bool doAttack(int owner, int i, int j) {
    final att = cells[i];
    if (att.auto && att.v == 6) return false;
    final dmg = kRange[att.v] != null ? 1 : att.v; // 3、4恒1
    final t = cells[j];
    if (!isUnit(t)) return false;
    // 规则开关：己方滚木不可被己方攻击（服务端/本地引擎双重校验，防伪造操作）
    if (!allowOwnRollerAttack && t.v == 6 && t.o == owner) return false;
    final old = t.v;
    if (kRange[att.v] != null && isShieldCovered(j, i, t)) {
      log.add('${att.v}的攻击被盾兵7挡下');
      lastSeq++;
      lastAction = {'type': 'attack', 'i': i, 'j': j, 'shielded': true, 'owner': owner};
      return true;
    }
    final r = applyDamage(j, dmg, byOwner: owner);
    final tj = r['insertedAt'] != null ? j + 1 : j;
    final tc = tj < cells.length ? cells[tj] : null;
    final newV = isUnit(tc) ? tc!.v : 0;
    log.add('${att.v}攻击$old，造成$dmg伤害');
    lastSeq++;
    lastAction = {'type': 'attack', 'i': i, 'j': j, 'old': old, 'newV': newV, 'insertedAt': r['insertedAt'], 'owner': owner};
    return true;
  }

  bool doSplit(int owner, int i, int keep) {
    final unit = cells[i];
    if (unit.auto && unit.v == 6) return false;
    final v = unit.v;
    if (v < kSplitMin) return false;
    if (keep is! int || keep < 1 || keep >= v) return false;
    final other = v - keep;
    if (cells.length >= limit) {
      unit.v = keep;
      log.add('满员拆分：$v → 只保留$keep');
      lastSeq++;
      lastAction = {'type': 'split', 'i': i, 'keep': keep, 'other': other, 'full': true, 'owner': owner};
      return true;
    }
    // 产物固定插到保留值右侧（索引+1）
    final ins = i + 1;
    if (ins < 0 || ins > cells.length) return false;
    cells.insert(ins, AimCell(other, o: owner));
    unit.v = keep;
    log.add('拆分$v → $keep+$other');
    lastSeq++;
    lastAction = {'type': 'split', 'i': i, 'keep': keep, 'other': other, 'full': false, 'owner': owner};
    return true;
  }

  bool doDevour(int owner, int i, int j) {
    final me = cells[i];
    if (me.auto && me.v == 6) return false;
    final t = cells[j];
    if (!isUnit(t) || t.v > me.v) return false;
    final sum = me.v + t.v;
    var spliced = false;
    var collapsed = false;
    if (sum <= 9) {
      me.v = sum;
      // 吞噬统计：目标阵亡
      if (t.o != null) {
        _statsList('losses')[t.o!]++;
        _statsList('kills')[owner]++;
      }
      cells.removeAt(j);
      spliced = true;
      log.add('吞噬：${sum - t.v}+${t.v}=$sum');
    } else {
      final tens = sum ~/ 10;
      final ones = sum % 10;
      // 拆出来的两个数，棋盘从左到右读 = 十进制（十位在左、个位在右）
      // 左方(0)吞噬：me 在左保留十位，目标在右放个位；右方(1)相反
      if (owner == 0) {
        me.v = tens;
        cells[j] = AimCell(ones, o: ones == 0 ? null : owner);
      } else {
        me.v = ones;
        cells[j] = AimCell(tens, o: owner);
        if (me.v == 0) {
          // 10/20…：吞噬者这一位是 0，清成空地
          me.o = null;
          me.auto = false;
        }
      }
      log.add('吞噬超9：$sum → $tens+$ones（变拉了）');
    }
    if (me.onBridge && me.v >= 5) {
      final idx = cells.indexOf(me);
      if (idx >= 0) cells.removeAt(idx); // 桥毁人亡：连桥带人一起删格（-1 格），非仅清空
      log.add('桥上吞噬后${me.v}≥5：桥毁人亡');
      collapsed = true;
    }
    lastSeq++;
    lastAction = {'type': 'devour', 'i': i, 'j': j, 'sum': sum, 'spliced': spliced, 'collapsed': collapsed, 'owner': owner};
    return true;
  }

  bool doProduce(int owner, int i) {
    final base = cells[i];
    if (!isOwnedUnit(base, owner) || base.v != 8) return false;
    final dir = dirOf(owner);
    final j = i + dir;
    if (j < 0 || j >= cells.length) return false;
    final t = cells[j];
    if (isBridge(t)) return false;
    if (isUnit(t) && t.o != owner) {
      applyDamage(j, 1, byOwner: owner);
      log.add('造兵攻击：敌方单位-1');
      lastSeq++;
      lastAction = {'type': 'produce', 'j': j, 'attacked': true, 'owner': owner};
    } else {
      bool inserted = false;
      if (t.v == 9) {
        // 9+1=10 → [1][0]：十位1留在原格，个位0空地插到右侧（与拆分同构：产物固定插索引+1）
        t.v = 1;
        t.o = owner;
        final ins = j + 1;
        if (ins >= 0 && ins <= cells.length && cells.length < limit) {
          cells.insert(ins, AimCell(0));
          inserted = true;
          log.add('造兵：9+1=10 → [1][0]（插入个位0空地）');
        } else {
          log.add('造兵：9+1 满格 → 只保留十位1');
        }
      } else {
        t.v += 1;
        t.o = owner;
        log.add('造兵：基地前${t.v - 1} → ${t.v}');
      }
      lastSeq++;
      lastAction = {'type': 'produce', 'j': j, 'attacked': false, 'newV': t.v, 'inserted': inserted, 'owner': owner};
    }
    _statsList('produce')[owner]++;
    return true;
  }

  bool doChoosePhase(int owner, String phase) {
    if (this.phase != null || turn != owner) return false;
    if (phase != 'action' && phase != 'produce') return false;
    this.phase = phase;
    if (phase == 'action') {
      points = countOf(owner, 9) + 1;
    } else {
      produceLeft = countOf(owner, 8);
    }
    return true;
  }

  // ── 滚木自动阶段 ──
  // 逐步接口：rollStepOnce 每次只滚一步（供动画层"规则算一步 → 动画播一步"嵌套驱动）
  // autoRoll 改为循环调用 rollStepOnce——行为完全不变，只是可逐步执行
  void autoRoll(int owner) {
    beginRoll(owner);
    while (rollStepOnce(owner) != null) {}
  }

  // ── 滚木逐步状态 ──
  int? _rsOwner;
  List<AimCell>? _rsRollers;
  int _rsIdx = 0;
  int _rsPos = 0;
  int _rsStep = 1;
  final Set<int> _rsRolled = <int>{};
  final Set<int> _rsDone = <int>{}; // 本回合已滚完的滚木（防重新收集重复滚）
  bool _rsActive = false;
  final List<String> _rsLogs = <String>[];
  final List<Map<String, dynamic>> _rsSteps = <Map<String, dynamic>>[];

  /// 开始一轮滚木（新回合调用）：重置逐步状态
  void beginRoll(int owner) {
    _rsActive = false;
    _rsOwner = null;
    _rsDone.clear();
  }

  // 最近一步基础动作（供动画层逐步驱动）；null = 无新步
  List<Map<String, dynamic>>? _lastRollActs;
  int _rollStepSeq = 0;

  /// 滚木单步：调用一次滚一步，返回该步的【基础动作序列】；全部滚完返回 null
  /// 基础动作：{op:'move',from,to} 滚木移动 ｜ {op:'crush',from,to,at,oldV,newV,bridge} 压单位（含插桥）
  /// ｜ {op:'kill',from,to,at,oldV} 抹杀 ｜ {op:'dead',from,reason} 死亡（撞桥/建筑/滚出/掉桥）
  List<Map<String, dynamic>>? rollStepOnce(int owner) {
    final result = _rollStepOnceInner(owner);
    if (result == null) {
      _lastRollActs = null;
    } else {
      _lastRollActs = result;
      _rollStepSeq++;
    }
    return result;
  }

  List<Map<String, dynamic>>? _rollStepOnceInner(int owner) {
    if (!_rsActive) {
      if (_rsOwner != owner) _rsDone.clear();
      _rsOwner = owner;
      _rsRollers = <AimCell>[];
      final seen = <int>{};
      for (final c in cells) {
        if (isOwnedUnit(c, owner) && c.v == 6 && !seen.contains(c.id) && !_rsDone.contains(c.id)) {
          seen.add(c.id);
          _rsRollers!.add(c);
        }
      }
      _rsIdx = 0;
      _rsPos = _rsRollers!.isEmpty ? -1 : cells.indexOf(_rsRollers!.first);
      _rsStep = 1;
      _rsRolled.clear();
      _rsLogs.clear();
      _rsSteps.clear();
      _rsActive = true;
      if (_rsRollers!.isEmpty) {
        _rsActive = false;
        return null;
      }
    }
    final dir = dirOf(owner);
    // 定位当前活着的滚木（可能已死亡/被清）
    while (_rsIdx < _rsRollers!.length && !cells.contains(_rsRollers![_rsIdx])) {
      _rsIdx++;
    }
    if (_rsIdx >= _rsRollers!.length) {
      _finishRoll();
      return null;
    }
    final roller = _rsRollers![_rsIdx];
    if (_rsStep > 3) {
      // 当前滚木 3 步完成：收尾（滚木已在最终位置，由 _rollOneStep 精确放置）
      roller.auto = true;
      _rsDone.add(roller.id);
      _rsIdx++;
      _rsStep = 1;
      if (_rsIdx < _rsRollers!.length) {
        _rsPos = cells.indexOf(_rsRollers![_rsIdx]);
        return rollStepOnce(owner); // 继续下一个滚木的第一步
      }
      _finishRoll();
      return null;
    }
    final res = _rollOneStep(roller, dir);
    _rsStep++;
    final acts = res['acts'] as List<Map<String, dynamic>>;
    if (res['finished'] == true) {
      // 该滚木结束（死亡或抹杀）：滚木已消失或停在终点
      roller.auto = true;
      _rsDone.add(roller.id);
      _rsIdx++;
      _rsStep = 1;
      if (_rsIdx < _rsRollers!.length) {
        _rsPos = cells.indexOf(_rsRollers![_rsIdx]);
        // 2026-08-18 修复：当前滚木有死亡/抹杀动画（acts 非空）时先返回这步，
        // 让客户端播完再请求下一步——否则下一个滚木的 acts 会覆盖吞掉这步动画
        // （多滚木时死滚木会残影滞留、突然消失）
        if (acts.isNotEmpty) return acts;
        final next = rollStepOnce(owner);
        return next;
      }
      _finishRoll();
      return acts.isEmpty ? null : acts;
    }
    return acts;
  }

  void _finishRoll() {
    _rsActive = false;
    _pendingRoll = false;
    log.addAll(_rsLogs);
    if (_rsSteps.isNotEmpty) {
      rollSeq++;
      rollSteps = List.of(_rsSteps);
    }
    _rsLogs.clear();
    _rsSteps.clear();
  }

  // 滚木走开：当前位置清空（露出脚下压着的单位，或空地），滚木暂离棋盘
  void _unpress(AimCell roller) {
    if (_rsPos >= 0 && _rsPos < cells.length && cells[_rsPos] == roller) {
      cells[_rsPos] = roller.pressedV != null
          ? AimCell(roller.pressedV!, o: roller.pressedO, auto: roller.pressedV == 6)
          : AimCell(0);
    }
    roller.pressedV = null;
    roller.pressedO = null;
  }

  // 滚木放置到 [idx]：覆盖目标格（原单位值存入 pressed = 滚木脚下压着）
  void _place(AimCell roller, int idx, {int? pressedV, int? pressedO}) {
    if (idx >= 0 && idx < cells.length) {
      cells[idx] = roller;
      roller.pressedV = pressedV;
      roller.pressedO = pressedO;
    }
  }

  // 滚木单步执行：返回 {acts: 基础动作序列, finished: 该滚木是否结束}
  Map<String, dynamic> _rollOneStep(AimCell roller, int dir) {
    final acts = <Map<String, dynamic>>[];
    final pos = _rsPos;
    final p = pos + dir;
    // 步开头：脚下压着的单位转正（滚木走开，露出——牢大：压到单位后棋盘只显示滚木，走开才露出）
    _unpress(roller);
    if (p < 0 || p >= cells.length) {
      // 滚出地图
      _rsSteps.add({'dead': true});
      _rsLogs.add('滚木滚出地图');
      acts.add({'op': 'dead', 'reason': 'edge', 'from': pos});
      roller.auto = true;
      return {'acts': acts, 'finished': true};
    }
    final t = cells[p];
    if (isBridge(t)) {
      // 撞桥：桥塌，滚木消失（脚下单位已转正，removeAt 后自动补位）
      _rsSteps.add({'dead': true, 'bridgeCollapse': true});
      _rsLogs.add('滚木砸塌独木桥');
      cells.removeAt(p);
      acts.add({'op': 'dead', 'reason': 'bridge', 'from': pos});
      roller.auto = true;
      return {'acts': acts, 'finished': true};
    }
    if (t.v == 8 || t.v == 9) {
      // 撞建筑：滚木消失
      _rsSteps.add({'dead': true, 'building': true});
      _rsLogs.add('滚木撞上建筑消失');
      acts.add({'op': 'dead', 'reason': 'building', 'from': pos});
      roller.auto = true;
      return {'acts': acts, 'finished': true};
    }
    if (isUnit(t)) {
      if (_rsRolled.contains(t.id)) {
        // 已被推挤到前方，不再碾：滚木站上去（脚下压着）
        _rsPos = p;
        _rsSteps.add({'crush': false});
        acts.add({'op': 'move', 'from': pos, 'to': p});
        _place(roller, p, pressedV: t.v, pressedO: t.o);
        return {'acts': acts, 'finished': false};
      }
      _rsRolled.add(t.id);
      if (_rsStep == 3) {
        // 第三格：抹杀（单位死，滚木站上去）
        _rsSteps.add({'crush': true, 'kill': true, 'owner': t.o, 'oldV': t.v});
        _rsLogs.add('滚木抹杀${t.v}');
        cells[p] = AimCell(0);
        _place(roller, p);
        _rsPos = p;
        acts.add({'op': 'kill', 'from': pos, 'to': p, 'at': p, 'oldV': t.v});
        return {'acts': acts, 'finished': true};
      }
      // 第一、二格：压到单位，受6伤
      final oldV = t.v;
      final r = applyDamage(p, 6);
      _rsSteps.add({'crush': true, 'owner': t.o, 'oldV': oldV, 'newV': t.v, 'bridge': r['insertedAt'] != null});
      _rsLogs.add('滚木碾过：$oldV受6伤');
      if (r['insertedAt'] != null) {
        // 溢出插桥：桥插单位位置（splice），变值单位被顶到桥右（p+1），滚木站到桥右压着它
        _rsSteps.add({'bump': true});
        _rsPos = p + 1; // 桥右边（splice 后变值单位所在）
        acts.add({'op': 'crush', 'from': pos, 'to': p + 1, 'at': p, 'oldV': oldV, 'newV': t.v, 'bridge': true});
        if (_rsPos >= 0 && _rsPos < cells.length) {
          _place(roller, _rsPos, pressedV: t.v, pressedO: t.o);
          return {'acts': acts, 'finished': false};
        }
        // 被顶出地图（尽头插桥）
        _rsSteps.add({'dead': true});
        acts.add({'op': 'dead', 'reason': 'edge', 'from': _rsPos});
        roller.auto = true;
        return {'acts': acts, 'finished': true};
      }
      // 非溢出：单位原地变值，滚木站到单位上（脚下压着）
      _rsPos = p;
      _place(roller, p, pressedV: t.v, pressedO: t.o);
      acts.add({'op': 'crush', 'from': pos, 'to': p, 'at': p, 'oldV': oldV, 'newV': t.v, 'bridge': false});
      return {'acts': acts, 'finished': false};
    }
    // 空地：滚木前进一格
    _rsPos = p;
    _place(roller, p);
    _rsSteps.add({'crush': false});
    acts.add({'op': 'move', 'from': pos, 'to': p});
    return {'acts': acts, 'finished': false};
  }

  bool endTurn(int owner, {bool deferRoll = false}) {
    if (turn != owner) return false;
    turn = 1 - owner;
    phase = null;
    points = 0;
    produceLeft = 0;
    turnCount++;
    if (deferRoll) {
      // 延后滚木：动画层逐步驱动（规则算一步 → 动画播一步）
      // 只在真有滚木待滚时标记（没滚木的回合不产生多余的 roll_step 请求）
      _pendingRoll = cells.any((c) => isOwnedUnit(c, turn) && c.v == 6 && !_rsDone.contains(c.id));
    } else {
      autoRoll(turn);
    }
    checkWin();
    return true;
  }

  bool _pendingRoll = false;
  /// 是否有待滚滚木（deferRoll 模式：endTurn 后滚木还没滚）
  bool get hasPendingRoll => _pendingRoll;

  /// 标记当前待滚状态（供动画层逐步驱动完成后清除）
  void clearPendingRoll() {
    _pendingRoll = false;
  }

  void checkWin() {
    for (final o in [0, 1]) {
      if (sumOf(o) == 0) {
        winner = 1 - o;
        log.add('玩家${1 - o}获胜！');
        continue;
      }
      // 只剩激活滚木（无任何可操控单位）→ 直接判负（牢大定）
      final hasControllable =
          cells.any((c) => isOwnedUnit(c, o) && !(c.v == 6 && c.auto));
      if (!hasControllable) {
        winner = 1 - o;
        log.add('玩家$o只剩滚木，无法行动，判负');
      }
    }
  }

  // ── 重复操作判负（象棋式「三次重复」，与 server rules.js 逐行对应）──
  String _boardHash() {
    return cells
        .map((c) =>
            '${c.v},${c.o ?? ''},${c.bridge ? 1 : 0},${c.onBridge ? 1 : 0},${c.auto ? 1 : 0},${c.pressedV ?? ''},${c.pressedO ?? ''}')
        .join(';');
  }

  String _opSig(Map<String, dynamic> action) {
    final type = action['type'] as String?;
    final i = action['i'] is num ? (action['i'] as num).toInt() : -1;
    final steps = action['steps'] is num ? (action['steps'] as num).toInt() : 1;
    final j = action['j'] is num ? (action['j'] as num).toInt() : -1;
    final keep = action['keep'] is num ? (action['keep'] as num).toInt() : 0;
    switch (type) {
      case 'move':
        return 'move:$i:$steps';
      case 'attack':
        return 'attack:$i:$j';
      case 'split':
        return 'split:$i:$keep';
      case 'devour':
        return 'devour:$i:$j';
      case 'produce':
        return 'produce:$i';
      default:
        return type ?? '';
    }
  }

  int _recordOp(int owner, Map<String, dynamic> action) {
    final fp = '$owner|${_opSig(action)}|${_boardHash()}';
    final n = (_opHistory[fp] ?? 0) + 1;
    _opHistory[fp] = n;
    if (n >= 3) {
      winner = 1 - owner;
      log.add('玩家$owner重复完全相同操作三次（循环），判负');
      _lastOpRepeatWarn = false;
    } else if (n == 2) {
      // 第二次重复：提示「再重复一次就判负」（牢大定）
      _lastOpRepeatWarn = true;
      log.add('玩家$owner注意：再重复一次相同操作将直接判负');
    } else {
      _lastOpRepeatWarn = false;
    }
    return n;
  }

  // ── 统一入口 ──
  Map<String, dynamic> applyAction(int owner, Map<String, dynamic> action, {bool deferRoll = false}) {
    if (winner != null) return {'ok': false, 'reason': '游戏已结束'};
    if (turn != owner) return {'ok': false, 'reason': '还没轮到你'};
    final type = action['type'] as String?;
    if (phase == null) {
      if (type == 'produce') doChoosePhase(owner, 'produce');
      else if (type == 'move' || type == 'attack' || type == 'split' || type == 'devour') {
        doChoosePhase(owner, 'action');
      }
    }
    switch (type) {
      case 'choosePhase':
        if (!doChoosePhase(owner, (action['phase'] as String?) ?? '')) {
          return {'ok': false, 'reason': '无效阶段选择'};
        }
        maybeAutoEnd();
        return {'ok': true};
      case 'move':
        if (phase != 'action' || points <= 0) return {'ok': false, 'reason': '非行动阶段'};
        if (!doMove(owner, (action['i'] as num).toInt(), (action['steps'] as num?)?.toInt() ?? 1)) {
          return {'ok': false, 'reason': '移动不合法'};
        }
        points--;
        checkWin();
        if (winner == null) _recordOp(owner, action); // 重复操作三次判负（象棋式）
        maybeAutoEnd();
        return {'ok': true, 'repeatWarn': _lastOpRepeatWarn};
      case 'attack':
        if (phase != 'action' || points <= 0) return {'ok': false, 'reason': '非行动阶段'};
        if (!doAttack(owner, (action['i'] as num).toInt(), (action['j'] as num).toInt())) {
          return {'ok': false, 'reason': '攻击不合法'};
        }
        points--;
        checkWin();
        if (winner == null) _recordOp(owner, action); // 重复操作三次判负（象棋式）
        maybeAutoEnd();
        return {'ok': true, 'repeatWarn': _lastOpRepeatWarn};
      case 'split':
        if (phase != 'action' || points <= 0) return {'ok': false, 'reason': '非行动阶段'};
        if (!doSplit(owner, (action['i'] as num).toInt(), (action['keep'] as num?)?.toInt() ?? 0)) {
          return {'ok': false, 'reason': '拆分不合法'};
        }
        points--;
        checkWin();
        if (winner == null) _recordOp(owner, action); // 重复操作三次判负（象棋式）
        maybeAutoEnd();
        return {'ok': true, 'repeatWarn': _lastOpRepeatWarn};
      case 'devour':
        if (phase != 'action' || points <= 0) return {'ok': false, 'reason': '非行动阶段'};
        if (!doDevour(owner, (action['i'] as num).toInt(), (action['j'] as num).toInt())) {
          return {'ok': false, 'reason': '吞噬不合法'};
        }
        points--;
        checkWin();
        if (winner == null) _recordOp(owner, action); // 重复操作三次判负（象棋式）
        maybeAutoEnd();
        return {'ok': true, 'repeatWarn': _lastOpRepeatWarn};
      case 'produce':
        if (phase != 'produce' || produceLeft <= 0) return {'ok': false, 'reason': '非造兵阶段'};
        if (!doProduce(owner, (action['i'] as num).toInt())) return {'ok': false, 'reason': '造兵不合法'};
        produceLeft--;
        checkWin();
        if (winner == null) _recordOp(owner, action); // 重复操作三次判负（象棋式）
        maybeAutoEnd();
        return {'ok': true, 'repeatWarn': _lastOpRepeatWarn};
      case 'endTurn':
        if (phase == 'action' && points > 0) return {'ok': false, 'reason': '行动点未耗尽，不能结束回合'};
        if (phase == 'produce' && produceLeft > 0) return {'ok': false, 'reason': '造兵点未耗尽，不能结束回合'};
        endTurn(owner, deferRoll: deferRoll);
        return {'ok': true};
      default:
        return {'ok': false, 'reason': '未知行动'};
    }
  }

  void maybeAutoEnd() {
    if (winner != null) return;
    if (phase == 'action' && points <= 0) {
      endTurn(turn);
      return;
    }
    if (phase == 'produce' && produceLeft <= 0) {
      endTurn(turn);
      return;
    }
    final acts = getLegalActions(turn);
    final playable = acts.where((a) => a['type'] != 'endTurn' && a['type'] != 'choosePhase').toList();
    if (phase != null && playable.isEmpty) {
      // 死局判负（牢大 08-22）：一方无任何可执行行动（无法移动/攻击/吞噬/拆分）→ 直接判负
      log.add('玩家$turn无任何可执行行动，判负');
      winner = 1 - turn;
    }
  }

  // ── 玩家视角快照（与联机服务端 viewFor 同格式，GameScreen 直接消费）──
  Map<String, dynamic> viewFor(int playerIdx) {
    final mine = playerIdx == turn;
    return {
      'cells': cells.map((c) => c.toMap()).toList(),
      'mapLen': cells.length,
      'limit': limit,
      'turn': turn,
      'phase': phase,
      'points': points,
      'produceLeft': produceLeft,
      'winner': winner,
      'yourIdx': playerIdx,
      'names': ['玩家1', '玩家2'],
      'hotseat': true,
      'mySum': sumOf(playerIdx),
      'enemySum': sumOf(1 - playerIdx),
      'myBases': countOf(playerIdx, 8),
      'myHqs': countOf(playerIdx, 9),
      'legalActions': mine ? getLegalActions(playerIdx) : [],
      'log': log.length > 8 ? log.sublist(log.length - 8) : List.of(log),
      'lastAction': lastAction,
      'lastSeq': lastSeq,
      'rollSteps': rollSteps,
      'rollSeq': rollSeq,
      'rollPending': _pendingRoll || _rsActive,
      'rollActs': _lastRollActs,
      'rollStepSeq': _rollStepSeq,
      'stats': stats,
      'turnCount': turnCount,
    };
  }

  Map<String, dynamic> viewForSpectator() {
    return {
      'cells': cells.map((c) => c.toMap()).toList(),
      'mapLen': cells.length,
      'limit': limit,
      'turn': turn,
      'phase': phase,
      'points': points,
      'produceLeft': produceLeft,
      'winner': winner,
      'yourIdx': -1,
      'names': ['玩家1', '玩家2'],
      'hotseat': false,
      'spectator': true,
      'mySum': 0,
      'enemySum': 0,
      'myBases': 0,
      'myHqs': 0,
      'sums': [sumOf(0), sumOf(1)],
      'bases': [countOf(0, 8), countOf(1, 8)],
      'hqs': [countOf(0, 9), countOf(1, 9)],
      'legalActions': [],
      'log': log.length > 8 ? log.sublist(log.length - 8) : List.of(log),
      'lastAction': lastAction,
      'lastSeq': lastSeq,
      'rollSteps': rollSteps,
      'rollSeq': rollSeq,
      'rollPending': _pendingRoll || _rsActive,
      'rollActs': _lastRollActs,
      'rollStepSeq': _rollStepSeq,
      'stats': stats,
      'turnCount': turnCount,
    };
  }
}
