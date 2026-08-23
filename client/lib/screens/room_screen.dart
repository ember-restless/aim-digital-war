// 房间页：双座位 + 准备 + 选边 + 踢人 + 地图长度 + 开始
// 受控组件：数据由父层（LobbyScreen）随 socket 事件更新传入，本页只展示 + 发事件
import 'package:flutter/material.dart';

import '../net/socket.dart';

const _ink = Color(0xFF11110F);
const _paper = Color(0xFFFFF5DC);
const _signal = Color(0xFFFF4E35);
const _dim = Color(0xFF77736B);
const _warn = Color(0xFFFFD36A);
const _border = Color(0xFF5A554C);
const _green = Color(0xFF61D39E);

class RoomScreen extends StatelessWidget {
  final dynamic room; // room_update
  final dynamic you; // you_are
  final AIMSocket socket;
  final String playerName;
  final VoidCallback onLeave;

  const RoomScreen({
    super.key,
    required this.room,
    required this.you,
    required this.socket,
    required this.playerName,
    required this.onLeave,
  });

  int get myIdx => ((you as Map?)?['playerIdx'] as num?)?.toInt() ?? -1;
  int get hostIdx => ((room as Map?)?['hostIdx'] as num?)?.toInt() ?? 0;
  bool get isOwner => myIdx == hostIdx;
  List get players => ((room as Map?)?['players'] as List?) ?? const [];
  bool get hotseat => (room as Map?)?['mode'] == 'hotseat';

  Widget _pt(String s, double size, Color c, {bool bold = false, bool center = false}) {
    return Text(s,
        style: TextStyle(color: c, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal, height: 1.2),
        textAlign: center ? TextAlign.center : TextAlign.left);
  }

