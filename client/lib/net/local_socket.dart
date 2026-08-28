// 本地热座数据源：伪装成 AIMSocket，实际驱动本地规则引擎（AimGame）
// GameScreen 无感——它只 emit('action') + 接收 onEvent('game_state')，
// 本地引擎算完结果直接推，不经过网络。断网可玩。
//
// 滚木逐步驱动（2026-08-16 重构）：
// endTurn 用 deferRoll 延后滚木 → 推 state（rollPending=true，棋盘未滚）
// GameScreen 检测到 rollActs 播该步动画 → 播完 emit('roll_step')
// → 引擎 rollStepOnce 算一步 → 推 state（该步后棋盘 + rollActs）
// → 循环直到 rollStepOnce 返回 null（rollPending=false）
//
// 玩家 vs AI（2026-08-22）：aiLevel 非空时，玩家1 由 AimAi 自动决策，
// 每个行动延迟 700ms（像在思考），玩家0 始终是人类。
import 'dart:async';

import '../game/rules.dart';
import '../game/ai.dart';
import 'socket.dart';

class LocalAimSocket extends AIMSocket {
  AimGame game;
  final int limit;
  final AiLevel? aiLevel; // null=双人；非 null=玩家 vs AI
  final int humanSide; // 人类所在侧（0=左，1=右）；AI 在另一侧
  bool _started = false;
  bool _disposed = false;
  bool _aiThinking = false;
  int _aiSeq = 0;
  // ── 训练场记录模式：记录人类每步操作供行为克隆训练 ──
  bool recordMode = false;
  bool duoMode = false; // 双人对战：两个真人轮流操作，记录双方棋谱（AI 都学）
  List<Map<String, dynamic>> humanSteps = [];
  // AI 决策可插拔（训练场用 TrainAi；空则用 aiLevel 的 AimAi）
  Map<String, dynamic>? Function(AimGame game)? aiDecider;
  void Function(Map<String, dynamic> gameData)? onGameRecorded;

  LocalAimSocket({this.limit = 16, bool allowOwnRollerAttack = true, this.aiLevel, this.humanSide = 0})
      : game = AimGame(limit: limit, allowOwnRollerAttack: allowOwnRollerAttack),
        super('local://hotseat');

  int get aiSide => 1 - humanSide;

  @override
  bool get connected => true;

  @override
  void connect() {
    // 本地无连接：直接开局，推人类视角
    onEvent?.call('game_state', game.viewFor(humanSide));
    // AI 先手（人类在右，aiSide=0）时立即开始决策——否则没人触发 AI 行动
    _maybeDriveAi();
  }

  void _pushState() {
    if (game.winner != null) {
      onEvent?.call('game_over', {
        'winner': game.winner,
        'winnerName': '玩家${game.winner! + 1}',
      });
      if (recordMode) {
        final data = <String, dynamic>{
          'winner': game.winner,
          'turns': game.turnCount,
          'limit': limit,
          'steps': List<Map<String, dynamic>>.from(humanSteps),
        };
        onGameRecorded?.call(data);
        humanSteps = [];
      }
    }
    // 视角：双人模式跟随当前回合玩家（谁行动谁看到自己的合法操作）；单人固定人类视角
    onEvent?.call('game_state', game.viewFor(duoMode ? game.turn : humanSide));
    _maybeDriveAi();
  }

  // AI 回合：延迟后决策 → 走统一 emit 入口（applyAction → _pushState 递归）
  void _maybeDriveAi() {
    if (duoMode) return; // 双人对战：无 AI
    if (aiLevel == null && aiDecider == null) return;
    if (_disposed) return;
    if (game.winner != null) return;
    if (game.turn != aiSide) return; // AI 在人类对面
    if (_aiThinking) return;
    _aiThinking = true;
    final mySeq = ++_aiSeq;
    Future.delayed(const Duration(milliseconds: 700), () {
      if (_disposed || mySeq != _aiSeq) {
        _aiThinking = false;
        return;
      }
      _aiThinking = false;
      final action = aiDecider != null ? aiDecider!(game) : AimAi(aiLevel!).decide(game);
      if (action == null) return; // 游戏已结束
      emit('action', action);
    });
  }

  // 记录人类一步：applyAction 成功后调用（状态为操作前快照）
  // 双人模式记录双方（owner=操作者），单人只记录人类侧
  // cells 必须传「执行前」棋盘——训练端 rebuild 用记录棋盘枚举合法动作，
  // 若用执行后棋盘（如 split 后 i 格已变 keep 值），执行前的动作会匹配不上（not_found）
  void _recordHumanStep(Map<String, dynamic> action, List<List<int>> cellsBefore,
      int snapTurn, String? snapPhase, int snapPoints, int snapProduce, int owner) {
    humanSteps.add({
      'cells': cellsBefore,
      'turn': snapTurn,
      'phase': snapPhase,
      'points': snapPoints,
      'produceLeft': snapProduce,
      'action': action,
      'owner': owner,
    });
  }

  @override
  void emit(String event, [dynamic data]) {
    if (event == 'action') {
      if (game.winner != null) return;
      final action = (data as Map).cast<String, dynamic>();
      // 记录模式：双人记录双方，单人只记录人类回合
      final rec = recordMode && (duoMode || game.turn == humanSide);
      final snapTurn = game.turn, snapPhase = game.phase;
      final snapPoints = game.points, snapProduce = game.produceLeft;
      // 执行前棋盘快照（训练端 rebuild 需要操作前状态来枚举合法动作）
      final cellsBefore = rec
          ? game.cells.map((c) => [c.v, c.o ?? -1, c.bridge ? 1 : 0, c.onBridge ? 1 : 0, c.auto ? 1 : 0]).toList()
          : null;
      // endTurn 延后滚木（deferRoll），由 roll_step 逐步驱动——规则算一步，动画播一步
      final res = game.applyAction(game.turn, action, deferRoll: true);
      if (res['ok'] != true) {
        onServerError?.call(res['reason']?.toString() ?? '操作不合法');
        return;
      }
      if (rec) {
        _recordHumanStep(action, cellsBefore!, snapTurn, snapPhase, snapPoints, snapProduce, snapTurn);
      }
      if (res['repeatWarn'] == true) {
        // 第 2 次重复：提示「再重复一次将判负」
        onEvent?.call('repeat_warn', null);
      }
      if (action['type'] == 'endTurn' && game.hasPendingRoll) {
        // 滚木待滚：推未滚的棋盘，等 GameScreen 逐步驱动
        _pushState();
        return;
      }
      _pushState();
    } else if (event == 'roll_step') {
      if (game.winner != null) return;
      final acts = game.rollStepOnce(game.turn);
      _pushState();
      if (acts == null) {
        // 全部滚完：本回合结束
        game.clearPendingRoll();
      }
    }
    // leave_room 等事件本地忽略
  }

  @override
  void dispose() {
    _disposed = true;
    _aiSeq++;
    // 无资源
  }
}
