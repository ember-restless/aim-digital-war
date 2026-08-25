import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../art/art_manager.dart';
import '../net/socket.dart';
import '../core/settings_store.dart';
import '../core/bgm_manager.dart';
import '../widgets/hit_fx.dart';
import '../widgets/settings_panel.dart';
import '../widgets/game_over_anim.dart';
import '../tutorial/board_anim.dart';
import '../game/unit_cards.dart';

const _myC = Color(0xFFFF4E35);     // signal 橙红
const _enemyC = Color(0xFFB12718);   // 深红
const _warnC = Color(0xFFFFD36A);    // 橙黄
const _dimC = Color(0xFF77736B);
const _textC = Color(0xFF3E3628);    // 纸上深字
const _panelC = Color(0xFFFFF5DC);   // paper 米白
const _cellEven = Color(0xFF1E1D1A); // 深底棋盘
const _cellOdd = Color(0xFF181715);
const _greenC = Color(0xFF61D39E);   // 亮绿
const _signalC = Color(0xFFFF4E35);  // 橙红

class GameScreen extends StatefulWidget {
  final AIMSocket socket;
  final dynamic state;
  final String packId;
  final dynamic over;
  final VoidCallback onBack;
  const GameScreen({super.key, required this.socket, required this.state, required this.packId, this.over, required this.onBack});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with TickerProviderStateMixin {
  int? selUnit;
  String? selAction;
  int _kbCursor = 0; // 键盘光标（PC/Web 快捷键），指向格子下标
  List<dynamic>? splitOpts;
  dynamic splitFull;
  dynamic state;
  dynamic over;
  List<dynamic>? pending;
  int? splitSliderI;   // 拆分滚动条目标单位
  double splitKeep = 1;
  int round = 1;
  double _scale = 1;   // 小屏缩放系数（手表/窄屏自动缩小字号与控件）

  // ── 战斗语音（选中/移动/攻击 × 6 角色 × 2 句随机）──
  // 互斥：单播放器，播放中新触发直接丢弃（不排队不打断），播完才响应下一次
  // 音频焦点：全部 none——音效/语音/BGM 互不抢焦点（否则音效一播会把语音暂停，onPlayerComplete 不触发 → 语音永久哑）
  static final AudioContext _voiceContext = AudioContext(
    android: AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
    iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient, options: {}),
  );
  static final AudioContext _sfxContext = _voiceContext;
  final AudioPlayer _battleVoice = AudioPlayer()..setAudioContext(_voiceContext);
  bool _voiceBusy = false;
  Timer? _voiceWatchdog; // 看门狗：3.5s 强制解锁，防任何意外卡死语音
  final math.Random _voiceRand = math.Random();
  static const Set<int> _voiceUnits = {1, 2, 3, 4, 5, 7}; // 6 滚木/8 基地/9 指挥无语音

  // ── 8-bit 战斗音效（独立通道，不与语音互斥；4 播放器轮转防连续音效互相吞）──
  final List<AudioPlayer> _sfxPool = List.generate(4, (_) => AudioPlayer()..setAudioContext(_sfxContext));
  int _sfxIdx = 0;

  void _playSfx(String name) {
    if (SettingsStore.sfxVolume <= 0) return;
    final p = _sfxPool[_sfxIdx];
    _sfxIdx = (_sfxIdx + 1) % _sfxPool.length;
    p.setVolume(SettingsStore.sfxVolume);
    p.play(AssetSource('audio/sfx/sfx_$name.wav')).catchError((_) {});
  }

  bool _myPhaseSeen = false;

  // ── 对局入场：地图展开动画（中间先落、对称向两侧飞入） ──
  bool _boardEntered = false; // 入场动画完成后置 true（移除动画包装）
  bool _exiting = false; // 退出动画播放中（数字朝自家方向飞走淡出后真正退出）
  Timer? _enterTimer;

  // ── 逐格移动动画：每移动一格 = 一次 180ms easeInOut 平移 ──
  // 多格移动（骑兵2格/滚木3格）= 连续多次平移串行；1 格移动也有平移
  List<dynamic>? _animCells;   // 动画中的棋盘（覆盖显示，以最终棋盘为底）
  AnimationController? _stepCtrl; // 当前这一步的平移进度 0→1
  Map<String, dynamic>? _mv;   // 移动单位信息 {v,o,dirn,steps,oldIdx,newIdx,stepFrom}
  bool _animLock = false;      // 动画期间锁定操作
  Map<String, dynamic>? _deferredRoll; // 行动动画未结束时缓存的滚木动画（播完再滚）
  static const int _moveStepMs = 260; // 每格平移时长（含加速/减速段，牢大定 260ms 观感最好）
  static const int _rollStepGapMs = 400; // 滚木每步播完后的间隔（牢大 2026-08-18：每步间隔太短难反应，加长）
  static const int _rollCrushPauseMs = 1050; // 压单位停顿（原 660ms，牢大要停久一点看得清）
  static const int _rollDeadPauseMs = 800; // 死亡停顿（原 400ms）

  // ── 插入/删除格子动画（插桥弹入 / 塌桥吞噬删格补位） ──
  final List<_InsertAnim> _inserts = []; // 插入动画中的格子（新棋盘索引）
  AnimationController? _shiftCtrl; // 删除补位专用（吞噬删格用，无残影）
  int _shiftAt = -1; // 删除补位位置
  int _animId = 0;
  double _layoutWidth = 0; // 棋盘布局宽度（LayoutBuilder 提供，插入动画居中补偿用）

  // 插入格弹入动画：先让右侧格子推开腾位（0~75%），空位出现后再弹入（75%~100%）
  void _addInsertAnim(int idx) {
    final id = ++_animId;
    final ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _inserts.add(_InsertAnim(id: id, idx: idx, ctrl: ctrl));
    ctrl.addListener(() { if (mounted) setState(() {}); });
    ctrl.forward().whenComplete(() {
      ctrl.dispose();
      if (mounted) setState(() => _inserts.removeWhere((a) => a.id == id));
    });
    if (mounted) setState(() {});
  }

  // 动画期间格子位移：
  // - 插入：平滑推开——位移按「实际居中变化 + 右侧补 1 格」精确计算：
  //   左格跟随居中位移（窄屏溢出=0，格子不动），右格从旧位置无缝滑到新位置；插入格由 _insertWrap 弹入
  // - 删除：整体右移半格（居中保持）+ 删除点右侧格子左移一格（补位）
  // [forFloat] 浮层专用：只跟随插入推挤，不跟随删除位移（否则撞桥死停时浮层被带偏 0.5 格，牢大 2026-08-18）
  Offset _cellOffset(int i, double step, {bool forFloat = false}) {
    double dx = 0;
    for (final a in _inserts) {
      final t = Curves.easeOutCubic.transform(const Interval(0.0, 0.75).transform(a.ctrl.value));
      // 2026-08-18 精确公式：插桥瞬间棋盘 n-1→n 格，居中偏移变化 = C(n-1)-C(n)
      // （棋盘比屏幕窄才居中；手机/手表棋盘恒溢出=0）。配合固定步距，t=0 时每格正好在旧位置，零跳变
      final n = _animCells?.length ?? 0;
      final w = _layoutWidth;
      final centerDelta = n > 0
          ? (((w - (n - 1) * step) / 2).clamp(0.0, double.infinity) -
              ((w - n * step) / 2).clamp(0.0, double.infinity))
          : 0.0;
      if (i != a.idx) dx += centerDelta * (1 - t); // 左格：跟随居中位移（溢出时=0 不动）
      if (i > a.idx) dx -= step * (1 - t); // 右格：额外左移 1 格（从旧位置滑到新位置）
    }
    if (!forFloat) {
      // 删除补位（吞噬删格同一套，牢大 2026-08-18 23:50：基本动画只写一套）：
      // 左侧右移半格、删除点及右侧左移半格
      final sc = _shiftCtrl;
      if (sc != null && sc.isAnimating) {
        final t = Curves.easeOutCubic.transform(sc.value);
        if (i < _shiftAt) {
          dx -= step * 0.5 * (1 - t);
        } else {
          dx += step * 0.5 * (1 - t);
        }
      }
    }
    return Offset(dx, 0);
  }