  @override
  Widget build(BuildContext context) {
    final title = (room as Map?)?['title'] ?? '房间';
    final hasPwd = (room as Map?)?['hasPassword'] == true;
    final players = this.players;
    // 自己的座位（0 或 1）
    final mySeat = myIdx >= 0 && myIdx < players.length ? myIdx : 0;
    final otherSeat = 1 - mySeat;
    final limit = ((room as Map?)?['limit'] as num?)?.toInt() ?? 16;

    return Scaffold(
      body: Container(
        color: _ink,
        child: SafeArea(
          child: Column(children: [
            // 顶栏
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(children: [
                InkWell(
                  onTap: onLeave,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
                    child: _pt('← 退出房间', 12, _paper),
                  ),
                ),
                const SizedBox(width: 10),
                _pt('$title${hasPwd ? ' 🔒' : ''}', 14, _signal, bold: true),
                const Spacer(),
                _pt(isOwner ? '房主' : '等待房主开始…', 11, isOwner ? _warn : _dim),
              ]),
            ),
            const Divider(color: _border, height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  // 双座位
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _seat(context, 0, mySeat == 0)),
                    const SizedBox(width: 16),
                    Expanded(child: _seat(context, 1, mySeat == 1)),
                  ]),
                  const SizedBox(height: 20),
                  // 规则状态：滚木能否被己方攻击（创建房间时定）
                  Row(children: [
                    _pt('规则：', 11, _dim),
                    const SizedBox(width: 6),
                    _pt((room as Map?)?['allowOwnRollerAttack'] == false ? '己方滚木不可被己方攻击' : '滚木可被己方攻击', 11,
                        (room as Map?)?['allowOwnRollerAttack'] == false ? _warn : _green, bold: true),
                  ]),
                  const SizedBox(height: 8),
                  // 房主控制区：选边 + 地图长度
                  if (isOwner) ...[
                    _panel(title: '房主设置', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _pt('我坐（选边）', 12, _dim),
                      const SizedBox(height: 6),
                      Row(children: [
                        _btn('左 ◀', () => socket.emit('set_side', {'roomId': (room as Map)['id'], 'side': 'left'})),
                        const SizedBox(width: 8),
                        _btn('▶ 右', () => socket.emit('set_side', {'roomId': (room as Map)['id'], 'side': 'right'})),
                      ]),
                      const SizedBox(height: 12),
                      _pt('地图长度', 12, _dim),
                      const SizedBox(height: 6),
                      Row(children: [
                        for (final l in [12, 14, 16]) ...[          
                          InkWell(
                            onTap: () => socket.emit('set_limit', {'roomId': (room as Map)['id'], 'limit': l}),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                              decoration: BoxDecoration(
                                color: limit == l ? const Color(0xFF3A2A1C) : const Color(0xFF2A2824),
                                border: Border.all(color: limit == l ? _signal : _border),
                              ),
                              child: _pt('$l', 12, limit == l ? _signal : _paper, bold: limit == l),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      ]),
                      const SizedBox(height: 4),
                      _pt('点击数字预设地图长度（开局前可随时改）', 10, _dim),
                    ])),
                    const SizedBox(height: 16),
                  ],
                  // 操作区
                  if (isOwner)
                    _btn('开 始 游 戏', _startGame, primary: true, wide: true)
                  else
                    _btn(_myReady ? '✓ 已准备 · 取消' : '准 备', _toggleReady, primary: !_myReady, wide: true),
                  if (!isOwner)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _pt(_otherReady ? '双方已就绪，等待房主开始' : '对手准备后房主才能开始', 11, _dim),
                    ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  bool get _myReady {
    final p = players;
    if (myIdx < 0 || myIdx >= p.length) return false;
    final me = p[myIdx] as Map?;
    return me?['ready'] == true;
  }

  bool get _otherReady {
    final p = players;
    final o = 1 - myIdx;
    if (o < 0 || o >= p.length) return false;
    final op = p[o] as Map?;
    return op != null && op['ready'] == true;
  }

  void _toggleReady() {
    socket.emit('ready', {'ready': !_myReady});
  }

  void _startGame() {
    // 服务端权威校验全员准备，未准备会返回错误提示（客户端不预检，让服务器说话）
    socket.emit('start_game', {'limit': ((room as Map?)?['limit'] as num?)?.toInt() ?? 16});
  }

  void _kick(BuildContext ctx, int idx) {
    final p = players[idx] as Map?;
    if (p == null) return;
    showDialog(
      context: ctx,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('踢出玩家？', style: TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
        content: Text('确定把「${p['name']}」移出房间吗？', style: const TextStyle(color: _paper, fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold))),
          TextButton(
            onPressed: () {
              Navigator.pop(dctx);
              socket.emit('kick', {'roomId': (room as Map)['id'], 'targetIdx': idx});
            },
            child: const Text('踢出', style: TextStyle(color: _signal, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _seat(BuildContext ctx, int idx, bool isMine) {
    final p = idx < players.length ? players[idx] as Map? : null;
    final name = p?['name']?.toString() ?? '';
    final ready = p?['ready'] == true;
    final isHost = idx == hostIdx;
    final empty = p == null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1916),
        border: Border.all(color: isMine ? _signal : _border, width: isMine ? 2 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _pt(isMine ? '你' : (idx == 0 ? '玩家 1' : '玩家 2'), 11, _dim),
          if (isHost) ...[const SizedBox(width: 6), _pt('👑 房主', 11, _warn)],
          const Spacer(),
          if (!empty && !isHost && isOwner)
            InkWell(
              onTap: () => _kick(ctx, idx),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
                child: _pt('踢出', 10, _warn),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Center(
          child: _pt(empty ? '（等待加入…）' : name, 20, empty ? _dim : _paper, bold: !empty),
        ),
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: empty ? const Color(0xFF201E1A) : (ready ? const Color(0xFF1A2E1F) : const Color(0xFF2A2824)),
              border: Border.all(color: empty ? _border : (ready ? _green : _dim)),
            ),
            child: _pt(empty ? '空位' : (ready ? '✓ 已准备' : '未准备'), 12, empty ? _dim : (ready ? _green : _dim), bold: ready),
          ),
        ),
      ]),
    );
  }

  Widget _panel({required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF1A1916), border: Border.all(color: _border, width: 2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _pt('◆ $title', 12, _warn),
        const SizedBox(height: 10),
        child,
      ]),
    );
  }

  Widget _btn(String label, VoidCallback cb, {bool primary = false, bool wide = false}) {
    return InkWell(
      onTap: cb,
      child: Container(
        width: wide ? double.infinity : null,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: primary ? _signal : const Color(0xFF2A2824),
          border: Border.all(color: primary ? const Color(0xFFB12718) : _border, width: 2),
        ),
        child: Center(child: _pt(label, 14, _paper, bold: true)),
      ),
    );
  }
}
