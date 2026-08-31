import 'dart:async';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../tutorial/tutorial_engine.dart';
import '../widgets/hit_fx.dart';
import '../tutorial/tutorial_script.dart';
import '../tutorial/tutorial_audio_map.dart';
import '../tutorial/board_anim.dart';
import '../core/bgm_manager.dart';
import '../core/settings_store.dart';
import '../widgets/settings_panel.dart';

const _ink = Color(0xFF11110F);
const _paper = Color(0xFFFFF5DC);
const _signal = Color(0xFFFF4E35);
const _enemy = Color(0xFFB12718);
const _warn = Color(0xFFFFD36A);
const _dim = Color(0xFF77736B);
const _green = Color(0xFF61D39E);
const _borderC = Color(0xFF5A554C);
const _cellEven = Color(0xFF1E1D1A);
const _textC = Color(0xFF3E3628); // 纸上深字（仿游戏）
const _cellOdd = Color(0xFF181715);
// 像素风引导色（低饱和，贴合 UI，不扎眼）
const _glowGold = Color(0xFFB8934A); // 暗金（等待操作）
const _glowGreen = Color(0xFF4E8A6A); // 暗绿（展示引导）

class TutorialScreen extends StatefulWidget {
  final VoidCallback onExit;
  final int startChapter; // 从第几章开始（0-based）
  const TutorialScreen({super.key, required this.onExit, this.startChapter = 0});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> with TickerProviderStateMixin {
  late TutEngine _engine;
  int chapterIdx = 0;
  double _scale = 1;

  // 打字机
  Timer? _typeTimer;
  String _display = '';
  String _fullText = '';
  int _typeIdx = 0;
  String? _lastSpeaker;
  String? _lastText;
  bool _showStats = false; // 角色信息大弹窗
  bool _demoPlaying = false; // 演示队列播放中
  bool _tutRollDead = false; // 教程滚木滚动中撞毁（提前结束动画）
  bool _tutRollPaused = false; // 教程滚木压单位停顿中（浮层保持显示）
  bool _boardAnim = false; // 棋盘入场/退场动画进行中（阻止点击推进）
  bool _boardEntering = false; // 入场动画中
  bool _exiting = false; // 退出动画播放中（数字朝自家方向飞走淡出后真正退出）
  final AudioPlayer _voice = AudioPlayer(); // 日文配音播放器
  int _voiceSeq = 0; // 配音代次：快速切句时丢弃过期播放请求

  // ── 动画（与游戏本体同套逻辑：动画棋盘 + 转变白闪 + 删除缩没 + 插入弹入） ──
  int _lastSeq = 0; // 已播放的剧本序号
  List<TutCell>? _animCells; // 动画中的棋盘（旧棋盘 + 转变结果），null=显示引擎棋盘
  final List<HitFxData> _hits = [];
  int _hitId = 0;
  int _animId = 0;
  final List<_TutInsertAnim> _inserts = [];
  final List<_TutRemoveAnim> _removes = [];
  AnimationController? _tutShiftCtrl; // 删除补位专用（吞噬删格用）
  int _tutShiftAt = -1;
  // 移动浮层（与对战端 _startMoveAnim 同构）：单位从 stepFrom 逐格平移到新位置
  Map<String, dynamic>? _tutMv;
  AnimationController? _tutStepCtrl;

  @override
  void initState() {
    super.initState();
    _engine = TutEngine();
    _engine.addListener(_onEngineChanged);
    _loadChapter(widget.startChapter.clamp(0, tutorialChapters.length - 1));
    // 教程：非战斗 BGM
    BgmManager.instance.playIdle();
  }

  void _loadChapter(int idx) {
    chapterIdx = idx;
    _animCells = null;
    _removes.clear();
    _inserts.clear();
    _stopVoice(); // 旧章语音立即停
    _engine.load(tutorialChapters[idx]['steps'] as List<Map<String, dynamic>>);
  }

  void _onEngineChanged() {
    if (!mounted) return;
    // 剧本驱动（与游戏本体同套逻辑）：移动/滚木走 demoQueue 逐格，其余操作播放转变/删除/插入动画
    final la = _engine.lastAction;
    final seq = _engine.lastSeq;
    if (la != null && seq != _lastSeq) {
      _lastSeq = seq;
      final t = la['type'] as String?;
      if (t != null && t != 'move' && t != 'roll') {
        _playTutLastAction(la);
      }
    }
    // board 状态更新 diff（元素思维）：同位置变化→白闪，新增→弹入，删除→缩没+补位
    final diff = _engine.boardDiff;
    if (diff != null) {
      _playTutBoardDiff(diff);
      _engine.clearBoardDiff();
    }
    final sp = _engine.currentSpeaker;
    final tx = _engine.currentText;
    // 角色词条出现 → 显示大弹窗
    if (_engine.stats.isNotEmpty) {
      _showStats = true;
    }
    if (sp != _lastSpeaker || tx != _lastText) {
      _lastSpeaker = sp;
      _lastText = tx;
      if (tx != null && tx.isNotEmpty) {
        // 播放日文配音（角色台词才有音频）
        _playVoice(tx);
        // 延迟 400ms 再开始打字，避免场景切换接得太硬
        _typeTimer?.cancel();
        _fullText = tx;
        _display = '';
        _typeIdx = 0;
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          if (_lastText != tx) return;
          _startTypingInternal(tx);
        });
      } else {
        _stopTyping();
        _display = '';
        _stopVoice(); // 字幕被切走 → 当前语音立即停（不再等下一个语音到来）
      }
    }
    // 演示队列就绪 → 逐格播放
    if (_engine.demoReady && !_demoPlaying) {
      _playDemo();
    }
    // 章节首屏 board → 退场+入场动画；章节内 board 已由引擎直接应用（状态更新）
    if (_engine.boardPending && !_boardAnim) {
      _playBoardTransition();
    }
    setState(() {});
  }

  // 棋盘切换动画：退场 → 换盘 → 入场
  Future<void> _playBoardTransition() async {
    if (_boardAnim) return;
    _boardAnim = true;
    setState(() {});
    // 阶段1：旧棋盘退场（数字先退 → 停100ms → 格子壳再退）
    _boardEntering = false;
    setState(() {});
    await Future.delayed(const Duration(milliseconds: 1000));
    // 阶段2：应用新棋盘（引擎继续推进）
    if (!mounted) return;
    _engine.applyPendingBoard();
    // 阶段3：新棋盘入场（中间先落，对称展开）
    _boardEntering = true;
    setState(() {});
    await Future.delayed(const Duration(milliseconds: 1000));
    _boardAnim = false;
    _boardEntering = false;
    if (mounted) setState(() {});
  }

  // 教程退出动画：整盘数字朝自家方向飞走淡出（教程专属退场，对战用不到），播完再真正退出
  void _startExitAnim() {
    if (_exiting) return;
    _stopVoice();
    setState(() => _exiting = true);
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      widget.onExit();
    });
  }

  // ── 剧本驱动（与游戏本体同套逻辑，TutCell 版） ──
  // 动画棋盘：旧棋盘 + 转变结果，播完切回引擎棋盘
  void _playTutLastAction(Map la) {
    final type = la['type'] as String?;
    if (type == null) return;
    switch (type) {
      case 'attack':
        _tutAttack(la);
        break;
      case 'devour':
        _tutDevour(la);
        break;
      case 'split':
        _tutSplit(la);
        break;
      case 'produce':
        _tutProduce(la);
        break;
    }
  }

  // board 状态更新 diff 动画（元素思维，与对战端各行动动画同构）：
  // 同位置内容变化→白闪转变；新棋盘多出的格子→弹入；旧棋盘多出的格子→缩没+补位
  void _playTutBoardDiff(Map diff) {
    final prev = ((diff['prevCells'] as List?) ?? const []).cast<TutCell>();
    final changed = (diff['changed'] as List?) ?? const [];
    final inserted = (diff['inserted'] as List?) ?? const [];
    final removed = (diff['removed'] as List?) ?? const [];
    // 转变：白闪（同位置值变，如 0→8 造兵点出现）
    for (final c in changed) {
      final idx = (c['idx'] as num).toInt();
      final from = (c['from'] as num).toInt();
      final to = (c['to'] as num).toInt();
      if (from == to) continue;
      _addTutHit(idx, from, to);
    }
    // 插入：新格弹入（由 _tutInsertWrap 由远及近）
    for (final idx in inserted) {
      _addTutInsert((idx as num).toInt());
    }
    // 删除：旧格缩没 + 补位
    for (final idx in removed) {
      _addTutRemove((idx as num).toInt(), prev);
    }
  }

  List<TutCell> _copyTutCells(List<TutCell> cells) => cells.map((c) => c.copy()).toList();

  // 与对战端同构：动画基底必须是操作前的旧棋盘（prevCells），
  // 否则引擎已插桥/已删格，UI 再插/再删会重复错位
  List<TutCell> _tutBase(Map la) {
    final prev = la['prevCells'];
    if (prev is List && prev.isNotEmpty && prev.first is TutCell) {
      return (prev as List).cast<TutCell>();
    }
    return _engine.cells; // 兜底（旧数据无快照）
  }

  // 按 id 在结果棋盘找值（删除/插入导致索引变化时精确定位，与对战端 _newCellVAt 同构）
  int _tutNewVAt(List<TutCell> cells, int id, int fallback) {
    for (final c in cells) {
      if (c.id == id) return c.v;
    }
    return fallback;
  }

  void _tutFinish([int delayMs = 0]) {
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      _animCells = null;
      setState(() {});
    });
  }

  // 攻击：目标转变（白闪遮挡），溢出则插桥（推开+弹入）——与对战端 _playAttack 同构
  void _tutAttack(Map la) {
    final j = (la['j'] as num).toInt();
    final old = (la['old'] as num).toInt();
    final newV = (la['newV'] as num).toInt();
    final ins = la['insertedAt'];
    if (la['shielded'] == true) return;
    final base = _tutBase(la);
    final anim = _copyTutCells(base);
    if (ins != null) {
      final insIdx = (ins as num).toInt();
      anim.insert(insIdx, TutCell(0, bridge: true)); // 桥插入（新 id）
      if (insIdx + 1 < anim.length) anim[insIdx + 1].v = newV;
      _animCells = anim;
      setState(() {});
      _addTutHit(insIdx + 1, old, newV);
      _addTutInsert(insIdx);
      _tutFinish(750);
    } else {
      if (newV > 0) {
        anim[j].v = newV;
      } else {
        anim[j] = TutCell(0);
      }
      _animCells = anim;
      setState(() {});
      _addTutHit(j, old, newV);
      _tutFinish(650);
    }
  }

  // 吞噬：两格同时转变 → 停顿 → 目标格缩没 → 切回引擎棋盘——与对战端 _playDevour 同构
  void _tutDevour(Map la) {
    final i = (la['i'] as num).toInt();
    final j = (la['j'] as num).toInt();
    final spliced = la['spliced'] == true;
    final collapsed = la['collapsed'] == true;
    final sum = (la['sum'] as num).toInt();
    final base = _tutBase(la);
    final oldVi = (la['oldI'] as num?)?.toInt() ?? base[i].v;
    final oldVj = (la['oldJ'] as num?)?.toInt() ?? base[j].v;
    // 结果值按 id 在新棋盘（引擎 cells）找；找不到用 sum 推导（超9：tens+ones）
    final newVi = _tutNewVAt(_engine.cells, base[i].id, sum > 9 ? sum ~/ 10 : sum);
    final newVj = _tutNewVAt(_engine.cells, base[j].id, sum > 9 ? sum % 10 : 0);
    final anim = _copyTutCells(base);
    if (!collapsed) {
      anim[i].v = newVi;
      if (spliced) {
        anim[j] = TutCell(0);
      } else {
        anim[j].v = newVj;
      }
    } else {
      anim[i] = TutCell(0);
    }
    _animCells = anim;
    setState(() {});
    // 阶段1：两个格子同时转变（白闪+刀光遮挡，底下已是结果值）
    if (!collapsed) {
      _addTutHit(i, oldVi, newVi);
      if (spliced) {
        _addTutHit(j, oldVj, 0);
      } else if (newVj != oldVj) {
        _addTutHit(j, oldVj, newVj);
      }
    } else {
      _addTutHit(i, oldVi, 0);
    }
    // 阶段2：直接删除变 0 的格子（无残影），剩余格子平滑补位
    Timer(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      if (spliced && !collapsed) {
        final anim = _animCells;
        if (anim != null && j < anim.length) {
          anim.removeAt(j);
          _animCells = anim;
          setState(() {});
        }
        _tutShiftAt = j;
        _tutShiftCtrl?.dispose();
        _tutShiftCtrl = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 400),
        )
          ..addListener(() { if (mounted) setState(() {}); })
          ..forward().whenComplete(() {
            _tutShiftCtrl?.dispose();
            _tutShiftCtrl = null;
            _tutShiftAt = -1;
          });
      }
      _tutFinish(1000);
    });
  }

  // 拆分：保留位转变 + 产物插入（右侧弹入）——与对战端 _playSplit 同构
  void _tutSplit(Map la) {
    final i = (la['i'] as num).toInt();
    final keep = (la['keep'] as num).toInt();
    final other = (la['other'] as num?)?.toInt() ?? 0;
    final full = la['full'] == true;
    final oldV = (la['old'] as num?)?.toInt() ?? (keep + other); // 拆分前值
    final base = _tutBase(la);
    final anim = _copyTutCells(base);
    anim[i].v = keep;
    if (!full) anim.insert(i + 1, TutCell(other, o: base[i].o)); // 产物插保留值右侧
    _animCells = anim;
    setState(() {});
    _addTutHit(i, oldV, keep);
    if (!full) _addTutInsert(i + 1);
    _tutFinish(750);
  }

  // 造兵：新单位出现（白闪）或攻击敌方（-1）——不需要动画棋盘，与对战端 _playProduce 同构
  void _tutProduce(Map la) {
    final j = (la['j'] as num).toInt();
    final base = _tutBase(la);
    if (la['attacked'] == true) {
      final oldV = base[j].v;
      final nv = _engine.cells[j].v;
      if (nv != oldV) _addTutHit(j, oldV, nv);
    } else {
      final oldV = base[j].v;
      final nv = _engine.cells[j].v;
      if (nv != oldV) _addTutHit(j, oldV, nv);
      // 9+1=10：个位0空地插入右侧（与拆分插入动画同款）
      if (la['inserted'] == true) _addTutInsert(j + 1);
    }
  }

  void _addTutHit(int idx, int from, int to) {
    if (!mounted) return;
    setState(() {
      _hits.add(HitFxData(i: idx, from: from, to: to)..id = ++_hitId);
    });
  }

  void _addTutInsert(int idx) {
    final id = ++_animId;
    final ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _inserts.add(_TutInsertAnim(id: id, idx: idx, ctrl: ctrl));
    ctrl.addListener(() { if (mounted) setState(() {}); });
    ctrl.forward().whenComplete(() {
      ctrl.dispose();
      if (mounted) setState(() => _inserts.removeWhere((a) => a.id == id));
    });
    if (mounted) setState(() {});
  }

  void _addTutRemove(int oldIdx, List<TutCell> prevCells) {
    if (oldIdx < 0 || oldIdx >= prevCells.length) return;
    final c = prevCells[oldIdx];
    final id = ++_animId;
    final ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
    _removes.add(_TutRemoveAnim(id: id, oldIdx: oldIdx, cell: c, ctrl: ctrl));
    ctrl.addListener(() { if (mounted) setState(() {}); });
    ctrl.forward().whenComplete(() {
      ctrl.dispose();
      if (mounted) setState(() => _removes.removeWhere((r) => r.id == id));
    });
    if (mounted) setState(() {});
  }

  void _removeTutHit(int id) {
    if (!mounted) return;
    setState(() => _hits.removeWhere((h) => h.id == id));
  }

  void _startTypingInternal(String full) {
    final perChar = full.length > 30 ? 55 : 65;
    _typeTimer = Timer.periodic(Duration(milliseconds: perChar), (t) {
      _typeIdx++;
      if (_typeIdx >= _fullText.length) {
        t.cancel();
        // 关键：置 null，否则光标 ▌ 一直显示且点击要多点一次
        _typeTimer = null;
      }
      if (mounted) {
        setState(() => _display = _fullText.substring(0, _typeIdx.clamp(0, _fullText.length)));
      }
      if (_typeIdx % 3 == 0) {
        SystemSound.play(SystemSoundType.click);
      }
    });
  }

  // 字幕被切走 → 语音立即停（代次 +1 使进行中的播放请求作废）
  void _stopVoice() {
    _voiceSeq++;
    _voice.stop();
  }

  // 播放台词日文配音（无音频的角色/旁白自动跳过）
  // 若语音未放完就切到下一句：停止当前、播下一句（代次保护防竞态）
  Future<void> _playVoice(String text) async {
    final path = lineAudioMap[text];
    if (path == null) return;
    final mySeq = ++_voiceSeq;
    try {
      await _voice.stop();
      if (!mounted || mySeq != _voiceSeq) return; // 期间又切句了，放弃过期请求
      await _voice.setVolume(SettingsStore.voiceVolume);
      await _voice.play(AssetSource(path.replaceFirst('assets/', '')));
    } catch (_) {}
  }

  // 播放演示队列：逐格动画（移动一步一停），播完调用 engine.demoDone()
  Future<void> _playDemo() async {
    if (_demoPlaying) return; // 防重入
    _demoPlaying = true;
    try {
      if (mounted) setState(() {});
      while (_engine.demoQueue.isNotEmpty && !_exiting) {
        final s = _engine.demoQueue.removeAt(0);
        final type = s['auto'] as String;
        final owner = (s['owner'] as int?) ?? 0;
        if (type == 'move') {
          final i = s['i'] as int;
          final steps = (s['steps'] as int?) ?? 1;
          // 一格一格走，中间停顿（浮层平移，与对战端 _startMoveAnim 同构）
          var pos = i;
          for (int k = 1; k <= steps; k++) {
            final prev = _engine.cells.map((c) => c.copy()).toList();
            _engine.doMove(pos, 1, owner: owner);
            pos += (owner == 0 ? 1 : -1); // 我方朝右+1，敌方朝左-1
            // 移动浮层：基于旧棋盘逐格平移（引擎棋盘已是结果，动画播完再切回）
            _startTutMoveAnim(prev, k == steps);
            if (mounted) setState(() {});
            await Future.delayed(const Duration(milliseconds: 520));
          }
        } else if (type == 'roll') {
          // 滚木：一格一格滚（step 1→3），碾压/生桥同步显示（浮层平移）
          for (int k = 1; k <= 3; k++) {
            final prev = _engine.cells.map((c) => c.copy()).toList();
            _engine.rollStep(owner, k);
            _tutDetectRoll(prev); // 浮层：滚木位置变化 → 逐格平移
            if (mounted) setState(() {});
            await Future.delayed(const Duration(milliseconds: 520));
          }
        } else if (type == 'walk') {
          // 列队离场：一个个往右走，依次走到尽头消失
          while (_engine.walkStep(owner)) {
            if (mounted) setState(() {});
            await Future.delayed(const Duration(milliseconds: 400));
          }
        } else {
          _engine.runAuto(s);
          // 触发 lastAction 动画（攻击白闪/吞噬转变/拆分/造兵）——与对战端一致
          final la = _engine.lastAction;
          if (la != null && la['type'] != 'move' && la['type'] != 'roll') {
            _lastSeq = _engine.lastSeq; // 标记已播，避免 _onEngineChanged 重复播放
            _playTutLastAction(la);
          }
          if (mounted) setState(() {});
          await Future.delayed(const Duration(milliseconds: 800));
        }
        if (!mounted) return;
      }
    } finally {
      _demoPlaying = false;
      _engine.demoDone();
      if (mounted) setState(() {});
    }
  }

  // 移动浮层动画（与对战端 _startMoveAnim 同构）：旧棋盘为底，单位从旧位置逐格平移到新位置
  // [prev] 操作前棋盘快照（引擎棋盘已是结果）；[lastStep] 是否最后一步（播完切回引擎棋盘）
  void _startTutMoveAnim(List<TutCell> prev, bool lastStep) {
    // 从快照找移动单位（用 id 精确定位，防场上同值/同阵营单位被误清——对齐对战端）
    final la = _engine.lastAction;
    if (la == null || la['type'] != 'move') return;
    final me = (la['owner'] as num?)?.toInt() ?? 0;
    final i = (la['i'] as num).toInt();
    final steps = (la['steps'] as num?)?.toInt() ?? 1;
    final dirn = me == 1 ? -1 : 1;
    if (i < 0 || i >= prev.length) return;
    final c = prev[i];
    if (!c.isUnit) return;
    final newIdx = i + dirn * steps;
    if (newIdx < 0 || newIdx >= prev.length) return;
    _startTutMv(prev,
        v: c.v, o: c.o, dirn: dirn, steps: steps, oldIdx: i, newIdx: newIdx,
        rid: c.id);
  }

  // 滚木浮层：id diff 找 v=6 位置变化（与对战端 _detectRoll 同构），逐格平移
  void _tutDetectRoll(List<TutCell> prev) {
    final newCells = _engine.cells;
    for (final p in prev) {
      if (p.isB || !p.isUnit || p.v != 6) continue;
      final oi = prev.indexOf(p);
      int? ni;
      for (int k = 0; k < newCells.length; k++) {
        if (newCells[k].id == p.id) {
          ni = k;
          break;
        }
      }
      if (ni == null) {
        // 滚木消失（撞桥/建筑/压桥掉下去）：有 rollSteps 时也播动画（滚动到死点消失）
        if (_engine.lastRollSteps.isNotEmpty) {
          final steps = _engine.lastRollSteps.length;
          final deadIdx = oi + (ni == null ? (p.o == 0 ? 1 : -1) : 0) * steps;
          final dirn = p.o == 0 ? 1 : -1;
          _startTutMv(prev,
              v: 6, o: p.o, dirn: dirn, steps: steps, oldIdx: oi, newIdx: deadIdx,
              rollSteps: _engine.lastRollSteps, rid: p.id);
        }
        break;
      }
      if (ni == oi) continue;
      final steps = (ni - oi).abs();
      final dirn = ni > oi ? 1 : -1;
      _startTutMv(prev,
          v: 6, o: p.o, dirn: dirn, steps: steps, oldIdx: oi, newIdx: ni,
          rollSteps: _engine.lastRollSteps, rid: p.id);
      break;
    }
  }

  // 浮层核心：旧棋盘为底，单位逐格平移（每格 260ms easeInOut），播完切回引擎棋盘。
  // 滚木滚动时 [rollSteps] 携带引擎每子步碾压结果：压到即更新（桥/新值），不是滚完统一处理。
  // 绑定模型（对齐对战端 _startMoveAnim 2026-08-17）：
  //   - 移动单位用 id 精确定位（[rid]），滚木脚下压着的单位存 pressedV，走开时转正露出
  //   - 滚木压单位（crush）→ 绑定到棋盘格（显示滚木，压着单位），浮层隐藏；
  //     下一步滑行前 placeUnit 清掉滚木（露出被压单位），浮层重新出现
  //   - 溢出插桥（bridge）：滚木先绑定到被压格，桥插入把整格挤到桥右（splice 语义）
  //   - 子步方向：bump（被顶到桥右）固定 +1，与滚木方向无关
  void _startTutMv(List<TutCell> prev,
      {required int v, required int? o, required int dirn, required int steps, required int oldIdx, required int newIdx,
      List<Map<String, dynamic>>? rollSteps, int? rid}) {
    _tutStepCtrl?.dispose();
    _tutStepCtrl = null;
    _tutRollDead = false;
    _tutMv = {'v': v, 'o': o, 'dirn': dirn, 'steps': steps, 'oldIdx': oldIdx, 'newIdx': newIdx, 'stepFrom': oldIdx, 'bound': false};
    var anim = prev.map((cc) => cc.copy()).toList();
    // 清掉滚木本体所在格（对齐对战端 clearCell）：脚下压着的单位转正露出；桥保留
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
    // 把移动单位从旧位置清掉（其余位置不动），刷新动画棋盘（浮层即本体，不写进棋盘）
    void placeUnit(int from) {
      if (rid != null) {
        for (int k = 0; k < anim.length; k++) {
          if (anim[k].id == rid) clearCell(k);
        }
      } else {
        for (int k = 0; k < anim.length; k++) {
          if (k != from && anim[k].v == v && anim[k].o == o) {
            anim[k] = TutCell(0);
          }
        }
      }
      _animCells = anim.map((cc) => cc.copy()).toList();
    }
    // 滚木第 [s] 子步（1-based）的碾压结果应用到动画棋盘：压到即更新
    void applyRollStep(int s) {
      if (rollSteps == null || s < 1 || s > rollSteps.length) return;
      final rs = rollSteps[s - 1];
      if (rs['dead'] == true) {
        _tutRollDead = true;
        return;
      }
      if (rs['bump'] == true || rs['crush'] != true) return; // 被顶/空位：格子不变
      final arrival = oldIdx + dirn * s;
      if (arrival < 0 || arrival >= anim.length) return;
      final owner = (rs['owner'] as num?)?.toInt();
      if (rs['kill'] == true) {
        // 抹杀：单位死，滚木站上去（棋盘显示滚木；id 用 rid，后续 placeUnit 能按 id 清掉）
        anim[arrival] = TutCell.withId(v, rid!, o: o);
        _tutMv?['bound'] = true;
      } else if (rs['bridge'] == true) {
        // 溢出插桥：滚木先绑定到被压格（脚下压着变值单位），
        // 桥插入把整格挤到桥右（splice 语义）——"格子怎么动，滚木怎么动"
        anim[arrival] = TutCell.withId(v, rid!, o: o,
            pressedV: (rs['newV'] as num).toInt(), pressedO: owner);
        anim.insert(arrival, TutCell(0, bridge: true));
        _addTutInsert(arrival);
        _tutMv?['bound'] = true;
      } else {
        // 非溢出：单位原地变值，滚木站上去压着（棋盘显示滚木，单位藏脚下）
        anim[arrival] = TutCell.withId(v, rid!, o: o,
            pressedV: (rs['newV'] as num).toInt(), pressedO: owner);
        _tutMv?['bound'] = true;
      }
      // 被压单位的转变动画（白闪刀光）
      if (rs['kill'] != true) {
        _addTutHit(arrival, (rs['oldV'] as num?)?.toInt() ?? 0, (rs['newV'] as num?)?.toInt() ?? 0);
      }
      _animCells = anim.map((cc) => cc.copy()).toList();
    }
    void cleanup() {
      _tutStepCtrl?.dispose();
      _tutStepCtrl = null;
      _tutMv = null;
      _tutRollPaused = false;
      _animCells = null;
      if (mounted) setState(() {});
    }
    // 串行推进：上一步平移完成 → 应用该步碾压结果 → 下一步（from → from+dirn）
    var step = 0;
    void nextStep() {
      step++;
      if (step > steps) {
        cleanup();
        return;
      }
      // 滚木撞桥掉下去（dead 子步）：浮层停在桥的位置（保持显示），停顿后删格
      if (rollSteps != null && step <= rollSteps.length && rollSteps[step - 1]['dead'] == true) {
        _tutRollPaused = true;
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          _tutRollPaused = false;
          cleanup();
        });
        return;
      }
      // 子步方向：bump（被顶到桥右边）固定 +1（splice 右移，与滚木方向无关）；其余沿 dirn
      final isBump = rollSteps != null &&
          step <= rollSteps.length &&
          rollSteps[step - 1]['bump'] == true;
      final subDirn = isBump ? 1 : dirn;
      // from 按前 step-1 个子步累计（bump 反向 +1）——旧公式 oldIdx+dirn*(step-1) 在插桥后错位
      var from = oldIdx;
      for (var i = 1; i < step; i++) {
        final r = rollSteps != null && i <= rollSteps.length ? rollSteps[i - 1] : null;
        from += (r != null && r['bump'] == true) ? 1 : dirn;
      }
      _tutMv?['stepFrom'] = from;
      _tutMv?['subDirn'] = subDirn;
      _tutMv?['bound'] = false; // 滚木回到浮层（清掉棋盘绑定格）
      placeUnit(from);
      final prevCtrl = _tutStepCtrl;
      _tutStepCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 260),
      )
        ..addListener(() {
          if (mounted) setState(() {});
        })
        ..forward().whenComplete(() {
          if (!mounted) return;
          // 浮层到达 from+dirn：该格立即更新为碾压结果（压到即更新，不是滚完统一处理）
          applyRollStep(step);
          if (_tutRollDead) {
            cleanup();
            return;
          }
          // 压到单位：停住（滚木绑定在到达格，脚下压着被压单位），等转变动画播完再继续滚
          final rs = rollSteps != null && step <= rollSteps.length ? rollSteps[step - 1] : null;
          if (rs != null && rs['crush'] == true && rs['kill'] != true) {
            _tutRollPaused = true;
            Future.delayed(const Duration(milliseconds: 660), () {
              if (!mounted) return;
              _tutRollPaused = false;
              nextStep();
            });
            return;
          }
          nextStep();
        });
      prevCtrl?.dispose();
      if (mounted) setState(() {});
    }
    nextStep();
  }

  void _stopTyping() {
    _typeTimer?.cancel();
    _typeTimer = null;
  }

  @override
  void dispose() {
    _stopTyping();
    _voice.dispose();
    _tutStepCtrl?.dispose();
    _tutShiftCtrl?.dispose();
    for (final a in _inserts) {
      a.ctrl.dispose();
    }
    for (final r in _removes) {
      r.ctrl.dispose();
    }
    _engine.removeListener(_onEngineChanged);
    super.dispose();
  }

  // ── 点任意处下一条（打字未完成先跳完） ──
  void _tapNext() {
    if (_engine.autoPause) {
      _engine.autoPause = false;
      _engine.runStep();
      return;
    }
    if (_engine.popupOpen) {
      _engine.dismissPopup();
      // popup 关闭后若已 finished（章节末规则弹窗），直接切章/退出，不用再点一次
      _maybeNextChapter();
      return;
    }
    if (_engine.choiceOptions != null) return;
    if (_engine.waiting) return;
    if (_typeTimer != null) {
      _stopTyping();
      setState(() => _display = _fullText);
      return;
    }
    _engine.advance();
    _maybeNextChapter();
  }

  void _choose(String opt) {
    _engine.chooseOption(opt);
    _maybeNextChapter();
  }

  // 章节结束后：切下一章 / 全部完成则退出
  void _maybeNextChapter() {
    if (_engine.finished && chapterIdx < tutorialChapters.length - 1) {
      _loadChapter(chapterIdx + 1);
    } else if (_engine.finished) {
      widget.onExit();
    }
  }

  // 只在"能推进"的状态下响应点击
  bool get _canAdvance {
    if (_exiting) return false; // 退出动画中锁定
    if (_engine.waiting) return false;
    if (_engine.choiceOptions != null) return false;
    // popupOpen 时允许点击（点击 = 关闭弹窗 → 切章），不能禁！
    if (_engine.splitMode) return false;
    if (_showStats) return false;
    if (_engine.demoReady || _demoPlaying) return false; // 演示播放中锁定
    if (_boardAnim) return false; // 棋盘切换动画中锁定
    return true;
  }

  @override
  Widget build(BuildContext context) {
    _scale = (MediaQuery.sizeOf(context).shortestSide / 400).clamp(0.72, 1.0);
    final title = tutorialChapters[chapterIdx]['title'] as String? ?? '';
    return Scaffold(
      body: Container(
        color: _ink,
        child: SafeArea(
          child: Stack(children: [
            // 与游戏一致的布局：信息栏 + 地图 + 操作面板 + 战报
            Column(children: [
              _topBar(title),
              const Divider(color: _borderC, height: 1),
              // 游戏同款信息栏（我方/敌方数字和、基地、指挥部）
              _infoBar(),
              // 地图
              Expanded(child: _boardPanel()),
              // 游戏同款操作面板
              _actionPanel(),
              const Divider(color: _borderC, height: 1),
              // 战报栏
              _logBar(),
            ]),
            // 半透明剧情对话框 + 立绘框（叠加在最底部）
            _storyDialog(),
            // 角色信息大弹窗（80% 屏）
            _statsPanel(),
            // 章节规则总结大窗口（popup，全屏遮罩 + 大卡片）
            _rulePanel(),
            // 拆分确认弹层（最顶层，确保可交互）
            _splitOverlay(),
          ]),
        ),
      ),
    );
  }

  // ── 游戏同款信息栏（仿 GameScreen._infoBar） ──
  Widget _infoBar() {
    final e = _engine;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _pt('我方  基地×${e.myBases}  指挥部×${e.myHqs}', 12, _signal),
            _pt('数字和 ${e.mySum}', 11, _dim),
          ]),
        ),
        Expanded(
          flex: 2,
          child: Column(children: [
            _pt('回合 ${_engine.round}', 13, Colors.white, center: true),
            _pt('地图 ${e.mapLen}/${e.mapLen}', 10, _dim, center: true),
          ]),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _pt('敌方', 12, _enemy),
            _pt('数字和 ${e.enemySum}', 11, _dim),
          ]),
        ),
      ]),
    );
  }

  // ── 游戏同款操作面板（仿 GameScreen._actionBody） ──
  Widget _actionPanel() {
    final e = _engine;
    final compact = MediaQuery.sizeOf(context).shortestSide < 360;
    final sel = e.selUnit;
    return Column(children: [
      if (!compact)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            _pt('边框:', 10, _dim),
            for (final (c, name) in [
              (_signal, '我方'), (_enemy, '敌方'), (_green, '移动/可点'), (_warn, '吞噬/选中'),
            ])
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(children: [_pt('■', 11, c), const SizedBox(width: 2), _pt(name, 10, _dim)]),
              ),
          ]),
        ),
      _actionBody(),
    ]);
  }

  Widget _actionBody() {
    final e = _engine;
    final sel = e.selUnit;
    // 拆分面板已改为全屏弹层（_splitOverlay），这里显示占位提示
    if (e.splitMode) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: _pt('正在拆分…请在弹出的窗口中选择保留值', 13, _dim),
      );
    }
    // 教学等待：引导面板（黄条 + 分步 + 按钮）
    if (e.waiting) return _tutGuidePanel();
    // 选中单位：游戏同款操作按钮
    if (sel != null) {
      final acts = e.availableActions(sel);
      if (acts.isNotEmpty) {
        final labels = {'move': '移动', 'attack': '攻击', 'devour': '吞噬', 'split': '拆分', 'produce': '造兵'};
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            for (final a in acts)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _btn(labels[a] ?? a, () => e.tapButton(a)),
              ),
            _btn('取消', () => setState(() => e.selUnit = null)),
          ]),
        );
      }
    }
    // 无选中：提示文字（仿游戏）
    return Padding(
      padding: const EdgeInsets.all(8),
      child: _pt('点基地造兵 · 点单位行动（行动点用完自动过回合）', 13, _textC),
    );
  }

  // 教学引导气泡（等待操作时显示；像素风：深底细边、低饱和、贴合 UI）
  Widget _tutGuidePanel() {
    final engine = _engine;
    if (engine.waitType == 'action' && engine.selUnit == null && engine.waitCell != null) {
      engine.selUnit = engine.waitCell;
    }
    final sel = engine.selUnit;

    // 像素风气泡外壳：深底 + 1px 细边框 + 小三角
    Widget bubble({required Widget child}) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xE61E1D1A),
          border: Border.all(color: _borderC, width: 1),
        ),
        child: child,
      );
    }

    String? hint;
    String? targetTip;
    Widget? actionBtn;
    if (engine.waitType == 'select') {
      hint = '点击高亮的 ${_waitCellLabel(engine.waitCell)} 选中它';
    } else if (engine.waitType == 'tap' && engine.waitAction == 'produce') {
      hint = sel == null
          ? '点击高亮的 ${_waitCellLabel(engine.waitCell)} 选中它'
          : '再点一下 ${_waitCellLabel(engine.waitCell)} → 造兵';
    } else if (engine.waitType == 'action') {
      final a = engine.waitAction;
      hint = '点击「${_actionLabel(a ?? '')}」';
      // 游戏同款操作按钮横排（跟 GameScreen._actionBody 一致），点击走 tapButton
      if (sel != null) {
        final acts = engine.availableActions(sel);
        if (acts.isNotEmpty) {
          actionBtn = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              for (final act in acts)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _btn(_actionLabel(act), () => engine.tapButton(act)),
                ),
              _btn('取消', () => setState(() => engine.selUnit = null)),
            ]),
          );
        }
      }
    } else if (engine.waitType == 'target') {
      hint = '点击目标格执行';
      // 选目标模式说明（牢大：说明为什么要点攻击后还要选目标）
      targetTip = '攻击范围内有多个目标时才需要手动选——这里演示选目标';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        bubble(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              _pt('▸', 13, _warn),
              const SizedBox(width: 6),
              if (hint != null) _pt(hint, 13, _paper),
              if (sel != null && engine.waitType != 'action') ...[  
                const SizedBox(width: 8),
                _pt('✓ 已选中', 12, _dim),
              ],
            ]),
            if (targetTip != null) ...[  
              const SizedBox(height: 4),
              _pt('· $targetTip', 12, _dim),
            ],
          ]),
        ),
        if (actionBtn != null) actionBtn,
      ]),
    );
  }

  // ── 战报栏（仿 GameScreen._logBar） ──
  Widget _logBar() {
    final log = _engine.log;
    final compact = MediaQuery.sizeOf(context).shortestSide < 360;
    return SizedBox(
      height: compact ? 26 : 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: compact
            ? Align(alignment: Alignment.centerLeft, child: _pt('战报', 10, _dim))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _pt('战报', 10, _dim),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final l in log.length > 4 ? log.sublist(log.length - 4) : log)
                        _pt('· $l', 10, _dim),
                    ]),
                  ),
                ),
              ]),
      ),
    );
  }

  Widget _topBar(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        _pt('AIM · 新手教程', 14, _signal),
        const SizedBox(width: 8),
        _pt('${chapterIdx + 1}/${tutorialChapters.length}', 12, _dim),
        const Spacer(),
        Expanded(
          child: Center(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _paper, fontSize: 13),
            ),
          ),
        ),
        const Spacer(),
        _topBtn('跳过', _showSkipMenu),
        const SizedBox(width: 6),
        _topBtn('设置', () => showSettingsPanel(context, onChanged: () => setState(() {}))),
        const SizedBox(width: 6),
        _topBtn('退出', _confirmExit),
      ]),
    );
  }

  // 顶栏按钮（跳过/设置/退出统一风格）
  Widget _topBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _borderC)),
        child: _pt(label, 12, _paper),
      ),
    );
  }

  void _confirmExit() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('退出教程？', style: TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
        content: const Text('教程进度不会保存，下次从头开始。', style: TextStyle(color: _paper, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续', style: TextStyle(color: _signal, fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startExitAnim();
            },
            child: const Text('退出', style: TextStyle(color: _dim, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 跳过菜单：直接跳到本章实操教学 / 章末总结
  void _showSkipMenu() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('跳到', style: TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
        content: const Text('跳过本章剧情对话，直接进入指定部分。', style: TextStyle(color: _paper, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _engine.skipTo('practice');
            },
            child: const Text('实操教学', style: TextStyle(color: _signal, fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _engine.skipTo('summary');
            },
            child: const Text('章末总结', style: TextStyle(color: _signal, fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── 棋盘面板（仿游戏界面：垂直居中） ──
  Widget _boardPanel() {
    final cells = _animCells ?? _engine.cells; // 动画期间显示动画棋盘（旧棋盘+转变）
    if (cells.isEmpty) {
      return Center(child: _pt('（战场还未展开）', 14, _dim));
    }
    return LayoutBuilder(builder: (ctx, cons) {
      final n = cells.length;
      // 照搬游戏内 GameScreen._mapArea 的格子尺寸公式：
      // 动画期间步距按规则棋盘长度固定算（插桥 8→9 格瞬间不整盘重排塌缩——牢大反馈的观感）
      final stepN = _engine.cells.length;
      final cellSize = ((cons.maxWidth - 12) / stepN).clamp(30.0, 72.0);
      final cellStep = cellSize + 6; // 每格步距（含 margin）
      final waitingGuide = _engine.waiting &&
          (_engine.waitType == 'select' ||
              _engine.waitType == 'tap' ||
              _engine.waitType == 'target');
      // wait target：聚光灯应指向目标格（waitTarget），不是自己的单位格（waitCell）
      final waitCell = waitingGuide
          ? (_engine.waitType == 'target' ? _engine.waitTarget : _engine.waitCell)
          : null;
      // 展示引导：非等待时 highlight + arrow → 高亮格也亮聚光灯+箭头（绿色）
      final showGuide = !_engine.waiting &&
          _engine.highlightCells.isNotEmpty &&
          _engine.arrowFrom != null;
      // 移动中的单位：浮层渲染（盖在所有格子之上，从 stepFrom 平移到 stepFrom+subDirn）
      final mv = _tutMv;
      final mCtrl = _tutStepCtrl;
      // bound=true：滚木已绑定棋盘格（压着单位），浮层隐藏——对齐对战端
      final moving = mv != null &&
          mCtrl != null &&
          (mCtrl.isAnimating || _tutRollPaused) &&
          mv['bound'] != true;
      double? mvLeft;
      if (moving) {
        final t = Curves.easeInOut.transform(mCtrl.value); // 加速→减速（停顿中 value=1 → 到达格）
        final floatIdx = mv['stepFrom'] as int;
        final subDirn = (mv['subDirn'] as int?) ?? (mv['dirn'] as int);
        mvLeft = 3 + floatIdx * cellStep + t * subDirn * cellStep;
        // 浮层跟随格子的插入/删除位移（否则插入动画推格子时，浮层不动=滚木像回到初始位置）
        mvLeft += _tutCellOffset(floatIdx, cellStep).dx;
      }
      return Stack(children: [
        // 居中棋盘
        Center(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Stack(children: [
                Row(
                children: List.generate(n, (i) {
                  final c = cells[i];
                  final hl = _engine.highlightCells.contains(i);
                  final isSel = _engine.selUnit == i;
                  final isTarget = waitCell == i;
                  final isGuide = showGuide && hl;
                  // 正在平移的单位：棋盘格内隐藏（由顶层浮层渲染），格子只露背景
                  final isMovingUnit = moving &&
                      c.isUnit &&
                      c.v == mv['v'] &&
                      c.o == mv['o'] &&
                      i == mv['stepFrom'];
                  Widget cell = Transform.translate(
                    offset: _tutCellOffset(i, cellStep),
                    child: _tutInsertWrap(
                        i, _cellWidget(c, i, cellSize, hl, isSel, isTarget, isGuide, hideIcon: isMovingUnit)),
                  );
                  // 棋盘切换动画：直接驱动现有格子元素
                  if (_boardAnim) {
                    final isUnit = c.isUnit;
                    if (_boardEntering) {
                      // 入场：中间先落、对称展开、数字后弹
                      cell = BoardEnterCell(
                        cell: cell,
                        index: i,
                        count: n,
                        cellSize: cellSize,
                        isUnit: isUnit,
                      );
                    } else {
                      // 退场：数字先朝自家方向移出淡出（我方朝左、敌方朝右），
                      // 停 100ms 后格子壳再退
                      final box = Container(
                        width: cellSize,
                        height: cellSize,
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: _cellColor(c),
                          border: Border.all(
                            color: _cellBorder(i, c, hl, isSel),
                            width: isSel ? 3 : (hl ? 3 : 1.5),
                          ),
                        ),
                      );
                      final icon = c.isUnit ? _cellIcon(c, cellSize) : null;
                      cell = BoardExitCell(
                        box: box,
                        icon: icon,
                        index: i,
                        count: n,
                        cellSize: cellSize,
                        isMine: c.o == 0,
                      );
                    }
                  }
                  // 退出动画：整盘数字朝自家方向飞走淡出，格子壳随后淡
                  if (_exiting) {
                    final box = Container(
                      width: cellSize,
                      height: cellSize,
                      margin: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: _cellColor(c),
                        border: Border.all(
                          color: _cellBorder(i, c, hl, isSel),
                          width: isSel ? 3 : (hl ? 3 : 1.5),
                        ),
                      ),
                    );
                    final icon = c.isUnit ? _cellIcon(c, cellSize) : null;
                    cell = BoardExitCell(
                      box: box,
                      icon: icon,
                      index: i,
                      count: n,
                      cellSize: cellSize,
                      isMine: c.o == 0,
                    );
                  }
                  // 打击动画层：刀光 + 旧数字淡出（露出新数字）——与游戏本体同款
                  final hitFx = <Widget>[
                    for (final h in _hits)
                      if (h.i == i)
                        HitFx(
                          key: ValueKey('tuthit${h.id}'),
                          packId: 'default', // 教程固定默认像素包
                          from: h.from,
                          to: h.to,
                          imgSize: (cellSize * 0.9).clamp(20.0, 64.0),
                          cellSize: cellSize,
                          onDone: () => _removeTutHit(h.id),
                        ),
                  ];
                  if (!_exiting && hitFx.isNotEmpty) {
                    // 必须给固定尺寸约束！HitFx 内部无尺寸的 Container（白闪/红边）靠父级约束撑开，
                    // 教程棋盘在水平滚动区里是 unbounded，直接放会收缩成 0 宽 → 红边变一条红竖线
                    cell = SizedBox(
                      width: cellSize,
                      height: cellSize,
                      child: Stack(alignment: Alignment.center, children: [cell, ...hitFx]),
                    );
                  }
                  return GestureDetector(
                    key: ValueKey('tutcell${c.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _onCellTap(i),
                    child: cell,
                  );
                }),
                ),
                // 顶层：平移中的单位浮层（盖住所有格子，不被邻格内容遮挡）
                if (moving && mvLeft != null)
                  Positioned(
                    left: mvLeft,
                    top: 3,
                    width: cellSize,
                    height: cellSize,
                    child: Center(
                      child: _pix('${mv['v']}', (cellSize * 0.9).clamp(20.0, 64.0)),
                    ),
                  ),
                // 删除格动画：残影（格子壳 + 内容）缩没 + 补位
                for (final r in _removes)
                  Positioned(
                    left: 3 + r.oldIdx * cellStep,
                    top: 3,
                    width: cellSize,
                    height: cellSize,
                    child: AnimatedBuilder(
                      animation: r.ctrl,
                      builder: (ctx, _) {
                        final v = r.ctrl.value;
                        // 内容 0~10% 快速消失（转变即时，被白闪盖住）
                        final contentOpacity =
                            (1 - Curves.easeOut.transform(const Interval(0.0, 0.1).transform(v))).clamp(0.0, 1.0);
                        // 白闪：0~15% 快速变白 → 15%~55% 慢慢透明
                        final fIn = Curves.easeOut.transform(const Interval(0.0, 0.15).transform(v));
                        final fOut = Curves.easeOut.transform(const Interval(0.15, 0.55).transform(v));
                        final flashOpacity = (fIn * (1 - fOut) * 0.45).clamp(0.0, 1.0);
                        final t2 = Curves.easeIn.transform(const Interval(0.55, 1.0).transform(v));
                        return Opacity(
                          opacity: (1 - t2).clamp(0.0, 1.0),
                          child: Transform.translate(
                            offset: Offset(0, t2 * 18),
                            child: Transform.scale(
                              scale: (1 - 0.75 * t2).clamp(0.0, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E1D1A),
                                  border: Border.all(color: const Color(0xFF5A554C), width: 2),
                                ),
                                child: Stack(alignment: Alignment.center, children: [
                                  Opacity(
                                    opacity: contentOpacity,
                                    child: Center(
                                      child: _cellIcon(r.cell, (cellSize * 0.9).clamp(20.0, 64.0)),
                                    ),
                                  ),
                                  Opacity(
                                    opacity: flashOpacity,
                                    child: Container(color: const Color(0xFFFFFFFF)),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ]);
    });
  }

  // 动画期间格子位移：插入推开 + 删除补位（与游戏本体同款）
  Offset _tutCellOffset(int i, double step) {
    double dx = 0;
    for (final a in _inserts) {
      final t = Curves.easeOutCubic.transform(const Interval(0.0, 0.75).transform(a.ctrl.value));
      if (i != a.idx) dx -= step * 0.5 * (1 - t);
      if (i > a.idx) dx += step * (1 - t);
    }
    for (final r in _removes) {
      final t = Curves.easeOutCubic.transform(const Interval(0.5, 1.0).transform(r.ctrl.value));
      if (i < r.oldIdx) {
        dx -= step * 0.5 * (1 - t);
      } else {
        dx += step * 0.5 * (1 - t);
      }
    }
    final sc = _tutShiftCtrl;
    if (sc != null && sc.isAnimating) {
      final t = Curves.easeOutCubic.transform(sc.value);
      if (i < _tutShiftAt) {
        dx -= step * 0.5 * (1 - t);
      } else {
        dx += step * 0.5 * (1 - t);
      }
    }
    return Offset(dx, 0);
  }

  // 插入动画包装：先等右侧推开，新格再"由远及近"弹入（与游戏本体同款）
  Widget _tutInsertWrap(int i, Widget child) {
    for (final a in _inserts) {
      if (a.idx == i) {
        return AnimatedBuilder(
          animation: a.ctrl,
          builder: (ctx, _) {
            final t = Curves.easeOutBack
                .transform(const Interval(0.75, 1.0).transform(a.ctrl.value));
            return Transform.translate(
              offset: Offset(0, -20 * (1 - t)),
              child: Transform.scale(scale: 0.15 + 0.85 * t, child: child),
            );
          },
        );
      }
    }
    return child;
  }

  // 单个格子 + 聚光灯引导（纯 widget：发光边框 + 浮动箭头）
  // isTarget = 等待玩家操作的目标格（黄）；isGuide = 展示用高亮引导格（绿）
  // hideIcon = 移动浮层中单位（格子只露背景，数字由浮层渲染）
  Widget _cellWidget(TutCell c, int i, double cellSize, bool hl, bool isSel, bool isTarget, bool isGuide,
      {bool hideIcon = false}) {
    final cell = Container(
      width: cellSize,
      height: cellSize,
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _cellColor(c),
        border: Border.all(
          color: _cellBorder(i, c, hl, isSel),
          width: isSel ? 3 : (hl ? 3 : 1.5),
        ),
      ),
      child: Center(child: hideIcon ? null : _cellIcon(c, cellSize)),
    );
    if (!isTarget && !isGuide) return cell;
    final glowColor = isTarget ? _glowGold : _glowGreen;
    // 目标/引导格：聚光灯（呼吸发光 + 浮动箭头 [+ 点这里气泡]）
    return Stack(clipBehavior: Clip.none, children: [
      cell,
      // 发光边框（动画，低饱和）
      Positioned.fill(
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 900),
            builder: (ctx, t, _) {
              final glow = 0.5 + 0.5 * math.sin(t * 2 * math.pi * 2);
              return Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Color.lerp(glowColor, const Color(0xFF3A352C), glow)!,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: glowColor.withOpacity(0.35 + 0.25 * glow),
                      blurRadius: 8 + 6 * glow,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
      if (isTarget)
        // 等待操作：上方像素风气泡 + 浮动箭头
        Positioned(
          top: -56,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 900),
              builder: (ctx, t, _) {
                final dy = math.sin(t * 2 * math.pi * 2) * 4;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  // 像素风气泡（深底细边）
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xE61E1D1A),
                      border: Border.all(color: _borderC, width: 1),
                    ),
                    child: Text('点这里',
                        style: TextStyle(
                            color: _glowGold,
                            fontSize: 12 * _scale,
                            fontWeight: FontWeight.bold)),
                  ),
                  // 浮动箭头
                  Transform.translate(
                    offset: Offset(0, dy),
                    child: Icon(Icons.keyboard_arrow_down,
                        color: _glowGold, size: 24 * _scale),
                  ),
                ]);
              },
            ),
          ),
        )
      else
        // 展示引导：只要浮动箭头（暗绿，指目标格）
        Positioned(
          top: -38,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 900),
              builder: (ctx, t, _) {
                final dy = math.sin(t * 2 * math.pi * 2) * 4;
                return Transform.translate(
                  offset: Offset(0, dy),
                  child: Icon(Icons.keyboard_arrow_down,
                      color: _glowGreen, size: 24 * _scale),
                );
              },
            ),
          ),
        ),
    ]);
  }

  void _onCellTap(int i) {
    if (_exiting) return;
    if (_engine.waiting) {
      // 教学等待：必须完成正确操作才能继续（点错静默忽略）
      _engine.tapCell(i);
      return;
    }
    // 非教学等待：棋盘点击不自己处理，交给全屏热点层统一推进
    // （否则热点层 GestureDetector + 棋盘 GestureDetector 会双重触发 _tapNext）
  }

  Color _cellColor(dynamic c) {
    if (c.isB) return const Color(0xFF2A2824);
    if (c.v == 0) return _cellEven;
    if (c.o == 0) return const Color(0xFF262220);
    return const Color(0xFF241C1A);
  }

  Color _cellBorder(int i, TutCell c, bool hl, bool isSel) {
    if (isSel) return _warn;
    if (hl) return _green;
    if (c.isB) return _borderC;
    if (c.v == 0) return _borderC;
    if (c.o == 0) return _signal;
    return _enemy;
  }

  Widget _cellIcon(TutCell c, double size) {
    // 照搬游戏内 GameScreen._cellIcon 的尺寸公式
    final imgSize = (size * 0.9).clamp(20.0, 64.0);
    if (c.isB) return _pix('dash', imgSize);
    if (c.v == 0) return _pix('0', imgSize);
    return _pix('${c.v}', imgSize);
  }

  Widget _pix(String file, double size) {
    return Image.asset('assets/art/default/units/$file.png',
        width: size, height: size, fit: BoxFit.contain);
  }

  // ── 底部区域 ──
  String _waitCellLabel(int? i) {
    if (i == null) return '';
    final c = _engine.cells[i];
    if (c.v == 8) return '兵营';
    if (c.v == 9) return '指挥部';
    return c.v > 0 ? '${c.v}号单位' : '该格';
  }

  String _actionLabel(String a) {
    return {'move': '移动', 'attack': '攻击', 'devour': '吞噬', 'split': '拆分', 'produce': '造兵'}[a] ?? a;
  }

  Widget _splitPanel() {
    final engine = _engine;
    final v = (engine.splitUnitIdx) != null
        ? engine.cells[engine.splitUnitIdx!].v
        : 5;
    final keep = engine.splitKeep ?? 1;
    final out = v - keep;
    final locked = engine.waitKeep != null; // 剧情锁定拆法
    final keepOk = keep <= 4;
    final outOk = out <= 4;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (locked) ...[  
        _pt('剧情要求：拆成 $keep + $out', 15, _warn),
        const SizedBox(height: 4),
      ],
      _pt('拆分 $v：', 16, _paper),
      const SizedBox(height: 6),
      _pt('左侧保留  $keep ${keepOk ? '（可过桥）' : '（重，过桥塌）'}', 14, keepOk ? _green : _enemy),
      _pt('右侧拆出  $out ${outOk ? '（可过桥）' : '（重，过桥塌）'}', 14, outOk ? _green : _enemy),
      const SizedBox(height: 8),
      Slider(
        value: keep.clamp(1, v - 1).toDouble(),
        min: 1,
        max: (v - 1).toDouble(),
        divisions: v - 2,
        activeColor: locked ? _dim : _signal,
        inactiveColor: const Color(0xFF2A2824),
        onChanged: locked
            ? null // 剧情锁定：不可拖动
            : (d) => setState(() => engine.splitKeep = d.round()),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _btn('确 认', () => engine.confirmSplit()),
        const SizedBox(width: 10),
        _btn('取消', () => engine.cancelSplit()),
      ]),
    ]);
  }

  // 拆分确认弹层（全屏模态，盖过一切，确保 Slider/按钮可点）
  Widget _splitOverlay() {
    if (!_engine.splitMode) return const SizedBox.shrink();
    final size = MediaQuery.sizeOf(context);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // 吞掉背景点击，防止误触
        child: Container(
          color: const Color(0xB8000000),
          alignment: Alignment.center,
          child: Container(
            width: size.width * 0.86,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1916),
              border: Border.all(color: _warn, width: 2),
              boxShadow: const [
                BoxShadow(color: Color(0x88000000), blurRadius: 20, spreadRadius: 4),
              ],
            ),
            child: _splitPanel(),
          ),
        ),
      ),
    );
  }

  // ── 角色信息大弹窗（80% 屏：左立绘 + 右介绍） ──
  // ── 章节规则总结大窗口：全屏遮罩 + 大卡片（像角色卡一样），点击关闭并进入下一章 ──
  Widget _rulePanel() {
    if (!_engine.popupOpen) return const SizedBox.shrink();
    final size = MediaQuery.sizeOf(context);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _engine.dismissPopup();
          _maybeNextChapter();
        },
        child: Container(
          color: const Color(0xB8000000),
          alignment: Alignment.center,
          child: Container(
            width: size.width * 0.88,
            height: size.height * 0.82,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1916),
              border: Border.all(color: _borderC, width: 2),
              boxShadow: const [
                BoxShadow(color: Color(0x88000000), blurRadius: 20, spreadRadius: 4),
              ],
            ),
            child: Column(children: [
              // 标题
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                child: _pt('📜 ${_engine.popupTitle}', 19, _signal),
              ),
              const Divider(color: Color(0xFF5A5680), height: 1),
              // 规则明细（可滚动，内容细致）
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final l in _engine.popupLines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 9),
                          child: _pt(l.startsWith('·') || l.startsWith('◆') ? l : '· $l',
                              14, _paper, height: 1.55),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(color: Color(0xFF5A5680), height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: _pt('（点击任意处进入下一章）', 12, _dim),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _statsPanel() {
    if (!_showStats || _engine.stats.isEmpty) return const SizedBox.shrink();
    final entry = _engine.stats.entries.first;
    final key = entry.key;
    final desc = entry.value;
    final file = _portraitFile(key);
    final name = _portraitName(key);
    final size = MediaQuery.sizeOf(context);
    // 属性第一行，背景故事后续行
    final lines = desc.split('\n');
    final attr = lines.isNotEmpty ? lines.first : '';
    final bio = lines.length > 1 ? lines.sublist(1) : <String>[];
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          // 关闭角色卡 → 直接进入下一对话（不用再点击一次）
          setState(() => _showStats = false);
          if (!_engine.waiting && !_engine.autoPause && !_engine.popupOpen) {
            _engine.advance();
            _maybeNextChapter();
          }
        },
        child: Container(
          color: const Color(0xB8000000),
          alignment: Alignment.center,
          child: Container(
            width: size.width * 0.86,
            height: size.height * 0.8,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1916),
              border: Border.all(color: _borderC, width: 2),
              boxShadow: const [
                BoxShadow(color: Color(0x88000000), blurRadius: 20, spreadRadius: 4),
              ],
            ),
            child: Row(children: [
              // 左：立绘框（框适应立绘：宽高比严格等于立绘 160:213，分割栏贴立绘）
              if (file != null)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: AspectRatio(
                    aspectRatio: 160 / 213,
                    child: Image.asset(
                      'assets/art/default/portraits/$file.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                )
              else
                SizedBox(
                  width: 120,
                  child: Center(child: _pt(name, 40, _dim)),
                ),
              // 分隔线
              Container(width: 2, color: _borderC),
              // 右：介绍
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _pt(name, 30, _signal),
                      const SizedBox(height: 8),
                      _pt('『$key 号』', 16, _dim),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2824),
                          border: Border.all(color: _borderC, width: 1),
                        ),
                        child: _pt(attr, 16, _warn, height: 1.5),
                      ),
                      if (bio.isNotEmpty) ...[  
                        const SizedBox(height: 16),
                        _pt('—— 背景 ——', 13, _dim),
                        const SizedBox(height: 8),
                        for (final b in bio)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _pt(b, 16, _paper, height: 1.5),
                          ),
                      ],
                      const Spacer(),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _pt('▼ 点击关闭', 14, _dim),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  String _portraitName(String key) {
    switch (key) {
      case '1':
        return 'Primus';
      case '2':
        return 'Secundus';
      case '3':
        return 'Tertius';
      case '4':
        return 'Quartus';
      case '5':
        return 'Quintus';
      case '7':
        return 'Septimus';
      case '前指挥官':
        return '前指挥官'; // 牢大：别给非数字角色加"号"后缀
      case '旁白':
        return '旁白';
      default:
        return '$key号';
    }
  }

  // ── 剧情对话框（底部半透明浮层 + 左侧立绘框接底） ──
  Widget _storyDialog() {
    final isWaiting = _engine.waiting;
    // 教学等待时：整个对话框隐藏（不挡棋盘/按键），指导改用气泡
    if (isWaiting) return const SizedBox.shrink();
    final speaker = _engine.currentSpeaker;
    final portrait = _portraitFile(speaker ?? '');
    return Align(
      alignment: Alignment.bottomCenter,
      // 热点 = 对话框本体区域（不覆盖顶部按钮/棋盘）：点击对话框推进剧情
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _canAdvance ? _tapNext : null,
        child: Stack(clipBehavior: Clip.none, children: [
          // 半透明对话框
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 140),
            // 左侧预留立绘框空间（立绘+空隙）；右侧留足边距，字幕不要贴到界面右缘、早点换行
            padding: EdgeInsets.fromLTRB((portrait != null ? 210 : 16) * _scale, 12, 48, 14),
            decoration: BoxDecoration(
              color: const Color(0x8A110F0D),
              border: Border(top: BorderSide(color: _borderC, width: 1)),
            ),
            child: _storyContent(),
          ),
          // 立绘框：缩小贴左下角，不挡地图
          if (portrait != null &&
              !isWaiting &&
              _engine.choiceOptions == null &&
              !_engine.popupOpen &&
              !_engine.autoPause)
            Positioned(
              left: 0,
              bottom: 0,
              width: 118 * _scale,
              height: 168 * _scale,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1916),
                    border: Border.all(color: _borderC, width: 1),
                  ),
                  child: ClipRect(
                    child: Image.asset(
                      'assets/art/default/portraits/$portrait.png',
                      fit: BoxFit.contain,
                      alignment: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _storyContent() {
    final isWaiting = _engine.waiting;
    if (_engine.autoPause) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xCC1A1916),
              border: Border.all(color: _warn, width: 1.5),
            ),
            child: _pt('⏸ 演示已结束 · 看完了点任意处继续', 14, _warn),
          ),
        ],
      );
    }
    // 选择：选项横置中间（Arknights 风）
    if (_engine.choiceOptions != null) {
      final opts = _engine.choiceOptions!;
      return Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < opts.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                InkWell(
                  onTap: () => _choose(opts[i]),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 140, minHeight: 56),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xF51A1916),
                      border: Border.all(color: _borderC, width: 1),
                      boxShadow: const [
                        BoxShadow(color: Color(0x88000000), offset: Offset(0, 2), blurRadius: 4),
                      ],
                    ),
                    child: _pt(opts[i], 15, _paper, center: true),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    // 弹窗（规则总结）已由大窗口 _rulePanel 接管，这里不再显示
    // 正常对话
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isWaiting)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFFFD36A),
              border: Border.all(color: const Color(0xFFB12718), width: 2),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('⏳', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              _pt('轮到你操作了！请看下方提示', 13, const Color(0xFF11110F)),
            ]),
          ),
        if (_engine.currentSpeaker != null) ...[  
          _pt('『${_portraitName(_engine.currentSpeaker!)}』', 14, _speakerColor(_engine.currentSpeaker!)),
          const SizedBox(height: 4),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _pt(_display.isEmpty ? ' ' : _display, 15, _paper, height: 1.5),
          ),
          if (_typeTimer != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _pt('▌', 15, _warn),
            ),
        ]),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: _pt(isWaiting ? '📍 请按提示操作' : '▼ 点击继续', 12, _dim),
        ),
      ],
    );
  }

  Color _speakerColor(String s) {
    switch (s) {
      case '前指挥官':
        return _warn;
      case '旁白':
        return _dim;
      default:
        return _signal;
    }
  }

  // ── 浮动立绘：放大、贴右下、字幕栏之下 ──
  String? _portraitFile(String speaker) {
    switch (speaker) {
      case '前指挥官':
        return 'excommander';
      case '1':
        return 'primus';
      case '2':
        return 'secundus';
      case '3':
        return 'tertius';
      case '4':
        return 'quartus';
      case '5':
        return 'quintus';
      case '7':
        return 'septimus';
      default:
        return null;
    }
  }

  Widget _btn(String label, VoidCallback cb, {bool small = false}) {
    return InkWell(
      onTap: cb,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: (small ? 12 : 18) * _scale, vertical: (small ? 8 : 10) * _scale),
        decoration: BoxDecoration(
          color: const Color(0xFFFF4E35),
          border: Border.all(color: _borderC, width: 2),
        ),
        child: _pt(label, small ? 13 : 14, Colors.white, center: true),
      ),
    );
  }

  Widget _pt(String s, double size, Color c, {bool center = false, bool bold = true, double height = 1.3}) {
    return Text(s,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: TextStyle(
            color: c,
            fontSize: size * _scale,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            height: height));
  }
}

// 插入格子动画：新格从无到有弹入（与游戏本体同款）
class _TutInsertAnim {
  final int id;
  final int idx;
  final AnimationController ctrl;
  _TutInsertAnim({required this.id, required this.idx, required this.ctrl});
}

// 删除格子动画：旧格缩没消失（与游戏本体同款）
class _TutRemoveAnim {
  final int id;
  final int oldIdx;
  final TutCell cell;
  final AnimationController ctrl;
  _TutRemoveAnim({required this.id, required this.oldIdx, required this.cell, required this.ctrl});
}