  // 插入动画包装：先等右侧推开腾位（75%），新格再“由远及近”弹入——
  // 从远处（scale 0.15 + 上方位移 -20px）飘近落位，easeOutBack 轻微过冲
  Widget _insertWrap(int i, Widget child) {
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

  // ── lastAction 剧本驱动（服务端下发行动结果，客户端照演，不用 diff 猜） ──
  int _lastSeq = 0; // 已播放的剧本序号（服务端每次行动 +1，只播新序号）
  int _lastRollSeq = 0; // 已播放的滚木剧本序号（服务端滚木自动阶段 +1，只播新序号）
  int _lastRollStepSeq = 0; // 已播放的逐步滚木步序号（规则层每步 +1，只播新步）
  bool _rollActsDriven = false; // 本回合滚木是否已由 rollActs 逐步驱动（热座/局域网）
  bool _rollDead = false; // 滚木滚动中撞毁（提前结束动画）
  bool _rollPaused = false; // 滚木压单位停顿中（浮层保持显示在到达格，不消失）
  bool _rollBridgeCollapse = false; // 撞桥死：死停后播桥格（含滚木 6）整体删除动画
  int _rollBridgeAt = -1; // 撞桥的桥格位置
  DateTime? _stallSince;  // 2026-08-20 动画锁卡死检测：_animLock=true 但无动画控制器在播的起始时间
  int _fakeId = 0;        // 2026-08-20 动画层假 id 全局计数（负值向下递增，跨动画唯一，防 Duplicate keys）

  // ── 打击动画（被攻击：刀光 + 数字渐变） ──
  final List<HitFxData> _hits = [];
  int _hitId = 0;

  @override
  // ── 对局内快捷消息（Kards 式）：半透明面板点短语发送，不弹键盘 ──
  bool _chatOpen = false;
  final List<({String text, int until})> _chatMsgs = [];
  static const List<String> _quickMsgs = [
    '你好！', '打得不错！', '这波不亏', '谢谢你',
    '我的失误', '运气不错', '准备进攻！', '防守！',
    '滚木来了！！', '拆桥！', '稳着来', '喵～',
  ];

  void _toggleChat() => setState(() => _chatOpen = !_chatOpen);

  void _sendQuickMsg(String text) {
    final s = state;
    final me = s?['yourIdx'];
    final names = (s?['names'] as List?) ?? ['玩家1', '玩家2'];
    final myName = (me is int && me >= 0 && me < names.length) ? '${names[me]}' : '我';
    _pushChat('$myName：$text');
    setState(() => _chatOpen = false);
    if (s?['hotseat'] == true) return; // 热座本地显示（同屏可见）
    widget.socket.emit('ingame_chat', {'msg': text});
  }

  void _handleInGameChat(dynamic data) {
    final m = data as Map?;
    if (m == null) return;
    _pushChat('${m['name']}：${m['msg']}');
  }

  void _pushChat(String text) {
    _chatMsgs.add((text: text, until: DateTime.now().millisecondsSinceEpoch + 3500));
    while (_chatMsgs.length > 4) _chatMsgs.removeAt(0);
    if (mounted) setState(() {});
  }

  // 快捷消息面板（半透明，右上角）
  Widget _chatPanel() {
    return Positioned(
      top: 52, right: 6,
      child: Container(
        width: 260,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xE61A1916),
          border: Border.all(color: const Color(0xFF5A554C), width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pt('快捷消息 · 点一下发送', 10, _dimC),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in _quickMsgs)
              InkWell(
                onTap: () => _sendQuickMsg(m),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: const Color(0xFF5A554C), width: 1)),
                  child: _pt(m, 12, _panelC),
                ),
              ),
          ]),
        ]),
      ),
    );
  }

  // 消息浮层（左下角 log 上方，3.5s 淡出）
  Widget _chatFloat() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final alive = _chatMsgs.where((m) => m.until > now).toList();
    if (alive.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 8, bottom: 64,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xB31A1916),
          border: Border.all(color: const Color(0xFF5A554C), width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final m in alive) _pt(m.text, 12, _panelC),
        ]),
      ),
    );
  }

  void initState() {
    super.initState();
    state = widget.state;
    over = widget.over;
    // 全局键盘监听：不依赖焦点，对局内快捷键必定生效（PC/Web）
    HardwareKeyboard.instance.addHandler(_handleKey);
    // 快捷消息接收：包装上层 onEvent（联机/局域网/热座通用；热座无对端，仅本地显示）
    final prev = widget.socket.onEvent;
    widget.socket.onEvent = (event, data) {
      prev?.call(event, data);
      if (event == 'ingame_chat') _handleInGameChat(data);
    };
    // 对战：战斗 BGM
    BgmManager.instance.playBattle();
    // 入场：地图展开动画期间锁定操作
    _animLock = true;
    _enterTimer = Timer(const Duration(milliseconds: 950), () {
      if (!mounted) return;
      setState(() {
        _boardEntered = true;
        _animLock = false;
      });
      _maybePlayDeferredRoll();
    });
  }

  @override
  void didUpdateWidget(covariant GameScreen old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      final prevCells = (state?['cells'] as List?) ?? [];
      state = widget.state;
      over = widget.over;
      selUnit = null;
      selAction = null;
      splitOpts = null;
      splitFull = null;
      final s = state;
      // 动画播放包防御：动画是锦上添花，任何异常都不能崩游戏
      try {
        // lastAction 剧本驱动：服务端告知"谁做了什么、结果是什么"，客户端照着演（与演示页同思路）
        // lastSeq 序号：同一次行动会推多个 state（回合切换等），只播第一次
        final la = s?['lastAction'];
        final seq = (s?['lastSeq'] as num?)?.toInt() ?? 0;
        if (la != null && seq != _lastSeq) {
          _lastSeq = seq;
          _playLastAction(la, prevCells, s['cells'] as List);
        }
        // 滚木滚动剧本驱动：服务端下发每步碾压结果（压到即更新状态，不是滚完统一处理）
        // 行动动画未播完（_animLock）时缓存到 _deferredRoll，播完再滚——不抢跑、也不被吞
        if (s != null && prevCells.isNotEmpty && s['cells'] is List) {
          // 逐步驱动（热座/局域网）：rollActs = 规则层算出的这一步基础动作，播完再请求下一步
          final rseq = (s['rollStepSeq'] as num?)?.toInt() ?? 0;
          final rActs = s['rollActs'];
          if (rseq != 0 && rseq != _lastRollStepSeq && rActs is List && rActs.isNotEmpty) {
            _lastRollStepSeq = rseq;
            _rollActsDriven = true; // 本回合滚木已由 rollActs 逐步驱动（播完即完成，全量 rollSteps 是冗余）
            _playRollActs(rActs.cast<Map<String, dynamic>>(), prevCells, s['cells'] as List);
          } else if (s['rollPending'] == true && rseq == _lastRollStepSeq && !_animLock) {
            // 滚木待滚且没有新步在播（endTurn 后第一步）→ 请求规则层算一步
            // 2026-08-19 修复：延迟到帧后请求——didUpdateWidget 是 build 阶段，同步 emit 会
            // 在 onEvent → 外层 setState 时触发 "setState during build"（debug assert），
            // release 不报但状态同步时序脆弱（幽灵格子隐患之一）
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.socket.emit('roll_step');
            });
          } else {
            final rollSeq = (s['rollSeq'] as num?)?.toInt() ?? 0;
            if (rollSeq != 0 && rollSeq != _lastRollSeq) {
              _lastRollSeq = rollSeq;
              if (_rollActsDriven) {
                // 2026-08-18 修复：热座/局域网已逐步播完整个滚动，
                // 滚完后的 rollSteps 全量重放会让浮层"一步多格"滑行并无视桥/单位（牢大反馈）
                _rollActsDriven = false;
              } else if (_animLock) {
                _deferredRoll = {
                  'prevCells': prevCells,
                  'newCells': s['cells'] as List,
                  'rollSteps': s['rollSteps'] as List?,
                };
              } else {
                _detectRoll(prevCells, s['cells'] as List, rollSteps: s['rollSteps'] as List?);
              }
            }
          }
        }
      } catch (e, st) {
        debugPrint('AIM anim error: $e\n$st');
        // 2026-08-19：动画异常防御——清理残留动画状态，否则 _animCells 卡在动画棋盘
        // （多一格幽灵格子、退出动画错位）。异常后回退到规则棋盘显示
        _animCells = null;
        _animLock = false;
        _mv = null;
      }

      // 2026-08-20 幽灵格子兜底 v3：动画已结束（_animLock=false）但 _animCells 残留、
      // 长度≠规则棋盘 → 强制清理（正常收尾时 _animLock=false 意味着 _animCells 已清空）。
      // _animLock=true 的卡死态由 _mapArea 的 2s 超时解锁处理（这里不动，避免误伤 _finishAnim 收尾窗口）
      if (!_animLock && _animCells != null && s != null && s['cells'] is List) {
        if (_animCells!.length != (s['cells'] as List).length) {
          if (kDebugMode) {
            debugPrint('AIMDBG   [幽灵格子防御] 清理残留动画棋盘 ${_animCells!.length}格 vs 规则${(s['cells'] as List).length}格');
          }
          _animCells = null;
        }
      }

      if (s != null && s['turn'] == s['yourIdx'] && s['phase'] == null && s['winner'] == null) {
        if (!_myPhaseSeen) {
          round++;
          _myPhaseSeen = true;
        }
      } else if (s != null && (s['phase'] != null || s['turn'] != s['yourIdx'])) {
        _myPhaseSeen = false;
      }
    }
  }

  // ── lastAction 剧本驱动：服务端告知"谁做了什么、结果是什么"，客户端照着演（与演示页同思路）──
  // 核心：动画期间渲染"旧棋盘 + 转变结果"（_animCells），播完才切新棋盘——不猜、不叠浮层
  void _playLastAction(Map la, List prevCells, List newCells) {
    final type = la['type'] as String?;
    if (type == null || type.isEmpty) return;
    switch (type) {
      case 'move':
        _playMove(la, prevCells, newCells);
        break;
      case 'attack':
        _playAttack(la, prevCells, newCells);
        break;
      case 'devour':
        _playDevour(la, prevCells, newCells);
        break;
      case 'split':
        _playSplit(la, prevCells, newCells);
        break;
      case 'produce':
        _playProduce(la, prevCells, newCells);
        break;
    }
  }

  // 滚木自动滚动：用 id 找到位置变化的滚木（v=6），按服务端 rollSteps 逐子步平移
  // 每子步到达的格子立即应用碾压结果（桥/新值）——压到即更新，不等滚完
  void _detectRoll(List prevCells, List newCells, {List? rollSteps}) {
    for (final p in prevCells) {
      if (p['bridge'] == true || (p['v'] as num?)?.toInt() != 6) continue;
      final me = (p['o'] as num?)?.toInt() ?? 0;
      final dirn = me == 1 ? -1 : 1;
      final pid = p['id'];
      if (pid == null) continue;
      final oi = prevCells.indexOf(p);
      int? ni;
      for (int k = 0; k < newCells.length; k++) {
        final q = newCells[k];
        if (q['id'] == pid) {
          ni = k;
          break;
        }
      }
      if (ni == null) {
        // 滚木消失（撞桥/建筑/滚出/压桥掉下去）：有 rollSteps 时也播动画（滚到死点消失）
        if (rollSteps != null && rollSteps.isNotEmpty) {
          final steps = rollSteps.length;
          // 2026-08-18 修复：终点按 rollSteps 实际累计（bump 反向 +1，dead 停在死点再往 dirn 一格）
          // 旧公式 oi + dirn*steps 在插桥+撞桥场景会多算（右→左闪现到桥左边两格）
          var deadEnd = oi;
          var hitDead = false;
          for (final rs in rollSteps) {
            if (rs['dead'] == true) {
              hitDead = true;
              break;
            }
            deadEnd += (rs['bump'] == true) ? 1 : dirn;
          }
          if (hitDead) deadEnd += dirn; // 滚到死点（桥/建筑/边缘）消失
          _startMoveAnim(prevCells,
              {'idx': deadEnd, 'v': 6, 'o': me, 'steps': steps, 'dir': dirn, 'oldIdx': oi}, newCells,
              rollSteps: rollSteps);
        }
        continue;
      }
      if (oi == ni) continue;
      _startMoveAnim(prevCells,
          {'idx': ni, 'v': 6, 'o': me, 'steps': (rollSteps?.length ?? 1), 'dir': dirn, 'oldIdx': oi}, newCells,
          rollSteps: rollSteps);
      break;
    }
  }

  // ── 滚木逐步驱动（热座/局域网，2026-08-16 重构）──
  // 规则层每次只算一步（rollStepOnce），下发该步基础动作序列（rollActs）；
  // 这里把动作组合成一次滚木动画（移动 + 转变 + 插桥 + 删除），播完请求下一步。
  // 基础动作：move 滚木移动 ｜ crush 压单位（含插桥） ｜ kill 抹杀 ｜ dead 死亡
  // 调试：AIMDBG 前缀输出动画层显示的地图（牢大要求实时比对）
  String _dbgCells(List cells) {
    return cells.map((c) {
      final m = c as Map;
      if (m['bridge'] == true) return '-';
      final v = (m['v'] as num?)?.toInt() ?? 0;
      final o = (m['o'] as num?)?.toInt();
      return o == null ? '0' : (o == 0 ? '[${v}]' : '{${v}}');
    }).join(' ');
  }

  void _playRollActs(List<Map<String, dynamic>> acts, List prevCells, List newCells) {
    if (kDebugMode) {
      debugPrint('AIMDBG rollActs=$acts');
      debugPrint('AIMDBG   步前棋盘(prevCells): ${_dbgCells(prevCells)}');
      debugPrint('AIMDBG   步后棋盘(newCells):  ${_dbgCells(newCells)}');
    }
    _playSfx('roll'); // 滚木每滚一步：隆隆
    // 滚木信息：从步前棋盘定位（acts 的 from 是步前坐标）
    int from = -1, v = 6, o = 0;
    final first = acts.isNotEmpty ? acts.first : null;
    final f = first?['from'];
    if (f is int && f >= 0 && f < prevCells.length) {
      from = f;
      final c = prevCells[f] as Map;
      v = (c['v'] as num?)?.toInt() ?? 6;
      o = (c['o'] as num?)?.toInt() ?? 0;
    }
    if (from < 0) return; // 找不到滚木（理论不会发生）
    final dirn = o == 1 ? -1 : 1;
    int to = from;
    String? deadReason;
    // 2026-08-17 绑定模型（牢大定）：滚木只在滑行瞬间是浮层，滑完一格绑定回棋盘对应格，
    // 插入/位移动画推格子时它跟着走（"被推开"=插入动画的推开效果，没有独立 bump 滑行）。
    // 每规则步 = 1 格滑行 + 绑定；含 dead 动作的步骤（尽头插桥被顶出地图等）走旧逻辑。
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
          final owner = (act['owner'] as num?)?.toInt() ?? o;
          final oldV = (act['oldV'] as num?)?.toInt() ?? 0;
          final newV = (act['newV'] as num?)?.toInt() ?? 0;
          final bridge = act['bridge'] == true;
          if (bridge && !hasDead) {
            // 溢出插桥（绑定模型）：滚木滑到被压格(at)停下并绑定，桥插入后
            // 6+被压单位整格被插入动画推到 at+1——视觉上"桥把 6 推过去"
            to = at + 1;
            bindAt = to;
            subSteps.add({'crush': true, 'owner': owner, 'oldV': oldV, 'newV': newV, 'bridge': true});
          } else if (bridge) {
            // 旧逻辑（含 dead 的尽头插桥）：压到 + bump 顶回
            to = at + 1;
            subSteps.add({'crush': true, 'owner': owner, 'oldV': oldV, 'newV': newV, 'bridge': true});
            subSteps.add({'bump': true});
          } else {
            to = (act['to'] as num).toInt();
            bindAt = to;
            subSteps.add({'crush': true, 'owner': owner, 'oldV': oldV, 'newV': newV, 'bridge': false});
          }
          break;
        case 'kill':
          final owner = (act['owner'] as num?)?.toInt() ?? o;
          final oldV = (act['oldV'] as num?)?.toInt() ?? 0;
          to = (act['to'] as num).toInt();
          bindAt = to;
          subSteps.add({'crush': true, 'kill': true, 'owner': owner, 'oldV': oldV});
          break;
        case 'dead':
          deadReason = act['reason'] as String?;
          if (deadReason == 'fall' || deadReason == 'bridge') {
            // 掉桥 / 撞桥：桥塌——6 落位到桥格（死停期显示桥+6 整体），
            // 死停后整格删除（牢大 2026-08-18 22:56 定稿：连带着 6 把整个格子一起删除）
            // 2026-08-20 修复：reason='bridge' 之前漏带 bridgeCollapse（'fall' 是历史遗留值，
            // 规则层实际只发 edge/bridge/building），导致热座/局域网撞桥死时 6 不落位，
            // 死停期棋盘 = 桥 + 露出的 1 两个格子（比规则棋盘多一格，牢大：最右边多一个 0）
            subSteps.add({'dead': true, 'bridgeCollapse': true});
            to = from + dirn; // 浮层滚到桥位消失
          } else {
            subSteps.add({'dead': true});
            to = from + dirn; // 撞建筑/滚出：滚到死点消失
          }
          bindAt = null;
          break;
      }
    }
    // 绑定模型：每规则步 = 1 格滑行；含 dead 的步骤按子步数（旧逻辑）
    final steps = hasDead ? subSteps.length : 1;
    _startMoveAnim(prevCells,
        {'idx': to, 'v': v, 'o': o, 'steps': steps, 'dir': dirn, 'oldIdx': from}, newCells,
        rollSteps: subSteps.isEmpty ? null : subSteps,
        bindAt: hasDead ? null : bindAt,
        onDone: () {
      // 该步播完：先停一小段（牢大：每步间隔太短难反应），还有下一步则请求（规则算一步 → 动画播一步）
      final st = state;
      if (st != null && st['rollPending'] == true) {
        Future.delayed(const Duration(milliseconds: _rollStepGapMs), () {
          if (!mounted) return;
          widget.socket.emit('roll_step');
        });
      }
    });
  }

  List<Map<String, dynamic>> _copyCells(List cells) =>
      cells.map((c) => Map<String, dynamic>.from(c as Map)).toList();

  // 按 id 在新棋盘找格子的值（删除/插入导致索引变化时精确定位）
  int _newCellVAt(List newCells, dynamic id, int fallback) {
    if (id == null) return fallback;
    for (final q in newCells) {
      if (q['id'] == id) return (q['v'] as num?)?.toInt() ?? fallback;
    }
    return fallback;
  }

  // 动画结束后切回新棋盘
  void _finishAnim([int delayMs = 0]) {
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      // 行动动画完成的棋盘 = 滚木动画的正确基底（行动后、滚木前）
      final doneCells = _animCells;
      _animCells = null;
      _animLock = false;
      _maybePlayDeferredRoll(baseCells: doneCells);
      setState(() {});
    });
  }

  // 行动动画播完后补播缓存的滚木动画（不抢跑也不被吞）
  // [baseCells] 行动动画播完的棋盘：行动+滚木同一帧推送时，prevCells 是行动前（会显示回退），必须用行动后棋盘
  void _maybePlayDeferredRoll({List? baseCells}) {
    final dr = _deferredRoll;
    if (dr == null || _animLock) return;
    _deferredRoll = null;
    if (_rollActsDriven) return; // 2026-08-18：已逐步播完，缓存的滚木动画是冗余，跳过全量重放
    final base = baseCells ?? (dr['prevCells'] as List);
    _detectRoll(base, dr['newCells'] as List, rollSteps: dr['rollSteps'] as List?);
  }

  // 移动：单位逐格平移（浮层），旧棋盘为底
  void _playMove(Map la, List prevCells, List newCells) {
    final i = (la['i'] as num).toInt();
    final steps = (la['steps'] as num).toInt();
    final collapse = la['bridgeCollapse'];
    final me = (la['owner'] as num?)?.toInt() ?? 0;
    final dirn = me == 1 ? -1 : 1;
    if (collapse != null) {
      // 重单位走桥：桥塌人亡 → 先播移动动画（逐格走到桥），到达后桥塌删除（含单位）+
      // _shiftCtrl 补位——与吞噬删格同一套删除动画（牢大 2026-08-18 23:50）
      final cp = (collapse as num).toInt();
      final v = (prevCells[i]['v'] as num).toInt();
      final o = prevCells[i]['o'];
      _startMoveAnim(prevCells,
          {'idx': cp, 'v': v, 'o': o, 'steps': steps, 'dir': dirn, 'oldIdx': i}, newCells,
          holdAtEnd: true, // 到达桥后保留动画棋盘（单位站在桥上），onDone 里播桥塌
          onDone: () {
        if (!mounted) return;
        // 桥塌：桥格（含站在桥上的单位）直接删除 + 补位
        final a = _animCells;
        if (a != null && cp < a.length) {
          a.removeAt(cp);
          _animCells = a;
          setState(() {});
        }
        _shiftCtrl?.dispose();
        _shiftAt = cp;
        _shiftCtrl = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 400),
        )
          ..addListener(() { if (mounted) setState(() {}); })
          ..forward().whenComplete(() {
            _shiftCtrl?.dispose();
            _shiftCtrl = null;
            _shiftAt = -1;
          });
        _finishAnim(1000);
      });
      return;
    }
    final newIdx = i + dirn * steps;
    if (newIdx < 0 || newIdx >= newCells.length) return;
    final v = (prevCells[i]['v'] as num).toInt();
    final o = prevCells[i]['o'];
    _startMoveAnim(prevCells,
        {'idx': newIdx, 'v': v, 'o': o, 'steps': steps, 'dir': dirn, 'oldIdx': i}, newCells);
  }

  // 攻击：目标格转变（白闪遮挡），溢出则插桥（推开+弹入）
  void _playAttack(Map la, List prevCells, List newCells) {
    final j = (la['j'] as num).toInt();
    final old = (la['old'] as num).toInt();
    final newV = (la['newV'] as num).toInt();
    final ins = la['insertedAt'];
    if (la['shielded'] == true) return; // 盾兵挡下：无动画
    final anim = _copyCells(prevCells);
    if (ins != null) {
      _playSfx('bridge'); // 溢出插桥：咚
      // 溢出插桥：桥插旧 j，目标右移（j+1）且值变 newV
      anim.insert(j, {'bridge': true, 'id': _fakeId--}); // 假 id：防与真实 id 撞渲染 key（2026-08-20）
      if (j + 1 < anim.length) anim[j + 1] = {...anim[j + 1], 'v': newV};
      _animCells = anim;
      _animLock = true;
      setState(() {});
      _addHit(j + 1, old, newV); // 目标转变（右移后）
      _addInsertAnim(j);         // 桥弹入（推开+由远及近）
      _finishAnim(750);
    } else {
      if (newV > 0) {
        anim[j] = {...anim[j], 'v': newV};
        _animCells = anim;
        _animLock = true;
        setState(() {});
        _addHit(j, old, newV);
      } else {
        // 击杀：目标消失
        anim[j] = {'v': 0, 'o': null};
        _animCells = anim;
        _animLock = true;
        setState(() {});
        _addHit(j, old, 0);
      }
      _finishAnim(650);
    }
  }

  // 吞噬：两格同时转变（1→2、1→0）→ 停顿 → 目标格缩没删除 → 切新棋盘
  void _playDevour(Map la, List prevCells, List newCells) {
    final i = (la['i'] as num).toInt();
    final j = (la['j'] as num).toInt();
    final sum = (la['sum'] as num).toInt();
    final spliced = la['spliced'] == true;
    final collapsed = la['collapsed'] == true;
    final oldVi = (prevCells[i]['v'] as num?)?.toInt() ?? 0;
    final oldVj = (prevCells[j]['v'] as num?)?.toInt() ?? 0;
    // 动画棋盘：旧棋盘 + 转变结果（吞噬方→新值、目标→新值），值都用新棋盘实际结果
    // （超9 时吞噬方变 tens、目标变 ones，不是 sum）
    // 注意：i > j（吞噬方在目标右边）时 splice 后新棋盘索引左移，用 id 精确定位
    // fallback：超9 时吞噬方变 tens（sum~/10），目标变 ones
    final newVi = _newCellVAt(newCells, prevCells[i]['id'], sum > 9 ? sum ~/ 10 : sum);
    final newVj = _newCellVAt(newCells, prevCells[j]['id'], sum > 9 ? sum % 10 : 0);
    final anim = _copyCells(prevCells);
    if (!collapsed) {
      anim[i] = {...anim[i], 'v': newVi};
      if (spliced) anim[j] = {'v': 0, 'o': null};
      else anim[j] = {...anim[j], 'v': newVj};
    } else {
      anim[i] = {'v': 0, 'o': null};
    }
    _animCells = anim;
    _animLock = true;
    setState(() {});
    // 阶段1：两个格子同时转变（白闪+刀光遮挡，底下已是结果值）
    if (!collapsed) {
      _addHit(i, oldVi, newVi);
      if (spliced) _addHit(j, oldVj, 0);
      else if (newVj != oldVj) _addHit(j, oldVj, newVj);
    } else {
      _addHit(i, oldVi, 0);
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
        // 补位动画：左侧右移半格、删除点及右侧左移半格
        _shiftCtrl?.dispose();
        _shiftAt = j;
        _shiftCtrl = AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 400),
        )
          ..addListener(() { if (mounted) setState(() {}); })
          ..forward().whenComplete(() {
            _shiftCtrl?.dispose();
            _shiftCtrl = null;
            _shiftAt = -1;
          });
      }
      _finishAnim(1000);
    });
  }

  // 拆分：保留位转变 + 产物插入（右侧弹入）
  void _playSplit(Map la, List prevCells, List newCells) {
    final i = (la['i'] as num).toInt();
    final keep = (la['keep'] as num).toInt();
    final other = (la['other'] as num?)?.toInt() ?? 0;
    final full = la['full'] == true;
    final owner = (la['owner'] as num?)?.toInt() ?? 0;
    final oldV = (prevCells[i]['v'] as num?)?.toInt() ?? 0;
    final anim = _copyCells(prevCells);
    anim[i] = {...anim[i], 'v': keep};
    if (!full) {
      anim.insert(i + 1, {'v': other, 'o': owner, 'id': _fakeId--}); // 产物插保留值右侧；假 id 防撞 key
    }
    _animCells = anim;
    _animLock = true;
    setState(() {});
    _addHit(i, oldV, keep);
    if (!full) _addInsertAnim(i + 1);
    _finishAnim(750);
  }

  // 造兵：新单位出现（白闪）或攻击敌方（-1）——不需要动画棋盘
  void _playProduce(Map la, List prevCells, List newCells) {
    final j = (la['j'] as num).toInt();
    if (la['attacked'] == true) {
      final oldV = (prevCells[j]['v'] as num?)?.toInt() ?? 0;
      final nv = (newCells[j]['v'] as num?)?.toInt() ?? 0;
      if (nv != oldV) _addHit(j, oldV, nv);
    } else {
      final nv = (newCells[j]['v'] as num?)?.toInt() ?? 0;
      if (nv > 0) _addHit(j, 0, nv);
    }
  }

  // 直接添加一个转变动画（白闪遮挡即时转变）
  void _addHit(int idx, int from, int to) {
    if (!mounted) return;
    setState(() {
      _hits.add(HitFxData(i: idx, from: from, to: to)..id = ++_hitId);
    });
  }

  void _removeHit(int id) {
    if (!mounted) return;
    setState(() => _hits.removeWhere((h) => h.id == id));
  }

  // 启动逐格移动动画：每格一次 260ms easeInOut 平移，多格连续串行
  // 动画棋盘以"旧棋盘"为底（单位从旧位置逐格移动），播完切新棋盘（单位已在终点）
  // 移动：单位逐格平移（浮层），旧棋盘为底。
  // 滚木滚动时 [rollSteps] 携带服务端每步碾压剧本：每子步到达的格子立即更新
  // 为桥/新值（压到即更新），而不是滚完再统一处理。
  void _startMoveAnim(List prevCells, Map<String, dynamic> moved, List newCells,
      {List? rollSteps, VoidCallback? onDone, int? bindAt, bool holdAtEnd = false}) {
    _stepCtrl?.dispose();
    _stepCtrl = null;
    _animLock = true;
    _rollDead = false;
    _rollBridgeCollapse = false;
    _rollBridgeAt = -1;
    final v = moved['v'] as int;
    final o = moved['o'] as int;
    final dirn = moved['dir'] as int;
    final steps = moved['steps'] as int;
    final oldIdx = moved['oldIdx'] as int;
    final newIdx = moved['idx'] as int;
    // 用 id 精确定位移动单位（防场上同值/同阵营单位被误清，多滚木场景）
    dynamic rid = moved['id'];
    if (rid == null && oldIdx >= 0 && oldIdx < prevCells.length) {
      rid = (prevCells[oldIdx] as Map?)?['id'];
    }
    var anim = prevCells.map((c) => Map<String, dynamic>.from(c as Map)).toList();
    _mv = {'v': v, 'o': o, 'dirn': dirn, 'steps': steps, 'oldIdx': oldIdx, 'newIdx': newIdx, 'stepFrom': oldIdx, 'bindAt': bindAt, 'bound': false};
    var step = 0;
    // 动画层新建格子的假 id（负值，保证不与真实 id 撞车，渲染 key 唯一）
    // 2026-08-20 修复：改为 State 级全局计数——局部变量每次从 -1 重新数，
    // 上一个动画残留的假 id 会与下一个动画（移动+滚木 _deferredRoll 链）新建的假 id 撞 key
    // （Duplicate keys → 渲染错乱，牢大"幽灵格子/操作不了"的真根因之一）
    var fakeId = _fakeId;
    // 滚木脚下压着的单位转正（滚木走开露出——与规则层 _unpress 同语义）；否则清格/保留桥
    // 2026-08-17：清掉的是滚木本体（id==rid）时，清出的格子用假 id——
    // 被压单位的原 id 规则棋盘没存（只存了 v/o），沿用 rid 会跟绑定/浮层落位的滚木格撞 key
    void clearCell(int k) {
      final c = anim[k];
      final pv = c['pressedV'];
      final isRoller = rid != null ? c['id'] == rid : false;
      final newId = isRoller ? fakeId-- : c['id'];
      if (pv != null && (pv as num) > 0) {
        // 被压单位转正显示（滚木移开，露出脚下）
        anim[k] = {'v': (pv as num).toInt(), 'o': c['pressedO'] as int?, 'id': newId};
      } else if (c['bridge'] == true || c['onBridge'] == true) {
        // 滚木离开桥格：桥保留
        anim[k] = {'v': 0, 'o': null, 'bridge': true, 'id': newId};
      } else {
        anim[k] = {'v': 0, 'o': null, 'id': newId};
      }
    }
    // 把移动单位从旧位置清掉（其余位置不动），刷新动画棋盘
    // 2026-08-16 改：滚木本体不进动画棋盘（浮层即本体，避免插桥 splice 挤动后棋盘残留第二个滚木）
    void placeUnit(int from) {
      for (int k = 0; k < anim.length; k++) {
        final c = anim[k];
        final isRoller = rid != null ? c['id'] == rid : (k == from && c['v'] == v && c['o'] == o);
        if (isRoller) clearCell(k);
      }
      _animCells = anim.map((c) => Map<String, dynamic>.from(c)).toList();
      if (kDebugMode) debugPrint('AIMDBG   [placeUnit@$from] 动画棋盘: ${_dbgCells(_animCells!)}');
    }
    // 滚木第 [s] 子步（1-based）的碾压结果应用到动画棋盘：压到即更新
    void applyRollStep(int s) {
      if (rollSteps == null || s < 1 || s > rollSteps.length) return;
      final rs = rollSteps[s - 1] as Map;
      if (rs['dead'] == true) {
        _rollDead = true;
        // 撞桥（bridgeCollapse）：6 落位到桥格（桥+6 整体），死停后整格一起播删除动画
        // （牢大 2026-08-18 22:56：停顿一下，然后连带着 6 把整个格子一起删除，不是 6 先消失）
        if (rs['bridgeCollapse'] == true) {
          // 桥的位置 = 浮层当前到达位置（stepFrom+subDirn，bump 后也准）——先算再隐藏浮层
          final bridgeAt = (_mv!['stepFrom'] as int) + ((_mv!['subDirn'] as int?) ?? dirn);
          if (bridgeAt >= 0 && bridgeAt < anim.length) {
            anim[bridgeAt] = {
              'id': rid,
              'v': v,
              'o': o,
              'bridge': true,
              'onBridge': true, // 6 站在桥上：只显示 6，桥藏脚下
              'pressedV': null,
              'pressedO': null,
            };
            _animCells = anim.map((c) => Map<String, dynamic>.from(c)).toList();
            _rollBridgeCollapse = true;
            _rollBridgeAt = bridgeAt;
          }
          _mv = null; // 浮层隐藏（6 已落位到格子，死停期间显示在桥上）
        }
        return;
      }
      if (rs['bump'] == true || rs['crush'] != true) return; // 被顶/空位：格子不变
      final arrival = oldIdx + dirn * s;
      if (arrival < 0 || arrival >= anim.length) return;
      final origId = anim[arrival]?['id']; // 保留被压格 id（渲染 key 唯一）
      final owner = (rs['owner'] as num?)?.toInt();
      if (rs['kill'] == true) {
        anim[arrival] = {'v': 0, 'o': null, 'id': origId}; // 抹杀：变空地
      } else if (rs['bridge'] == true) {
        if (bindAt != null) {
          // 绑定模型（2026-08-18）：6 先绑定到被压格（脚下压着变值单位），
          // 桥插入把整格挤到桥右（splice 语义）——“格子怎么动，6 怎么动”；
          // 插入动画平滑推开，6 跟着格子无缝右移，等插入动画播完（暂停 ${_rollCrushPauseMs}ms）才再动
          anim[arrival] = {
            'id': rid,
            'v': v,
            'o': o,
            'pressedV': (rs['newV'] as num).toInt(),
            'pressedO': owner,
          };
          anim.insert(arrival, {'v': 0, 'o': null, 'bridge': true, 'id': fakeId--});
          _addInsertAnim(arrival);
          _mv!['bound'] = true;
        } else {
          // 旧路径（联机回放/_detectRoll，无 bindAt）：单位右移一格，6 保持浮层——
          // 不能写 6 进棋盘也不能置 bound，否则浮层被隐藏 + 6 被 placeUnit 清掉 = 凭空消失
          anim.insert(arrival, {'v': 0, 'o': null, 'bridge': true, 'id': fakeId--});
          if (arrival + 1 < anim.length) {
            anim[arrival + 1] = {'v': (rs['newV'] as num).toInt(), 'o': owner, 'id': origId};
          }
          _addInsertAnim(arrival);
        }
      } else {
        // 非溢出：单位留在原地变新值
        anim[arrival] = {'v': (rs['newV'] as num).toInt(), 'o': owner, 'id': origId};
      }
      // 被压单位的转变动画（白闪刀光）
      if (rs['kill'] != true) {
        _addHit(arrival, (rs['oldV'] as num?)?.toInt() ?? 0, (rs['newV'] as num?)?.toInt() ?? 0);
      }
      _animCells = anim.map((c) => Map<String, dynamic>.from(c)).toList();
      if (kDebugMode) debugPrint('AIMDBG   [applyRollStep#$s] 动画棋盘: ${_dbgCells(_animCells!)}  子步=$rs');
    }
    void cleanup() {
      _stepCtrl?.dispose();
      _stepCtrl = null;
      final mv = _mv;
      final doneCells = _animCells;
      _mv = null;
      _rollPaused = false;
      _animLock = false;
      if (!holdAtEnd) _animCells = null; // holdAtEnd：保留动画棋盘，onDone 里继续播后续动画（如桥塌）
      if (doneCells != null && mv != null) {
        // 动画完成瞬间浮层单位还在 stepFrom（终点前一格），修正到终点——
        // 否则滚木动画拿这个棋盘当基底时单位会显示在上一格（牢大：5 回退位置）
        // 被桥推开的浮层（pushed）：当前位置就是终点（arrival+1），不再加移动方向
        final from = mv['stepFrom'] as int;
        final subDirn = (mv['subDirn'] as int?) ?? (mv['dirn'] as int);
        final pushed = mv['pushed'] == true;
        // 绑定模型：滚木已绑定在棋盘 bindAt 格（清掉重放=原位，无副作用）；旧路径保持 from+subDirn
        final to = (mv['bindAt'] as int?) ?? (pushed ? from : from + subDirn);
        final v = mv['v'] as int;
        final o = mv['o'] as int;
        if (to >= 0 && to < doneCells.length) {
          for (int k = 0; k < doneCells.length; k++) {
            final c = doneCells[k] as Map;
            final isRoller = rid != null
                ? c['id'] == rid
                : (c['v'] == v && c['o'] == o && k != to);
            if (isRoller) {
              final pv = c['pressedV'];
              if (pv != null && (pv as num) > 0) {
                doneCells[k] = {'v': (pv as num).toInt(), 'o': c['pressedO'] as int?};
              } else if (c['bridge'] == true || c['onBridge'] == true) {
                doneCells[k] = {'v': 0, 'o': null, 'bridge': true};
              } else {
                doneCells[k] = {'v': 0, 'o': null};
              }
            }
          }
          // 浮层落位：滚木覆盖目标格，脚下压着的单位存 pressedV（下一步走开时转正）
          final tc = doneCells[to] as Map;
          final tcB = tc['bridge'] == true || tc['onBridge'] == true;
          final tcV = (tc['v'] as num?)?.toInt() ?? 0;
          final tcO = tc['o'] as int?;
          final tcId = rid ?? tc['id'] ?? fakeId--;
          doneCells[to] = tcB
              ? {
                  'id': tcId,
                  'v': v,
                  'o': o,
                  'bridge': true,
                  'onBridge': true,
                  'pressedV': tcV > 0 ? tcV : null,
                  'pressedO': tcV > 0 ? tcO : null,
                }
              : {
                  'id': tcId,
                  'v': v,
                  'o': o,
                  'pressedV': tcV > 0 ? tcV : null,
                  'pressedO': tcV > 0 ? tcO : null,
                };
        }
      }
      _fakeId = fakeId; // 2026-08-20：存回全局假 id 计数，下一个动画继续向下（跨动画唯一）
      _maybePlayDeferredRoll(baseCells: doneCells);
      if (kDebugMode) debugPrint('AIMDBG   [cleanup] 动画完成切新棋盘: ${_dbgCells(state?['cells'] as List? ?? const [])}');
      onDone?.call();
      if (mounted) setState(() {});
    }
    // 串行推进：上一步平移完成 → 应用该步碾压结果 → 下一步（from → from+dirn）
    void nextStep() {
      step++;
      if (step > steps) {
        // 最后一步的 whenComplete 已 applyRollStep（幂等），这里只收尾
        cleanup();
        return;
      }
      // 子步方向：bump（被顶到桥右边）固定 +1（splice 右移，与滚木方向无关）；其余沿 dirn
      final isBump = rollSteps != null &&
          step <= rollSteps.length &&
          rollSteps[step - 1] != null &&
          rollSteps[step - 1]['bump'] == true;
      final subDirn = isBump ? 1 : dirn;
      // 2026-08-18 修复：实际位置按前 step-1 个子步累计（bump 反向），
      // 旧公式 oldIdx + dirn*(step-1) 在 bump 步后错位（右→左插桥场景浮层瞬移到桥左边两格）
      var from = oldIdx;
      for (var i = 1; i < step; i++) {
        final r = rollSteps != null && i <= rollSteps.length ? rollSteps[i - 1] : null;
        from += (r != null && r['bump'] == true) ? 1 : dirn;
      }
      _mv!['stepFrom'] = from;
      _mv!['subDirn'] = subDirn;
      placeUnit(from);
      final prev = _stepCtrl;
      _stepCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: _moveStepMs),
      )
        ..addListener(() {
          if (mounted) setState(() {});
        })
        ..forward().whenComplete(() {
          if (!mounted) return;
          // 浮层到达 from+dirn：该格立即更新为碾压结果（压到即更新，不是滚完统一处理）
          applyRollStep(step);
          if (_rollDead) {
            // 撞桥/滚出/建筑：浮层滚到死点，停顿后消失（删格/切新棋盘）
            _rollPaused = true;
            Future.delayed(const Duration(milliseconds: _rollDeadPauseMs), () {
              if (!mounted) return;
              _rollPaused = false;
              if (_rollBridgeCollapse) {
                // 撞桥：死停后直接删桥格（含 6，无残影），剩余格子 _shiftCtrl 补位——
                // 与吞噬删格同一套（牢大 2026-08-18 23:50：基本动画只写一套）
                final bi = _rollBridgeAt;
                _rollBridgeCollapse = false;
                final a = _animCells;
                if (bi >= 0 && a != null && bi < a.length) {
                  a.removeAt(bi); // 桥格（含 6）直接删除
                  _animCells = a;
                  setState(() {});
                  _shiftCtrl?.dispose();
                  _shiftAt = bi;
                  _shiftCtrl = AnimationController(
                    vsync: this,
                    duration: const Duration(milliseconds: 400),
                  )
                    ..addListener(() { if (mounted) setState(() {}); })
                    ..forward().whenComplete(() {
                      _shiftCtrl?.dispose();
                      _shiftCtrl = null;
                      _shiftAt = -1;
                    });
                  Future.delayed(const Duration(milliseconds: 600), () {
                    if (!mounted) return;
                    cleanup();
                  });
                  return;
                }
              }
              cleanup();
            });
            return;
          }
          // 绑定模型（2026-08-17）：滑完一格 → 滚木写回棋盘对应格（脚下压着被压单位），
          // 之后插入/位移动画推格子时它跟着走；下次滑行前再解除（placeUnit 清掉）。
          // 插桥的绑定已在 applyRollStep 里先绑后挤（bound=true），这里跳过
          if (bindAt != null && _mv!['bound'] != true) {
            final bi = bindAt;
            if (bi >= 0 && bi < anim.length) {
              final c = anim[bi];
              final pv = (c['v'] as num?)?.toInt() ?? 0;
              final po = c['o'] as int?;
              final cb = c['bridge'] == true || c['onBridge'] == true;
              anim[bi] = cb
                  ? {
                      'id': rid,
                      'v': v,
                      'o': o,
                      'bridge': true,
                      'onBridge': true,
                      'pressedV': pv > 0 ? pv : null,
                      'pressedO': pv > 0 ? po : null,
                    }
                  : {
                      'id': rid,
                      'v': v,
                      'o': o,
                      'pressedV': pv > 0 ? pv : null,
                      'pressedO': pv > 0 ? po : null,
                    };
              _animCells = anim.map((c) => Map<String, dynamic>.from(c)).toList();
              if (kDebugMode) debugPrint('AIMDBG   [bind@$bi] 动画棋盘: ${_dbgCells(_animCells!)}');
            }
            _mv!['bound'] = true;
          }
          // 压到单位：停住（此时滚木已绑定在到达格，脚下压着变值单位），
          // 等插入(400ms)/白闪(600ms)动画完全播完（暂停 ${_rollCrushPauseMs}ms 覆盖两者）再继续滚
          // 2026-08-16 牢大修正：crush 子步后如果还有 bump（被顶到桥右），先走完顶回，
          // 停顿发生在 bump 之后（浮层在被压单位格子上，而不是停在桥上）
          final rs = rollSteps != null && step <= rollSteps.length ? rollSteps[step - 1] : null;
          final isCrush = rs != null && rs['crush'] == true && rs['kill'] != true;
          final isBump = rs != null && rs['bump'] == true;
          final hasNext = step < steps;
          if (isCrush && hasNext) {
            nextStep(); // crush 后还有 bump：先顶回，不停顿
            return;
          }
          if ((isCrush || isBump) && !hasNext) {
            _rollPaused = true;
            Future.delayed(const Duration(milliseconds: _rollCrushPauseMs), () {
              if (!mounted) return;
              _rollPaused = false;
              nextStep();
            });
            return;
          }
          nextStep();
        });
      prev?.dispose();
      if (mounted) setState(() {});
    }
    nextStep();
  }

  bool get _myTurn => state != null && state['turn'] == state['yourIdx'] && state['winner'] == null;

  List<dynamic> _legalOf(int i) {
    final la = (state?['legalActions'] as List?) ?? [];
    return la.where((a) => a['i'] == i).toList();
  }

  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _enterTimer?.cancel();
    _stepCtrl?.dispose();
    for (final a in _inserts) {
      a.ctrl.dispose();
    }
    _voiceWatchdog?.cancel();
    _battleVoice.dispose();
    for (final p in _sfxPool) {
      p.dispose();
    }
    super.dispose();
  }

  bool _canClick(int i) {
    if (_animLock) return false; // 动画期间锁定操作
    if (!_myTurn || state == null) return false;
    final cells = state['cells'] as List;
    if (i < 0 || i >= cells.length) return false; // 动画棋盘比新棋盘长时防越界
    final c = cells[i];
    if (c['bridge'] == true || c['v'] == 0) return false;
    if (c['o'] != state['yourIdx']) return false;
    if (state['phase'] == 'produce') return c['v'] == 8;
    return _legalOf(i).isNotEmpty;
  }

  int? _moveTarget(dynamic a) {
    if (state == null) return null;
    final dirn = (state['yourIdx'] == 1) ? -1 : 1;
    return (a['i'] as int) + dirn * (a['steps'] as int);
  }

  String? _targetType(int i) {
    if (state == null || selUnit == null) return null;
    for (final a in _legalOf(selUnit!)) {
      if (a['type'] == 'move' && _moveTarget(a) == i) return 'move';
      if ((a['type'] == 'attack' || a['type'] == 'devour') && a['j'] == i) return a['type'];
    }
    return null;
  }

  void _tryProduce(int i) {
    if (state == null) return;
    final s = state;
    final cells = s['cells'] as List;
    final dirn = (s['yourIdx'] == 1) ? -1 : 1;
    final j = i + dirn;
    if (j >= 0 && j < cells.length && cells[j]['bridge'] != true) {
      _emitAction({'type': 'produce', 'i': i, 'j': j});
    }
    // 前方被独木桥挡住：操作问题静默不提示
  }

  void _confirmSplit() {
    if (splitSliderI == null) return;
    _emitAction({'type': 'split', 'i': splitSliderI, 'keep': splitKeep.round()});
    setState(() { splitSliderI = null; selUnit = null; });
  }

  // 战斗语音：选中/移动/攻击 触发（互斥——播放中新触发直接丢弃；随机 a/b 变体）
  void _playBattleVoice(String type, int v) {
    if (!_voiceUnits.contains(v)) return;
    if (SettingsStore.voiceVolume <= 0) return;
    if (_voiceBusy) return; // 播放中：直接丢弃，等播完才响应下一次
    final path = 'audio/battle/battle_${type}_$v${_voiceRand.nextBool() ? 'a' : 'b'}.mp3';
    _voiceBusy = true;
    // 看门狗：3.5s 强制解锁（防播放器异常导致 onPlayerComplete 永不触发 → 语音永久哑）
    _voiceWatchdog?.cancel();
    _voiceWatchdog = Timer(const Duration(milliseconds: 3500), () => _voiceBusy = false);
    // 先订阅完成事件再播放（防短音频错过流事件卡死 busy）
    _battleVoice.onPlayerComplete.first.then((_) {
      _voiceWatchdog?.cancel();
      _voiceBusy = false;
    }).catchError((_) {
      _voiceWatchdog?.cancel();
      _voiceBusy = false;
    });
    _battleVoice.setVolume(SettingsStore.voiceVolume);
    _battleVoice.play(AssetSource(path)).catchError((_) {
      _voiceWatchdog?.cancel();
      _voiceBusy = false; // 播放失败（文件缺失等）立即解锁
    });
  }

  // 统一发行动：移动/攻击 在下令瞬间触发对应语音（选中语音在 _clickCell 里单独触发）
  // 归属守卫：只播「我方单位」的语音——局域网/联机 yourIdx 固定座位，热座=当前操作者
  // 同时播对应 8-bit 音效（move/attack/shoot/devour/split/produce）
  void _emitAction(dynamic action) {
    final t = action?['type'];
    if (t == 'move' || t == 'attack') {
      final i = action['i'];
      if (i is int) {
        final cells = state?['cells'] as List?;
        if (cells != null && i >= 0 && i < cells.length) {
          final c = cells[i];
          final v = c?['v'];
          if (v is num && c?['o'] == state?['yourIdx']) {
            _playBattleVoice(t == 'move' ? 'move' : 'attack', v.toInt());
          }
          // 音效：攻击区分近战/远程（3 弓 4 炮 射程 >1 → 嗖）
          if (v is num && t == 'attack') {
            final av = v.toInt();
            _playSfx(av == 3 || av == 4 ? 'shoot' : 'attack');
          }
        }
      }
      if (t == 'move') _playSfx('move');
    } else if (t == 'devour') {
      _playSfx('devour');
    } else if (t == 'split') {
      _playSfx('split');
    } else if (t == 'produce') {
      _playSfx('produce');
    }
    widget.socket.emit('action', action);
  }

  // ── 键盘快捷键（PC/Web）：←→ 移动光标、空格/回车确认、Esc 取消、数字直选 ──
  // 绑定可在设置面板自定义（settings_store.keybind）
  bool _handleKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    if (_chatOpen) return false; // 聊天输入时不拦截键盘
    if (state == null) return false;
    final cells = state!['cells'] as List;
    final n = cells.length;
    final cur = _kbCursor.clamp(0, n - 1);
    final k = SettingsStore.canonKey(e.logicalKey);
    if (k == null) return false;
    if (k == SettingsStore.keyFor('moveLeft')) {
      setState(() => _kbCursor = cur <= 0 ? 0 : cur - 1);
      return true;
    }
    if (k == SettingsStore.keyFor('moveRight')) {
      setState(() => _kbCursor = cur >= n - 1 ? n - 1 : cur + 1);
      return true;
    }
    if (e is! KeyDownEvent) return false; // 以下动作忽略长按重复
    if (k == SettingsStore.keyFor('confirm')) {
      _clickCell(cur);
      return true;
    }
    if (k == SettingsStore.keyFor('cancel')) {
      setState(() { selUnit = null; selAction = null; pending = null; });
      return true;
    }
    // 已选中单位：动作快捷键（移动/攻击/吞噬/拆分）
    if (selUnit != null) {
      if (k == SettingsStore.keyFor('move')) { _doActionBtn('move'); return true; }
      if (k == SettingsStore.keyFor('attack')) { _doActionBtn('attack'); return true; }
      if (k == SettingsStore.keyFor('devour')) { _doActionBtn('devour'); return true; }
      if (k == SettingsStore.keyFor('split')) { _doActionBtn('split'); return true; }
    }
    // 造兵：光标停在己方基地上时按 P
    if (k == SettingsStore.keyFor('produce')) {
      final cells = state!['cells'] as List;
      final c = cells[cur];
      if (c['v'] == 8 && c['o'] == state!['yourIdx']) _tryProduce(cur);
      return true;
    }
    if (RegExp(r'^[0-9]$').hasMatch(k)) { // 数字直选 1-9,0
      final d = k == '0' ? 9 : int.parse(k) - 1;
      if (d < n) _clickCell(d);
      return true;
    }
    return false;
  }

  // ── 长按查看单位卡片（速查卡：忘记单位用途时用，样式同教程角色卡） ──
  void _showUnitCard(int i, dynamic c) {
    if (_animLock || _exiting) return;
    if (c == null) return;
    final rawV = c['v'];
    if (rawV == null || (rawV as num) <= 0) return; // 空地 / 桥不弹卡
    final v = rawV.toInt();
    final card = kUnitCards[v];
    if (card == null) return;
    final size = MediaQuery.sizeOf(context);
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xB8000000),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: EdgeInsets.symmetric(horizontal: size.width * 0.07, vertical: 40),
        child: Container(
          width: size.width * 0.86,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1916),
            border: Border.all(color: const Color(0xFF5A554C), width: 2),
            boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 20, spreadRadius: 4)],
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _unitCardPortrait(v, card),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pt(card.name, 22, _warnC),
                    _pt('『$v 号』', 12, _dimC),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: const Color(0xFF2A2824)),
                      child: _pt(card.stat, 13, _panelC),
                    ),
                    const SizedBox(height: 8),
                    for (final line in card.bio.split('\n')) _pt(line, 12, _dimC, bold: false),
                    const SizedBox(height: 8),
                    _pt('轻点空白处关闭', 10, _dimC, bold: false),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unitCardPortrait(int v, UnitCard card) {
    const pw = 100.0;
    if (card.portrait != null) {
      return SizedBox(
        width: pw,
        child: AspectRatio(
          aspectRatio: 160 / 213,
          child: Image.asset(
            'assets/art/default/portraits/${card.portrait}.png',
            fit: BoxFit.contain,
          ),
        ),
      );
    }
    // 无立绘（6 滚木 / 8 基地 / 9 指挥部）：数字像素图
    return Image.asset('assets/art/default/units/$v.png',
        width: pw, fit: BoxFit.contain, filterQuality: FilterQuality.none);
  }

  void _clickCell(int i) {
    if (_animLock || _exiting) return; // 动画/退场期间锁定操作
    if (!_myTurn || state == null) return;
    final s = state;
    final cells = s['cells'] as List;
    final c = cells[i];
    final isMine = c['o'] == s['yourIdx'] && c['v'] > 0 && c['bridge'] != true;
    // 1) 已选中单位
    if (selUnit != null) {
      // 点同一格：基地=造兵，其他=取消
      if (i == selUnit) {
        if (c['v'] == 8 && isMine) _tryProduce(i);
        setState(() { selUnit = null; pending = null; });
        return;
      }
      // 选目标模式（点了操作按钮后）：目标敌我皆可，必须先于「切换选中」判断，否则点己方可攻击单位会被拦截成选中
      if (selAction == 'attack' || selAction == 'devour') {
        Map<String, dynamic>? tgt;
        for (final a in _legalOf(selUnit!)) {
          if (a['type'] == selAction && a['j'] == i) {
            tgt = Map<String, dynamic>.from(a as Map);
            break;
          }
        }
        if (tgt != null) {
          _emitAction(tgt);
          setState(() { selUnit = null; selAction = null; pending = null; });
        }
        return;
      }
      // 点自己的其他单位 → 切换选中
      if (isMine) {
        _playBattleVoice('select', (c['v'] as num).toInt());
        _playSfx('select');
        setState(() { selUnit = i; pending = null; });
        return;
      }
      // 点目标格执行：attack 优先（吞噬用按钮）
      final targets = <dynamic>[];
      for (final a in _legalOf(selUnit!)) {
        if (a['type'] == 'move' && _moveTarget(a) == i) targets.add(a);
        if ((a['type'] == 'attack' || a['type'] == 'devour') && a['j'] == i) targets.add(a);
      }
      targets.sort((a, b) => (a['type'] == 'attack' ? 0 : 1) - (b['type'] == 'attack' ? 0 : 1));
      if (targets.isNotEmpty) {
        _emitAction(targets.first);
        setState(() { selUnit = null; pending = null; });
        return;
      }
      // 点自己的其他单位 → 切换选中
      if (isMine) {
        _playBattleVoice('select', (c['v'] as num).toInt());
        _playSfx('select');
        setState(() { selUnit = i; pending = null; });
        return;
      }
      // 不在射程内：操作问题静默不提示
      return;
    }
    // 2) 未选中：点自己单位（含基地）→ 选中
    if (isMine) {
      if (_canClick(i)) {
        _playBattleVoice('select', (c['v'] as num).toInt());
        _playSfx('select');
        setState(() => selUnit = i);
      }
      return;
    }
    // 3) 未选中点敌方单位 → 若有我方单位能攻击它，直接攻击（选第一个）
    if (c['v'] > 0 && c['bridge'] != true) {
      final la = (s['legalActions'] as List?) ?? [];
      Map<dynamic, dynamic>? atk;
      for (final a in la.cast<Map>()) {
        if (a['type'] == 'attack' && a['j'] == i) { atk = a; break; }
      }
      if (atk != null) {
        _emitAction(atk);
      }
      // 没有单位能攻击到它：操作问题静默不提示
    }
  }

  void _doActionBtn(String t) {
    if (t == 'move') {
      // 显式查找（不用 firstWhere orElse:()=>null，List<dynamic> 会运行期类型崩）
      Map<String, dynamic>? mv;
      for (final a in _legalOf(selUnit!)) {
        if (a['type'] == 'move') {
          mv = Map<String, dynamic>.from(a as Map);
          break;
        }
      }
      if (mv != null) {
        _emitAction(mv);
        setState(() { selUnit = null; selAction = null; pending = null; });
      }
    } else if (t == 'attack' || t == 'devour') {
      final tgtList = _legalOf(selUnit!).where((a) => a['type'] == t).toList();
      if (tgtList.length == 1) {
        // 只有一个目标：直接执行
        _emitAction(tgtList.first);
        setState(() { selUnit = null; selAction = null; pending = null; });
      } else if (tgtList.length > 1) {
        // 多个目标：选目标模式
        setState(() => selAction = t);
      }
    } else if (t == 'split') {
      setState(() {
        splitSliderI = selUnit;
        splitKeep = 1;
        selUnit = null;
      });
    }
  }

  void _pickPending(String t) {
    Map<String, dynamic>? act;
    final p = pending;
    if (p != null) {
      for (final a in p) {
        if (a['type'] == t) {
          act = Map<String, dynamic>.from(a as Map);
          break;
        }
      }
    }
    if (act != null) {
      _emitAction(act);
      setState(() { selUnit = null; pending = null; });
    }
  }

  void _openSplit() {
    Map<String, dynamic>? act;
    for (final a in _legalOf(selUnit!)) {
      if (a['type'] == 'split') {
        act = Map<String, dynamic>.from(a as Map);
        break;
      }
    }
    if (act != null) setState(() => splitOpts = _splitOpts(act));
  }

  List<dynamic> _splitOpts(dynamic act) {
    final seen = <String>{};
    final opts = <dynamic>[];
    for (final x in (state?['legalActions'] as List?) ?? []) {
      if (x['type'] == 'split' && x['i'] == selUnit) {
        final k = '${x['a']},${x['b']}';
        if (seen.add(k)) opts.add(x);
      }
    }
    return opts;
  }

  void _doAction(dynamic a) {
    switch (a['type']) {
      case 'move':
        _emitAction(a);
        setState(() { selUnit = null; });
        break;
      case 'attack':
      case 'devour':
        setState(() => selAction = a['type']);
        break;
      case 'split':
        final seen = <String>{};
        final opts = <dynamic>[];
        for (final x in (state?['legalActions'] as List?) ?? []) {
          if (x['type'] == 'split' && x['i'] == selUnit) {
            final k = '${x['a']},${x['b']}';
            if (seen.add(k)) opts.add(x);
          }
        }
        setState(() {
          if (state['mapLen'] >= state['limit']) {
            splitFull = opts.isEmpty ? a : opts.first;
            splitOpts = null;
          } else {
            splitOpts = opts;
            splitFull = null;
          }
        });
        break;
    }
  }

  void _pickSplit(dynamic opt) {
    if (state != null && state['mapLen'] >= state['limit']) {
      setState(() => splitFull = opt);
      return;
    }
    _emitAction({'type': 'split', 'i': opt['i'], 'keep': opt['a']});
    setState(() { selUnit = null; selAction = null; splitOpts = null; });
  }

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s == null) return const SizedBox();
    _scale = (MediaQuery.sizeOf(context).shortestSide / 400).clamp(0.72, 1.0);
    final margin = SettingsStore.margin * _scale;
    // 小屏（手表）强制经典布局：侧栏/简洁在窄屏会挤爆
    final isSmall = MediaQuery.sizeOf(context).shortestSide < 400;
    final layout = isSmall ? 'classic' : SettingsStore.layout;
    final Widget body = switch (layout) {
      'compact' => _buildCompact(s),
      'side' => _buildSide(s),
      _ => _buildClassic(s),
    };
    return Scaffold(
      body: Container(
        color: const Color(0xFF11110F),
        child: SafeArea(
          child: Stack(children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: margin),
              child: Column(children: [
                _topBar(),
                const Divider(color: Color(0xFF5A5680), height: 1),
                Expanded(child: body),
              ]),
            ),
            _overlay(s),
            if (_chatOpen) _chatPanel(),
            _chatFloat(),
          ]),
        ),
      ),
    );
  }

  // 顶栏：返回 + 标题 + 设置（与教程界面同风格，不悬浮、不挡信息）
  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(children: [
        _topBtn('← 返回', _confirmLeave),
        const Spacer(),
        _pt('AIM · 数字大战', 13, _signalC),
        const Spacer(),
        // 快捷消息按钮：像素绘制的白色聊天气泡（无 emoji）
        InkWell(
          onTap: _toggleChat,
          child: Container(
            width: 34, height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: const Color(0xFF5A554C), width: 1)),
            child: const CustomPaint(size: Size(20, 18), painter: _ChatIconPainter(color: Color(0xFFFFF5DC))),
          ),
        ),
        const SizedBox(width: 6),
        _topBtn('⚙ 设置', _openInGameSettings),
      ]),
    );
  }

  Widget _topBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2824),
          border: Border.all(color: const Color(0xFF5A554C), width: 1),
        ),
        child: _pt(label, 12, _panelC),
      ),
    );
  }



  void _confirmLeave() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('退出对局？', style: TextStyle(color: _warnC, fontSize: 15, fontWeight: FontWeight.bold)),
        content: const Text('对局进度不会保留，确定离开吗？', style: TextStyle(color: _panelC, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续', style: TextStyle(color: _signalC, fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startExitAnim(); // 先播退场动画（数字飞走淡出），再真正退出
            },
            child: const Text('退出', style: TextStyle(color: _dimC, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 退出对局：整盘数字朝自家方向飞走淡出（与教程退场同款），播完再 onBack
  void _startExitAnim() {
    if (_exiting) return;
    setState(() => _exiting = true);
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      widget.onBack();
    });
  }

  void _openInGameSettings() {
    // 通用设置面板（布局/边距/BGM/语音音量），onChanged 让棋盘边距与布局实时生效
    showSettingsPanel(context, onChanged: () => setState(() {}));
  }

  // ── 布局A：经典（当前默认）——顶信息栏 + 地图 + 操作面板 + 战报 ──
  Widget _buildClassic(dynamic s) {
    return Column(children: [
      _infoBar(s),
      const Divider(color: Color(0xFF5A5680), height: 1),
      Expanded(child: _mapArea(s)),
      _actionPanel(s),
      const Divider(color: Color(0xFF5A5680), height: 1),
      _logBar(s),
    ]);
  }

  // ── 布局B：简洁——状态压成一行，地图最大化 ──
  Widget _buildCompact(dynamic s) {
    return Column(children: [
      _midBar(s),
      const Divider(color: Color(0xFF5A5680), height: 1),
      Expanded(child: _mapArea(s)),
      _actionPanel(s),
      const Divider(color: Color(0xFF5A5680), height: 1),
      _logBar(s),
    ]);
  }

  // ── 布局C：侧栏——左竖排状态 + 右侧大棋盘 ──
  Widget _buildSide(dynamic s) {
    return Row(children: [
      SizedBox(
        width: 132 * _scale,
        child: Column(children: [
          _sideInfo(s),
          const Divider(color: Color(0xFF5A5680), height: 1),
          Expanded(child: _logBar(s)),
        ]),
      ),
      const VerticalDivider(width: 1, color: Color(0xFF5A5680)),
      Expanded(
        child: Column(children: [
          Expanded(child: _mapArea(s)),
          _actionPanel(s),
          const Divider(color: Color(0xFF5A5680), height: 1),
          _miniStatus(s),
        ]),
      ),
    ]);
  }

  // 精简状态行（布局B用）：回合 · 行动/造兵 · 点数 · 双方数字和 · 地图长度
  Widget _midBar(dynamic s) {
    final me = (s['yourIdx'] as num).toInt();
    final names = (s['names'] as List?) ?? ['玩家1', '玩家2'];
    String mid;
    if (s['spectator'] == true) {
      mid = '观战中 · 地图 ${s['mapLen']}/${s['limit']}';
    } else if (_myTurn) {
      if (s['phase'] == null) mid = '回合 $round · ${names[me]}：行动 or 造兵';
      else if (s['phase'] == 'produce') mid = '回合 $round · 造兵（剩${s['produceLeft']}次）';
      else mid = '回合 $round · 行动（剩${s['points']}点）';
    } else {
      mid = '回合 $round · 等待对手…';
    }
    final mySum = (s['mySum'] as num?)?.toInt() ?? 0;
    final enSum = (s['enemySum'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(children: [
        Expanded(child: _pt(mid, 12, Colors.white)),
        _pt('$mySum : $enSum', 13, _signalC, bold: true),
        const SizedBox(width: 8),
        _pt('${s['mapLen']}/${s['limit']}', 11, _dimC),
      ]),
    );
  }

  // 底部状态行（布局C右侧用）：回合 · 点数 · 地图长度
  Widget _miniStatus(dynamic s) {
    final me = (s['yourIdx'] as num).toInt();
    final names = (s['names'] as List?) ?? ['玩家1', '玩家2'];
    String mid;
    if (s['spectator'] == true) {
      mid = '观战中 · 地图 ${s['mapLen']}/${s['limit']}';
    } else if (_myTurn) {
      if (s['phase'] == null) mid = '回合 $round · ${names[me]}：行动 or 造兵';
      else if (s['phase'] == 'produce') mid = '回合 $round · 造兵剩${s['produceLeft']}次';
      else mid = '回合 $round · 行动剩${s['points']}点';
    } else {
      mid = '回合 $round · 等待对手…';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(children: [
        Expanded(child: _pt(mid, 11, _dimC)),
        _pt('地图 ${s['mapLen']}/${s['limit']}', 11, _dimC),
      ]),
    );
  }

  // 左侧竖排状态（布局C用）
  Widget _sideInfo(dynamic s) {
    final names = (s['names'] as List?) ?? ['玩家1', '玩家2'];
    final me = (s['yourIdx'] as num).toInt();
    final en = 1 - me;
    if (s['spectator'] == true) {
      final sums = (s['sums'] as List?) ?? [0, 0];
      final bases = (s['bases'] as List?) ?? [0, 0];
      final hqs = (s['hqs'] as List?) ?? [0, 0];
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pt('观战', 13, _warnC),
          const SizedBox(height: 6),
          _pt(names[0], 11, _myC),
          _pt('数字和 ${sums[0]}', 11, _dimC),
          _pt('基地×${bases[0]} 指×${hqs[0]}', 10, _dimC),
          const SizedBox(height: 8),
          _pt(names[1], 11, _enemyC),
          _pt('数字和 ${sums[1]}', 11, _dimC),
          _pt('基地×${bases[1]} 指×${hqs[1]}', 10, _dimC),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _pt(names[me], 12, _myC),
        _pt('数字和 ${s['mySum']}', 12, _dimC),
        _pt('基地×${s['myBases']} 指×${s['myHqs']}', 10, _dimC),
        const SizedBox(height: 10),
        _pt(names[en], 12, _enemyC),
        _pt('数字和 ${s['enemySum']}', 12, _dimC),
        const SizedBox(height: 10),
        _pt(_myTurn ? '轮到你' : '对手回合', 12, _myTurn ? _greenC : _dimC),
      ]),
    );
  }

  Widget _overlay(dynamic s) {
    if (over == null) return const SizedBox.shrink();
    final hotseat = s['hotseat'] == true;
    String txt;
    Color col;
    String sub;
    if (hotseat) {
      final names = (s['names'] as List?) ?? ['左边', '右边'];
      final w = (over['winner'] as num?)?.toInt() ?? 0;
      txt = w == 0 ? '左胜' : '右胜';
      col = _warnC;
      sub = '${names[w]} 把对手的数字减到了零';
    } else {
      final win = over['winner'] == s['yourIdx'];
      txt = win ? '胜 利' : '败 北';
      col = win ? const Color(0xFF5AC87A) : _enemyC;
      sub = win ? '敌方数字和归零' : '你的数字和归零了';
    }
    _playSfx(over['winner'] == s['yourIdx'] || (s['hotseat'] == true && (over['winner'] as num?)?.toInt() == 0) ? 'win' : 'lose');
    return GameOverAnim(
      win: col != _enemyC,
      title: txt,
      sub: sub,
      onBack: widget.onBack,
      state: s,
    );
  }

  Widget _infoBar(dynamic s) {
    final names = (s['names'] as List?) ?? ['玩家1', '玩家2'];
    if (s['spectator'] == true) {
      final sums = (s['sums'] as List?) ?? [0, 0];
      final bases = (s['bases'] as List?) ?? [0, 0];
      final hqs = (s['hqs'] as List?) ?? [0, 0];
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(children: [
          Expanded(child: _pt('${names[0]}  基地×${bases[0]}  指挥部×${hqs[0]}  数字和${sums[0]}', 12, _myC)),
          Expanded(flex: 2, child: Column(children: [
            _pt('观战中 · 不能操作', 14, _warnC, center: true),
            _pt('地图 ${s['mapLen']}/${s['limit']}', 11, _dimC, center: true),
          ])),
          Expanded(child: _pt('${names[1]}  数字和${sums[1]}', 12, _enemyC, center: false)),
        ]),
      );
    }
    final me = (s['yourIdx'] as num).toInt();
    final en = 1 - me;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pt('${names[me]}  基地×${s['myBases']}  指挥部×${s['myHqs']}', 13, _myC),
          _pt('数字和 ${s['mySum']}', 12, _dimC),
        ])),
        Expanded(flex: 2, child: Column(children: [
          _pt(_midText(s, names), 13, Colors.white, center: true),
          _pt('地图 ${s['mapLen']}/${s['limit']}', 11, _dimC, center: true),
        ])),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          _pt('${names[en]}', 13, _enemyC),
          _pt('数字和 ${s['enemySum']}', 12, _dimC),
        ])),
      ]),
    );
  }

  String _midText(dynamic s, List names) {
    final me = s['yourIdx'];
    if (s['winner'] != null) return '对局结束';
    if (_myTurn) {
      if (s['phase'] == null) return '回合 $round · ${names[me]}：行动 or 造兵';
      if (s['phase'] == 'produce') return '回合 $round · ${names[me]}造兵（剩${s['produceLeft']}次）';
      return '回合 $round · ${names[me]}行动（剩${s['points']}点）';
    }
    return '回合 $round · 等待对手…';
  }

  Widget _mapArea(dynamic s) {
    // 2026-08-20 幽灵格子兜底 v3（渲染层）：
    // 1) 动画已结束（_animLock=false）但 _animCells 残留、长度与规则棋盘不一致 → 回退规则棋盘。
    // 2) 动画锁卡死：_animLock=true 但没有任何动画控制器在播（_finishAnim 收尾窗口 ≤1.5s，
    //    阈值 2s 不误伤；死停期 _rollPaused=true 不误判）→ 强制解锁+回退，
    //    覆盖牢大"删除完最右边忽然多一格、整个棋盘点不了（含 1）"的卡死态。
    var displayCells = (_animCells ?? s['cells']) as List;
    final ruleCells = s['cells'] as List;
    if (_animCells != null) {
      final stalled = _animLock &&
          _stepCtrl == null && _shiftCtrl == null && _inserts.isEmpty &&
          _hits.isEmpty && !_rollPaused;
      if (stalled) {
        _stallSince ??= DateTime.now();
        if (DateTime.now().difference(_stallSince!) > const Duration(seconds: 2)) {
          if (kDebugMode) debugPrint('AIMDBG   [幽灵格子防御] 动画锁卡死>2s 强制解锁，回退规则棋盘');
          _animLock = false;
          _animCells = null;
          _mv = null;
          _stallSince = null;
        }
      } else {
        _stallSince = null;
      }
      if (!_animLock && displayCells.length != ruleCells.length) {
        displayCells = ruleCells;
      }
    }
    // 动画中：渲染动画棋盘（逐格移动效果）
    final n = displayCells.length;
    return LayoutBuilder(builder: (ctx, cons) {
      _layoutWidth = cons.maxWidth;
      // 格子自适应：大屏最多72，小屏（手表）保底30，装不下就横向滚动
      // 2026-08-18 修正：动画期间步距用规则棋盘长度（该步最终长度）固定——
      // 若按动画棋盘实时算，插桥 8→9 格瞬间 cellSize 变小、整盘重排塌缩（6 被挤得失位/消失的观感）
      final stepN = (s['cells'] as List).length;
      final cellSize = ((cons.maxWidth - 12) / stepN).clamp(30.0, 72.0);
      final step = cellSize + 6; // 每格步距（含 margin 3+3）
      // 移动中的单位：浮层渲染（盖在所有格子之上，从 stepFrom 平移到 stepFrom+dirn）
      final mv = _mv;
      final ctrl = _stepCtrl;
      final moving = mv != null && ctrl != null && (ctrl.isAnimating || _rollPaused) && mv['bound'] != true;
      double? mvLeft;
      if (moving) {
        final t = Curves.easeInOut.transform(ctrl.value); // 加速→减速（停顿中 value=1 → 到达格）
        final floatIdx = mv['stepFrom'] as int;
        final subDirn = (mv['subDirn'] as int?) ?? (mv['dirn'] as int);
        final pushed = mv['pushed'] == true;
        // 被桥推开的浮层：位置=stepFrom（不加移动方向），跟随插入动画的推开位移被动右移
        mvLeft = 3 + floatIdx * step + (pushed ? 0.0 : t * subDirn * step);
        // 浮层跟随格子的插入/删除位移（否则插入动画推格子时，浮层不动=滚木像回到初始位置）
        // forFloat：只跟插入推挤，不跟删除位移（撞桥死停时不被带偏，牢大 2026-08-18）
        mvLeft += _cellOffset(floatIdx, step, forFloat: true).dx;
        if (kDebugMode) {
          final cellIdx = ((mvLeft - 3) / step).round();
          debugPrint('AIMDBG   [render] 浮层@idx≈$cellIdx pushed=$pushed floatIdx=$floatIdx t=${t.toStringAsFixed(2)} off=${_cellOffset(floatIdx, step).dx.toStringAsFixed(1)}');
        }
      }
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 棋盘窄于屏幕时居中显示（与演示页一致）；宽于屏幕时横向滚动
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: cons.maxWidth),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(children: [
                Row(
                  children: List.generate(n, (i) {
              final c = displayCells[i];
              // 正在平移的单位：棋盘格内隐藏（由顶层浮层渲染），格子只露背景
              final isMovingUnit = moving &&
                  c['v'] == mv['v'] && c['o'] == mv['o'] && i == mv['stepFrom'];
              final cellId = c['id'] ?? i; // 格子稳定身份（服务端分配）；动画层新建格子也带唯一 id，不会撞
              return GestureDetector(
                key: ValueKey('cell$cellId'),
                onTap: () => _clickCell(i),
                onLongPress: () => _showUnitCard(i, c),
                child: _exiting
                    // 退出：整盘数字朝自家方向飞走淡出（与教程退场同款）
                    ? BoardExitCell(
                        box: _cellFrame(i, c, cellSize, step, isMovingUnit),
                        index: i,
                        count: n,
                        cellSize: cellSize,
                        isMine: c['o'] == s?['yourIdx'],
                      )
                    : (_boardEntered
                        ? _cellFrame(i, c, cellSize, step, isMovingUnit)
                        // 入场：地图展开动画（中间先落、对称向两侧飞入）
                        : BoardEnterCell(
                            cell: _cellFrame(i, c, cellSize, step, isMovingUnit),
                            index: i,
                            count: n,
                            cellSize: cellSize,
                            isUnit: c['bridge'] != true && c['v'] != null && (c['v'] as num) > 0,
                          )),
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
                child: _pixImg(widget.packId, '${mv['v']}', (cellSize * 0.9).clamp(20.0, 64.0)),
              ),
            ),
            ],
          ),
          ],
        ),
      ),
    );
    });
  }

  // 单个格子：位移（插入/删除动画）+ 弹入包装 + 边框/内容/打击层
  Widget _cellFrame(int i, dynamic c, double cellSize, double step, bool isMovingUnit) {
    final s = state;
    final cellId = c['id'] ?? i;
    return Transform.translate(
      offset: _cellOffset(i, step),
      child: _insertWrap(
        i,
        Container(
          width: cellSize,
          height: cellSize,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: _cellBg(c, i, s),
            border: Border.all(color: _borderColor(i, c, s), width: selUnit == i || _kbCursor == i ? 3 : 2),
          ),
          child: ClipRect(
            child: Stack(alignment: Alignment.center, children: [
              if (!isMovingUnit) _cellIcon(c, cellSize),
              if (c['v'] == 8 && c['o'] != null)
                Positioned(
                  left: c['o'] == s['yourIdx'] ? 2 : null,
                  right: c['o'] != s['yourIdx'] ? 2 : null,
                  top: 2,
                  child: _pt('▶', 10, _dimC),
                ),
              // 打击动画层：白闪 + 刀光（转变即时完成，动画负责遮挡）
              for (final h in _hits)
                if (h.i == i)
                  HitFx(
                    key: ValueKey('hit${h.id}_$cellId'),
                    packId: widget.packId,
                    from: h.from,
                    to: h.to,
                    imgSize: (cellSize * 0.9).clamp(20.0, 64.0),
                    cellSize: cellSize,
                    onDone: () => _removeHit(h.id),
                  ),
            ]),
          ),
        ),
      ),
    );
  }

  Color _cellBg(dynamic c, int i, dynamic s) {
    if (c['bridge'] == true) return const Color(0xFF2A2824);
    if (c['v'] == 0 || c['v'] == null) return i.isEven ? _cellEven : _cellOdd;
    if (c['o'] == s['yourIdx']) return i.isEven ? const Color(0xFF262220) : const Color(0xFF201C1A);
    return i.isEven ? const Color(0xFF241C1A) : const Color(0xFF1E1614);
  }

  Color _borderColor(int i, dynamic c, dynamic s) {
    final tt = _targetType(i);
    if (selUnit == i) return _warnC;
    if (_kbCursor == i) return const Color(0xFFFFC94D); // 键盘光标（金色）
    if (tt == 'move') return _greenC;
    if (tt == 'attack') return _enemyC;
    if (tt == 'devour') return _warnC;
    if (_canClick(i)) return _greenC;
    // 敌方单位：若有我方单位能攻击/吞噬它 → 亮橙红高亮（滚木等目标一眼可见）
    if (c['v'] != null && c['v'] > 0 && c['bridge'] != true && c['o'] != s['yourIdx']) {
      final la = (s['legalActions'] as List?) ?? [];
      final hit = la.any((a) => (a['type'] == 'attack' || a['type'] == 'devour') && a['j'] == i);
      if (hit) return const Color(0xFFFF6B52);
    }
    if (c['v'] != null && c['v'] > 0 && c['bridge'] != true) {
      return c['o'] == s['yourIdx'] ? _myC : _enemyC;
    }
    return const Color(0xFF5A554C);
  }

  Widget _cellIcon(dynamic c, double cellSize) {
    final packId = widget.packId;
    final imgSize = (cellSize * 0.9).clamp(20.0, 64.0);
    if (c['bridge'] == true && c['onBridge'] != true) {
      // 纯桥：显示桥
      return _pixImg(packId, 'dash', imgSize);
    }
    if (c['v'] == 0) return _pixImg(packId, '0', imgSize);
    // 单位上桥：只显示单位（桥隐藏在脚下）
    return _pixImg(packId, '${c['v']}', imgSize);
  }

  Widget _pixImg(String packId, String file, double size) {
    if (packId == 'default' || packId == ArtManager.builtinId) {
      return Image.asset('assets/art/default/units/$file.png', width: size, height: size, fit: BoxFit.contain);
    }
    return FutureBuilder<ImageProvider>(
      future: ArtManager.customUnit(packId, file),
      builder: (c, snap) => snap.hasData
          ? Image(image: snap.data!, width: size, height: size, fit: BoxFit.contain)
          : const SizedBox(width: 40, height: 40),
    );
  }

  Widget _actionPanel(dynamic s) {
    final compact = MediaQuery.sizeOf(context).shortestSide < 360;
    return Column(children: [
      if (!compact)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            _pt('边框:', 11, _dimC),
            for (final (c, name) in [
              (_myC, '我方'), (_enemyC, '敌方'), (_greenC, '移动/可点'), (_warnC, '吞噬/选中'),
            ])
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(children: [_pt('■', 12, c), const SizedBox(width: 2), _pt(name, 11, _dimC)]),
              ),
          ]),
        ),
      _actionBody(s),
    ]);
  }

  Widget _actionBody(dynamic s) {
    // 观战模式
    if (s['spectator'] == true) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: _pt('观战中 · 等待对局结束', 14, _dimC),
      );
    }
    // 已选中单位：优先显示操作按键（任何阶段）
    if (selUnit != null) return _unitActions(s);
    if (splitSliderI != null) return _splitSlider();
    if (!_myTurn) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: _pt('对手回合中…', 15, _dimC),
      );
    }
    if (s['phase'] == null) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: _pt('点基地造兵 · 点单位行动（点数用完自动过回合）', 14, _textC),
      );
    }
    if (s['phase'] == 'produce') {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: _pt('造兵阶段 · 剩 ${s['produceLeft']} 次 · 点基地造兵', 14, _textC),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(10),
      child: _pt('行动阶段 · 剩 ${s['points']} 点：点单位选中，点目标执行', 14, _textC),
    );
  }

  Widget _splitSlider() {
    final v = (state!['cells'][splitSliderI!]['v'] as int);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _pt('拆分 $v：保留 ${splitKeep.round()} → ${v - splitKeep.round()} 放右侧', 14, _warnC),
        Slider(
          value: splitKeep.clamp(1, v - 1).toDouble(),
          min: 1, max: (v - 1).toDouble(),
          divisions: v - 2,
          activeColor: _signalC,
          inactiveColor: const Color(0xFF2A2824),
          onChanged: (d) => setState(() => splitKeep = d),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _pixBtn('确 认', _confirmSplit, small: true),
          const SizedBox(width: 10),
          _pixBtn('取消', () => setState(() => splitSliderI = null), small: true),
        ]),
      ]),
    );
  }

  Widget _unitActions(dynamic s) {
    final acts = _legalOf(selUnit!);
    final chips = <Widget>[];
    // 选目标模式
    if (selAction == 'attack' || selAction == 'devour') {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _pt('点击目标执行（${selAction == 'attack' ? '攻击' : '吞噬'}）', 14, _warnC),
          const SizedBox(height: 6),
          _pixBtn('取消', () => setState(() => selAction = null), small: true),
        ]),
      );
    }
    // 操作按键（根据可用操作显示）
    final shown = <String>{};
    for (final a in acts) {
      final t = a['type'] as String;
      if (t == 'move' || t == 'attack' || t == 'devour' || t == 'split') {
        if (shown.add(t)) {
          final label = {'move': '移动', 'attack': '攻击', 'devour': '吞噬', 'split': '拆分'}[t]!;
          chips.add(Padding(
            padding: const EdgeInsets.all(4),
            child: _pixBtn(label, () => _doActionBtn(t), small: true),
          ));
        }
      }
    }
    chips.add(Padding(
      padding: const EdgeInsets.all(4),
      child: _pixBtn('取消', () => setState(() { selUnit = null; selAction = null; pending = null; }), small: true),
    ));
    chips.add(Padding(
      padding: const EdgeInsets.all(4),
      child: _pt('或直接点目标格 · 剩余${s['points']}点', 12, _dimC),
    ));
    if (splitOpts != null) {
      for (final o in splitOpts!) {
        chips.add(Padding(
          padding: const EdgeInsets.all(4),
          child: _pixBtn('${o['a']}+${o['b']}', () => _pickSplit(o), small: true),
        ));
      }
    }
    if (splitFull != null) {
      final big = (splitFull['a'] as int) > (splitFull['b'] as int) ? splitFull['a'] : splitFull['b'];
      final small = (splitFull['a'] as int) > (splitFull['b'] as int) ? splitFull['b'] : splitFull['a'];
      chips.add(Padding(
        padding: const EdgeInsets.all(4),
        child: _pixBtn('保大 $big', () {
          _emitAction({'type': 'split', 'i': splitFull['i'], 'keep': big});
          setState(() { selUnit = null; selAction = null; splitFull = null; });
        }, small: true),
      ));
      chips.add(Padding(
        padding: const EdgeInsets.all(4),
        child: _pixBtn('保小 $small', () {
          _emitAction({'type': 'split', 'i': splitFull['i'], 'keep': small});
          setState(() { selUnit = null; selAction = null; splitFull = null; });
        }, small: true),
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(8),
      child: Row(children: chips),
    );
  }

  Widget _logBar(dynamic s) {
    final log = (s['log'] as List?) ?? [];
    // 小屏（手表）收起战报栏：只留一行高度
    final compact = MediaQuery.sizeOf(context).shortestSide < 360;
    return SizedBox(
      height: compact ? 26 : 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: compact
            ? Align(alignment: Alignment.centerLeft, child: _pt('战报', 11, _dimC))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _pt('战报', 11, _dimC),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final l in log.length > 4 ? log.sublist(log.length - 4) : log) _pt('· $l', 11, _dimC),
                    ]),
                  ),
                ),
              ]),
      ),
    );
  }

  Widget _pt(String s, double size, Color c, {bool center = false, bool bold = true}) {
    return Text(s,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: TextStyle(color: c, fontSize: size * _scale,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal, height: 1.3));
  }

  Widget _pixBtn(String label, VoidCallback cb, {bool small = false}) {
    return InkWell(
      onTap: cb,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: (small ? 12 : 22) * _scale, vertical: (small ? 8 : 12) * _scale),
        decoration: BoxDecoration(
          color: const Color(0xFFFF4E35),
          border: Border.all(color: const Color(0xFF5A554C), width: 2),
        ),
        child: _pt(label, (small ? 13 : 15), Colors.white, center: true),
      ),
    );
  }
}

// 插入格子动画：新格（桥/拆分产物）从无到有弹入
class _InsertAnim {
  final int id;
  final int idx; // 新棋盘索引
  final AnimationController ctrl;
  _InsertAnim({required this.id, required this.idx, required this.ctrl});
}


// 快捷消息按钮图标：像素风白色聊天气泡（描边圆角框 + 尾巴 + 三点）
class _ChatIconPainter extends CustomPainter {
  final Color color;
  const _ChatIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.miter;
    // 气泡主体（圆角矩形）
    final body = Rect.fromLTWH(1.5, 2, size.width - 3, size.height - 7);
    canvas.drawRRect(RRect.fromRectAndRadius(body, const Radius.circular(3)), stroke);
    // 小尾巴（左下）
    final tail = Path()
      ..moveTo(size.width * 0.28, size.height - 5)
      ..lineTo(size.width * 0.28 - 4.5, size.height - 1)
      ..lineTo(size.width * 0.28 + 4.5, size.height - 5);
    canvas.drawPath(tail, stroke);
    // 三点省略号
    final dot = Paint()..color = color;
    for (int i = 0; i < 3; i++) {
      canvas.drawCircle(Offset(size.width * (0.3 + 0.2 * i), size.height * 0.42), 1.5, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _ChatIconPainter oldDelegate) => oldDelegate.color != color;
}
