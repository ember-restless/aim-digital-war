// 联机大厅：左=房间列表 中=聊天日志 右=在线玩家
// 内部状态机：lobby（大厅）→ room（房间页）→ game（对局），由 socket 事件驱动切换
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config.dart';
import '../net/socket.dart';
import '../widgets/keyboard_insets.dart';
import '../net/server_list.dart';
import '../net/lan_socket.dart';
import '../net/lan_server.dart';
import '../core/settings_store.dart';
import '../core/bgm_manager.dart';
import 'game_screen.dart';
import 'room_screen.dart';

const _ink = Color(0xFF11110F);
const _paper = Color(0xFFFFF5DC);
const _signal = Color(0xFFFF4E35);
const _dim = Color(0xFF77736B);
const _warn = Color(0xFFFFD36A);
const _border = Color(0xFF5A554C);
const _green = Color(0xFF61D39E);

class LobbyScreen extends StatefulWidget {
  final AimServer server; // 已选中的服务器（联机）
  final String playerName;
  final String packId;
  final bool lan; // 局域网模式：UDP 发现 + 创建者当主机
  const LobbyScreen({
    super.key,
    required this.server,
    required this.playerName,
    required this.packId,
    this.lan = false,
  });

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  // 局域网模式初始为占位空连接（不连任何服务器）；建房/加入时替换为真实 LanSocket。
  // 之前是 late 且局域网从不赋值 → 建房时 socket.dispose() 抛 LateInitializationError → 点了完全没反应
  AIMSocket socket = AIMSocket('');
  bool connected = false;
  String connStatus = '连接中…';

  // 房间列表 / 在线玩家 / 聊天
  List<dynamic> roomList = [];
  List<dynamic> onlineList = [];
  final List<Map<String, dynamic>> chatLog = [];
  final _chatCtrl = TextEditingController();
  final _chatScroll = ScrollController();
  bool _chatAutoScroll = true;

  // 状态机
  String view = 'lobby'; // lobby | room | game
  dynamic room; // room_update
  dynamic you; // you_are
  dynamic gameState; // game_state
  dynamic gameOver; // game_over

  // 断线重连（联机大厅：socket.io 自动重连 + 30s 窗口重进原房间）
  Map<String, dynamic>? _reconnect; // {roomId, playerIdx, name}
  bool _reconnecting = false;
  Timer? _reconnectTimer;

  // 局域网模式
  final LanDiscoverer _discoverer = LanDiscoverer();
  final LanBeacon _beacon = LanBeacon(); // 进大厅就广播「我在这」
  String get _myBeaconId => _beacon.id;
  List<Map<String, dynamic>> lanRooms = [];
  LanServer? _lanServer; // 自己是主机时
  bool lanConnected = false; // 已连上某台主机（自己或别人）

  // 服务器弹窗
  List<AimServer> _servers = [];
  bool _loadingServers = false;
  Timer? _listTimer;

  @override
  void initState() {
    super.initState();
    BgmManager.instance.playIdle(); // 大厅 = 非战斗 BGM
    if (widget.lan) {
      // 局域网：UDP 监听发现房间，不主动连任何主机
      _discoverer.onChanged = () {
        if (mounted) setState(() => lanRooms = List.of(_discoverer.rooms));
      };
      _discoverer.scanName = widget.playerName; // 网段扫描探测包里的名字
      _discoverer.start();
      _beacon.start(widget.playerName); // 在线信标：别人能看见你
      connStatus = '扫描局域网中…';
      _log('系统', '正在扫描同一 WiFi 下的房间…（Minecraft 式组播发现）', sys: true);
      _log('系统', '没有自动发现？点上方「局域网」用手动 IP 连接', sys: true);
    } else {
      _connect(widget.server);
      _listTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (connected && view == 'lobby') {
          socket.emit('list_rooms');
          socket.emit('list_players');
        }
      });
    }
    // 自动滚动聊天：滚动条在底部时跟随
    _chatScroll.addListener(() {
      if (!_chatScroll.hasClients) return;
      _chatAutoScroll = _chatScroll.position.pixels >= _chatScroll.position.maxScrollExtent - 20;
    });
  }

  @override
  void dispose() {
    _listTimer?.cancel();
    _reconnectTimer?.cancel();
    _chatCtrl.dispose();
    _chatScroll.dispose();
    _discoverer.stop();
    _beacon.stop();
    _lanServer?.stop();
    socket.dispose();
    BgmManager.instance.playIdle(); // 回主页兜底：BGM 恢复非战斗
    super.dispose();
  }

  // ── 局域网：连接某台主机（自己创建的主机或发现的房间）──
  void _connectLan(String host) {
    socket.dispose();
    socket = LanSocket('ws://$host:${kLanWsPort}');
    socket.onEvent = _onEvent;
    socket.onServerError = (msg) => _alert('⚠ 提示', msg);
    setState(() {
      view = 'lobby';
      room = null;
      you = null;
      gameState = null;
      gameOver = null;
      connStatus = '连接 $host…';
    });
    _log('系统', '正在连接局域网主机 $host:${kLanWsPort} …', sys: true);
    socket.connect();
  }

  // ── 连接服务器 ──
  void _connect(AimServer server) {
    socket = AIMSocket(server.url);
    socket.onEvent = _onEvent;
    socket.onServerError = (msg) {
      if (_reconnecting) {
        // 重连被服务端拒绝（对局已结束/名字不匹配等）→ 放弃重连回大厅
        _reconnectTimer?.cancel();
        setState(() {
          _reconnecting = false;
          _reconnect = null;
          view = 'lobby';
          room = null;
          you = null;
          gameState = null;
          gameOver = null;
          connStatus = '重连失败，已返回大厅';
        });
      }
      _alert('⚠ 服务器', msg);
    };
    socket.connect();
    setState(() => connStatus = '连接中…');
  }

  void _switchServer(AimServer server) {
    socket.dispose();
    setState(() {
      view = 'lobby';
      room = null;
      you = null;
      gameState = null;
      gameOver = null;
      roomList = [];
      connected = false;
      connStatus = '连接中…';
    });
    _log('系统', '正在切换到服务器「${server.name}」…', sys: true);
    _connect(server);
  }

  void _onEvent(String event, dynamic data) {
    if (!mounted) return;
    switch (event) {
      case 'connect':
        setState(() => connected = true);
        if (widget.lan) _log('系统', '已连接主机，握手…', sys: true);
        socket.emit('hello', {'name': widget.playerName, 'version': AppConfig.appVersion});
        break;
      case 'disconnect':
        setState(() {
          connected = false;
          connStatus = '已断开';
          lanConnected = false;
        });
        _log('系统', widget.lan ? '与局域网主机断开连接' : '与主机断开连接', sys: true);
        // 联机对局/房间中断线 → 自动重连（30s 窗口，socket.io 底层自动重连）
        if (!widget.lan && _reconnect != null && (view == 'room' || view == 'game') && !_reconnecting) {
          setState(() {
            _reconnecting = true;
            connStatus = '连接断开，正在重连…';
          });
          _reconnectTimer?.cancel();
          _reconnectTimer = Timer(const Duration(seconds: 30), () {
            if (!mounted) return;
            _reconnectTimer?.cancel();
            setState(() {
              _reconnecting = false;
              _reconnect = null;
              view = 'lobby';
              room = null;
              you = null;
              gameState = null;
              gameOver = null;
              connStatus = '重连失败，已返回大厅';
            });
            _alert('重连失败', '30 秒内未能重连回对局，已返回大厅。');
          });
        }
        break;
      case 'hello_ok':
        final d = (data as Map?) ?? {};
        setState(() {
          connStatus = '已连接 · ${d['server']?['name'] ?? (widget.lan ? '局域网' : widget.server.name)}';
          lanConnected = true;
        });
        _log('系统', widget.lan
            ? '已连接局域网主机（${widget.server.host}）'
            : '已连接「${widget.server.name}」',
            sys: true);
        _log('系统', '名字：${widget.playerName} · 输入消息回车发送', sys: true);
        // 断线重连：重新加入原房间（服务端恢复座位 + 推最新棋盘）
        if (_reconnecting && _reconnect != null) {
          socket.emit('join_room', {
            'roomId': _reconnect!['roomId'],
            'name': widget.playerName,
            'reconnectIdx': _reconnect!['playerIdx'],
          });
          break;
        }
        if (widget.lan) {
          if (_lanServer != null) {
            // 自己是主机：自动建房
            socket.emit('create_room', {
              'name': widget.playerName,
              'title': _lanServer!.roomTitle,
              'password': _lanServer!.password,
            });
          } else if (_pendingJoin != null) {
            socket.emit('join_room', {
              'roomId': 'LAN',
              'name': widget.playerName,
              'password': _pendingJoin!['password'],
            });
            _pendingJoin = null;
          }
        } else {
          socket.emit('list_rooms');
          socket.emit('list_players'); // 主动拉在线列表（不依赖 hello 推送）
        }
        break;
      case 'room_list':
        setState(() => roomList = (data as List?) ?? []);
        break;
      case 'player_list':
        setState(() => onlineList = (data as List?) ?? []);
        break;
      case 'chat':
        final d = (data as Map?) ?? {};
        _log(d['name']?.toString() ?? '?', d['msg']?.toString() ?? '', sys: d['sys'] == true);
        break;
      case 'you_are':
        setState(() => you = data);
        if (view == 'lobby') setState(() => view = 'room');
        // 记录重连上下文（观战者 playerIdx=-1 不参与重连）
        final d0 = (data as Map?) ?? {};
        final idx0 = (d0['playerIdx'] as num?)?.toInt() ?? -1;
        if (idx0 >= 0 && !widget.lan) {
          _reconnect = {'roomId': d0['roomId'], 'playerIdx': idx0, 'name': widget.playerName};
        }
        // 重连成功：清除重连状态
        if (_reconnecting) {
          _reconnectTimer?.cancel();
          setState(() => _reconnecting = false);
          _log('系统', '重连成功，已回到对局', sys: true);
        }
        break;
      case 'room_update':
        setState(() => room = data);
        break;
      case 'game_state':
        setState(() {
          gameState = data;
          view = 'game';
        });
        break;
      case 'game_over':
        setState(() => gameOver = data);
        break;
      case 'kicked':
        _alert('被移出房间', '你已被房主移出房间');
        socket.emit('list_rooms');
        setState(() {
          view = 'lobby';
          room = null;
          you = null;
        });
        break;
    }
  }

  void _log(String name, String msg, {bool sys = false}) {
    if (!mounted) return;
    setState(() {
      chatLog.add({'name': name, 'msg': msg, 'sys': sys});
      if (chatLog.length > 200) chatLog.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients && _chatAutoScroll) {
        _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
      }
    });
  }

  void _sendChat() {
    final m = _chatCtrl.text.trim();
    if (m.isEmpty) return;
    socket.emit('chat', {'msg': m});
    _chatCtrl.clear();
  }

  void _alert(String title, String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: Text(title, style: const TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
        content: Text(msg, style: const TextStyle(color: _paper, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了', style: TextStyle(color: _signal, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── 创建/加入/观战 ──
  Future<void> _createRoom() async {
    final titleCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    var allowOwnRollerAttack = true; // 规则开关：默认开（保持「敌我皆可」）
    final res = await showDialog<(bool, bool)>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1916),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: const Text('创建房间', style: TextStyle(color: _signal, fontSize: 15, fontWeight: FontWeight.bold)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: titleCtrl,
              maxLength: 16,
              style: const TextStyle(color: _paper, fontSize: 14),
              decoration: const InputDecoration(
                counterText: '', labelText: '房间名（可留空）',
                labelStyle: TextStyle(color: _dim, fontSize: 13),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pwdCtrl,
              maxLength: 12,
              obscureText: true,
              style: const TextStyle(color: _paper, fontSize: 14),
              decoration: const InputDecoration(
                counterText: '', labelText: '密码（可留空）',
                labelStyle: TextStyle(color: _dim, fontSize: 13),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // 规则开关：滚木能否被己方攻击
            InkWell(
              onTap: () => setDlg(() => allowOwnRollerAttack = !allowOwnRollerAttack),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: allowOwnRollerAttack ? const Color(0xFF1C2E22) : const Color(0xFF2A2824),
                  border: Border.all(color: allowOwnRollerAttack ? _green : _border),
                ),
                child: Row(children: [
                  _pt(allowOwnRollerAttack ? '✓' : '✗', 14, allowOwnRollerAttack ? _green : _dim, bold: true),
                  const SizedBox(width: 8),
                  Expanded(child: _pt('滚木可被己方攻击', 13, _paper, bold: allowOwnRollerAttack)),
                ]),
              ),
            ),
            const SizedBox(height: 4),
            _pt(allowOwnRollerAttack ? '己方可以打掉自己滚木（清理路障）' : '己方滚木免疫己方攻击，只能由敌方击破', 10, _dim),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, (false, allowOwnRollerAttack)), child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold))),
            TextButton(onPressed: () => Navigator.pop(ctx, (true, allowOwnRollerAttack)), child: const Text('创建', style: TextStyle(color: _signal, fontWeight: FontWeight.bold))),
          ],
        );
      }),
    );
    if (res == null || !res.$1) return;
    final allowOwn = res.$2;
    if (widget.lan) {
      await _createRoomLan(
        title: titleCtrl.text.trim().isEmpty ? '${widget.playerName} 的房间' : titleCtrl.text.trim(),
        password: pwdCtrl.text.trim().isEmpty ? null : pwdCtrl.text.trim(),
        allowOwnRollerAttack: allowOwn,
      );
      return;
    }
    socket.emit('create_room', {
      'name': widget.playerName,
      'title': titleCtrl.text.trim().isEmpty ? null : titleCtrl.text.trim(),
      'password': pwdCtrl.text.trim().isEmpty ? null : pwdCtrl.text.trim(),
      'allowOwnRollerAttack': allowOwn,
    });
  }

  // 局域网创建房间：本机当主机（起 LanServer + UDP 广播），然后连自己
  Future<void> _createRoomLan({required String title, String? password, bool allowOwnRollerAttack = true}) async {
    _lanServer?.stop();
    _log('系统', '正在启动局域网房间（探测本机 IP）…', sys: true);
    final server = LanServer(roomTitle: title, password: password, limit0: 16, allowOwnRollerAttack: allowOwnRollerAttack);
    final ok = await server.start();
    if (!ok) {
      _alert('启动失败', '局域网主机启动失败，可能端口被占用。请检查后重试。');
      return;
    }
    _lanServer = server;
    server.onSysLog = (m) => _log('系统', m, sys: true);
    // 连自己
    _connectLan('127.0.0.1');
  }

  Future<void> _joinRoom(Map r) async {
    final hasPwd = r['hasPassword'] == true;
    String? pwd;
    if (hasPwd) {
      final pwdCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1916),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: const Text('输入房间密码', style: TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: pwdCtrl,
            obscureText: true,
            style: const TextStyle(color: _paper, fontSize: 14),
            decoration: const InputDecoration(
              labelText: '密码', labelStyle: TextStyle(color: _dim, fontSize: 13),
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('加入', style: TextStyle(color: _signal, fontWeight: FontWeight.bold))),
          ],
        ),
      );
      if (ok != true) return;
      pwd = pwdCtrl.text.trim();
    }
    if (widget.lan) {
      // 局域网：连到该房间的主机再加入（连自己的房间用 127.0.0.1）
      final rh = (r['host'] as String? ?? '');
      final selfIp = _lanServer?.localIp;
      final host = (selfIp != null && rh == selfIp) ? '127.0.0.1' : rh;
      _connectLan(host);
      _pendingJoin = {'roomId': 'LAN', 'password': pwd};
      return;
    }
    socket.emit('join_room', {'roomId': r['id'], 'name': widget.playerName, 'password': pwd});
  }

  // 局域网模式下等待连接成功后再发 join
  Map<String, dynamic>? _pendingJoin;

  Future<void> _spectate(Map r) async {
    final hasPwd = r['hasPassword'] == true;
    String? pwd;
    if (hasPwd) {
      final pwdCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1916),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: const Text('输入房间密码', style: TextStyle(color: _warn, fontSize: 15, fontWeight: FontWeight.bold)),
          content: TextField(
            controller: pwdCtrl,
            obscureText: true,
            style: const TextStyle(color: _paper, fontSize: 14),
            decoration: const InputDecoration(
              labelText: '密码', labelStyle: TextStyle(color: _dim, fontSize: 13),
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('观战', style: TextStyle(color: _signal, fontWeight: FontWeight.bold))),
          ],
        ),
      );
      if (ok != true) return;
      pwd = pwdCtrl.text.trim();
    }
    if (widget.lan) {
      _connectLan((r['host'] as String? ?? ''));
      _pendingJoin = {'roomId': 'LAN', 'password': pwd};
      return;
    }
    socket.emit('join_room', {'roomId': r['id'], 'name': widget.playerName, 'password': pwd});
  }

  // ── 服务器选择弹窗 ──
  Future<void> _openServerDialog() async {
    setState(() => _loadingServers = true);
    final servers = await fetchServers();
    for (final s in servers) {
      s.latencyMs = await measureLatency(s, tries: 2);
    }
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _loadingServers = false;
    });
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return Dialog(
          backgroundColor: const Color(0xFF1A1916),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              _pt('选择服务器', 15, _signal),
              const SizedBox(height: 10),
              if (_loadingServers)
                const Padding(padding: EdgeInsets.all(12), child: Center(child: Text('测延迟中…', style: TextStyle(color: _dim))))
              else
                ..._servers.map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        onTap: () {
                          if (s.full) return;
                          Navigator.pop(ctx);
                          _switchServer(s);
                          SettingsStore.lastServer = s.url;
                          SettingsStore.save();
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: s.full ? const Color(0xFF201E1A) : const Color(0xFF2A2824),
                            border: Border.all(
                                color: s.url == widget.server.url ? _signal : _border,
                                width: s.url == widget.server.url ? 2 : 1),
                          ),
                          child: Row(children: [
                            Expanded(child: _pt('${s.name}${s.official ? ' ★' : ''}', 13, _paper)),
                            _pt('${s.players}/${s.maxPlayers}', 12, s.full ? _dim : _green),
                            const SizedBox(width: 8),
                            _pt(s.latencyMs == null ? '--' : '${s.latencyMs}ms', 12, s.latencyMs == null ? _dim : _warn),
                          ]),
                        ),
                      ),
                    )),
              if (_servers.isEmpty && !_loadingServers) _pt('（目录服务无响应）', 12, _dim),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      // 复制服务器配置包下载地址（引导搭建服务器用）
                      await Clipboard.setData(const ClipboardData(text: 'http://192.140.166.178:5000/aim-server.zip'));
                      if (ctx.mounted) Navigator.pop(ctx);
                      _alert('已复制链接', '服务器配置包下载地址已复制到剪贴板。在浏览器打开下载，按包内 README 引导搭建自己的服务器。');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(color: const Color(0xFF3A2A1C), border: Border.all(color: _signal)),
                      child: Center(child: _pt('下载服务器配置包', 12, _warn)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      _manualConnect();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
                      child: Center(child: _pt('手动输入 IP 连接', 12, _paper)),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
        );
      }),
    );
  }

  Future<void> _manualConnect() async {
    final ipCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('连接服务器', style: TextStyle(color: _signal, fontSize: 15, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ipCtrl,
          keyboardType: TextInputType.url,
          style: const TextStyle(color: _paper, fontSize: 14),
          decoration: const InputDecoration(
            hintText: '192.168.1.100:5000',
            hintStyle: TextStyle(color: _dim, fontSize: 13),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('连接', style: TextStyle(color: _signal, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    var input = ipCtrl.text.trim();
    if (input.isEmpty) return;
    if (!input.contains('://')) input = 'http://' + input;
    final s = AimServer(id: 'manual', name: '手动服务器', host: '', port: 5000, players: 0, maxPlayers: 99, version: '?');
    try {
      final u = Uri.parse(input);
      final ms = await measureLatency(AimServer(id: 'manual', name: '手动', host: u.host, port: u.port, players: 0, maxPlayers: 99, version: '?'), tries: 2);
      if (!mounted) return;
      if (ms == null) {
        _alert('连接失败', '无法连接到 $input，请检查地址和网络');
        return;
      }
      final ns = AimServer(id: 'manual', name: '手动服务器', host: u.host, port: u.port, players: 0, maxPlayers: 99, version: '?', latencyMs: ms);
      _switchServer(ns);
      SettingsStore.lastServer = ns.url;
      SettingsStore.save();
    } catch (_) {
      _alert('连接失败', '地址格式不对：$input');
    }
  }

  // ── 退出对局回大厅 ──
  void _backToLobby() {
    socket.emit('leave_room');
    BgmManager.instance.playIdle(); // 对局结束回大厅：BGM 切回非战斗
    if (widget.lan) {
      // 主机：解散房间并关闭主机，回到发现模式；非主机：断开连接
      if (_lanServer != null) {
        _lanServer?.stop();
        _lanServer = null;
      }
      setState(() {
        view = 'lobby';
        room = null;
        you = null;
        gameState = null;
        gameOver = null;
        lanConnected = false;
      });
      connStatus = '扫描局域网中…';
      _log('系统', '已回到局域网大厅', sys: true);
      return;
    }
    setState(() {
      view = 'lobby';
      room = null;
      you = null;
      gameState = null;
      gameOver = null;
    });
    socket.emit('list_rooms');
  }

  Widget _pt(String s, double size, Color c, {bool bold = false, bool center = false}) {
    return Text(s,
        style: TextStyle(color: c, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal, height: 1.2),
        textAlign: center ? TextAlign.center : TextAlign.left);
  }

  @override
  Widget build(BuildContext context) {
    // 对局中：整屏 GameScreen（断线重连时盖一层重连遮罩）
    if (view == 'game' && gameState != null) {
      final gs = GameScreen(
        socket: socket,
        state: gameState,
        packId: widget.packId,
        over: gameOver,
        onBack: _backToLobby,
      );
      if (!_reconnecting) return gs;
      return Stack(children: [
        gs,
        Positioned.fill(
          child: Container(
            color: const Color(0xAA11110F),
            child: Center(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(color: _signal, strokeWidth: 3)),
                const SizedBox(height: 14),
                _pt('连接断开，正在重连…', 15, _paper, bold: true),
                const SizedBox(height: 4),
                _pt('30 秒内未重连将返回大厅', 11, _dim),
              ]),
            ),
          ),
        ),
      ]);
    }
    // 房间页
    if (view == 'room' && room != null && you != null) {
      return RoomScreen(
        room: room,
        you: you,
        socket: socket,
        playerName: widget.playerName,
        onLeave: _backToLobby,
      );
    }
    // 大厅
    return Scaffold(
      body: Container(
        color: _ink,
        child: SafeArea(
          child: Column(children: [
            _topBar(),
            const Divider(color: _border, height: 1),
            Expanded(child: _body()),
          ]),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        InkWell(
          onTap: () {
            BgmManager.instance.playIdle();
            Navigator.pop(context);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
            child: _pt('← 返回', 12, _paper),
          ),
        ),
        const SizedBox(width: 10),
        InkWell(
          onTap: widget.lan ? _lanManualConnect : _openServerDialog,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: const Color(0xFF1A1916), border: Border.all(color: _signal, width: 1)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _pt(widget.lan ? '局域网' : '${widget.server.name}', 13, _signal, bold: true),
              const SizedBox(width: 4),
              _pt('▾', 12, _signal),
            ]),
          ),
        ),
        const SizedBox(width: 10),
        _pt(connStatus, 11, connected ? _green : _warn),
        const Spacer(),
        _pt('${widget.playerName}', 12, _dim),
      ]),
    );
  }

  // 局域网手动 IP 连接
  Future<void> _lanManualConnect() async {
    final ipCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1916),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: const Text('连接局域网主机', style: TextStyle(color: _signal, fontSize: 15, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ipCtrl,
          keyboardType: TextInputType.url,
          style: const TextStyle(color: _paper, fontSize: 14),
          decoration: const InputDecoration(
            hintText: '192.168.1.100',
            hintStyle: TextStyle(color: _dim, fontSize: 13),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: _dim, fontWeight: FontWeight.bold))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('连接', style: TextStyle(color: _signal, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    final ip = ipCtrl.text.trim();
    if (ip.isEmpty) return;
    // 断开当前主机（自己开的主机也停掉）
    if (_lanServer != null) {
      _lanServer?.stop();
      _lanServer = null;
    }
    _connectLan(ip);
  }

  // 三栏 / 小屏 Tab（小屏判断用宽度：手机横屏宽 800+ 必须三栏左中右）
  Widget _body() {
    final small = MediaQuery.sizeOf(context).width < 600;
    if (small) {
      return DefaultTabController(
        length: 3,
        child: Column(children: [
          const TabBar(
            tabs: [Tab(text: '房间'), Tab(text: '聊天'), Tab(text: '在线')],
            labelColor: _signal,
            unselectedLabelColor: _dim,
            indicatorColor: _signal,
          ),
          const Divider(color: _border, height: 1),
          Expanded(
            child: TabBarView(children: [
              _roomPanel(),
              _chatPanel(),
              _onlinePanel(),
            ]),
          ),
          _bottomBar(),
        ]),
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 260, child: Column(children: [
        Expanded(child: _roomPanel()), // 修复：房间面板必须包 Expanded，否则撑满把底部创建按钮挤出屏幕
        const Divider(color: _border, height: 1),
        _bottomBar(),
      ])),
      const VerticalDivider(width: 1, color: _border),
      Expanded(child: _chatPanel()),
      const VerticalDivider(width: 1, color: _border),
      SizedBox(width: 180, child: _onlinePanel()),
    ]);
  }

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(children: [
        Expanded(
          child: InkWell(
            onTap: _createRoom,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(color: _signal, border: Border.all(color: const Color(0xFFB12718), width: 2)),
              child: Center(child: _pt('创建房间', 13, _paper, bold: true)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: () => socket.emit('list_rooms'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border, width: 2)),
            child: _pt('刷新', 12, _paper),
          ),
        ),
      ]),
    );
  }

  Widget _roomPanel() {
    // 局域网：只列真正的房间（有 port 的广播）；在线信标（无 port）只进「在线玩家」
    final list = widget.lan
        ? lanRooms.where((r) => r['port'] != null).toList()
        : roomList;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: _pt('房间列表 // ${list.length}', 12, _dim),
      ),
      Expanded(
        child: list.isEmpty
            ? Center(
                child: _pt(widget.lan ? '（未发现房间：点上方「局域网」手动输 IP，或点下方创建）' : '（暂无房间，点下方创建）', 12, _dim),
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: list.length,
                itemBuilder: (c, i) {
                  final r = list[i] as Map;
                  final playing = r['status'] == 'playing';
                  final title = (r['title'] ?? r['name'] ?? r['id']).toString();
                  String sub;
                  String countTxt;
                  if (widget.lan) {
                    sub = r['host']?.toString() ?? '';
                    countTxt = '${r['players'] ?? 0}/${r['maxPlayers'] ?? 2}';
                  } else {
                    final names = ((r['players'] as List?) ?? [])
                        .map((p) => (p as Map?)?['name']?.toString() ?? '?')
                        .join(' vs ');
                    sub = names.isEmpty ? '（空位）' : names;
                    countTxt = playing ? '对战中' : '${((r['players'] as List?) ?? []).where((p) => p != null).length}/2';
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: InkWell(
                      onTap: () => playing ? _spectate(r) : _joinRoom(r),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1916),
                          border: Border.all(color: playing ? const Color(0xFF4A3A1A) : _border),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(child: _pt('${r['title'] ?? r['id']}', 13, _paper, bold: true)),
                                if (r['hasPassword'] == true) ...[
                                  const SizedBox(width: 4),
                                  _pt('🔒', 10, _warn),
                                ],
                              ]),
                              _pt(sub, 11, _dim),
                            ]),
                          ),
                          _pt(countTxt, 11, playing ? _warn : _green),
                          const SizedBox(width: 6),
                          if (playing)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0xFF2A2824), border: Border.all(color: _border)),
                              child: _pt('👁 观战', 11, _warn),
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0xFF3A2A1C), border: Border.all(color: _signal)),
                              child: _pt('加入', 11, _signal, bold: true),
                            ),
                        ]),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _chatPanel() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Row(children: [
          _pt('通信日志 //', 12, _dim),
          const SizedBox(width: 8),
          _pt('大厅聊天，所有人可见', 10, _dim),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          controller: _chatScroll,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: chatLog.length,
          itemBuilder: (c, i) {
            final m = chatLog[i];
            final sys = m['sys'] == true;
            return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _pt(sys ? '[${m['name']}]' : '${m['name']}:', 12, sys ? _dim : _signal, bold: !sys),
                const SizedBox(width: 6),
                Expanded(child: _pt('${m['msg']}', 12, sys ? _dim : _paper)),
              ]),
            );
          },
        ),
      ),
      const Divider(color: _border, height: 1),
      // 输入行：adjustNothing 下键盘悬浮在画面上，用原生键盘高度把输入行抬到键盘上方
      ValueListenableBuilder<double>(
        valueListenable: KeyboardInsets.instance.height,
        builder: (c, kb, _) => Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + kb),
          child: Row(children: [
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: const Color(0xFF1A1916), border: Border.all(color: _border)),
                child: TextField(
                  controller: _chatCtrl,
                  style: const TextStyle(color: _paper, fontSize: 13),
                  decoration: const InputDecoration(hintText: '说点什么…', hintStyle: TextStyle(color: _dim, fontSize: 12), border: InputBorder.none, isDense: true),
                  onSubmitted: (_) => _sendChat(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: _sendChat,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(color: _signal, border: Border.all(color: const Color(0xFFB12718), width: 2)),
                child: _pt('发送', 12, _paper, bold: true),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _onlinePanel() {
    // 局域网：自己 + 在线信标的人（无 port）+ 房间主（有 port）
    final List<Map<String, dynamic>> items;
    if (widget.lan) {
      items = [
        {
          'name': '${SettingsStore.playerName}（我）',
          'status': _lanServer != null ? 'room:lan' : 'lobby',
        },
        for (final r in lanRooms.where((r) => r['port'] == null && r['id'] != _myBeaconId))
          {
            'name': '${r['name'] ?? '未知玩家'}',
            'status': 'lobby',
            'sub': '${r['host']}',
          },
        for (final r in lanRooms.where((r) => r['port'] != null))
          {
            'name': '主机 · ${r['name'] ?? '未知房间'}',
            'status': 'room:${r['key']}',
            'sub': '${r['host']}:${r['port']}',
          },
      ];
    } else {
      items = List<Map<String, dynamic>>.from(onlineList);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: _pt('在线玩家 // ${items.length}', 12, _dim),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: items.length,
          itemBuilder: (c, i) {
            final o = items[i];
            final st = o['status']?.toString() ?? 'lobby';
            final inRoom = st.startsWith('room:');
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(color: const Color(0xFF1A1916), border: Border.all(color: _border)),
                child: Row(children: [
                  Expanded(child: _pt('${o['name']}', 12, _paper)),
                  if (o['sub'] != null) ...[
                    _pt('${o['sub']}', 9, _dim),
                    const SizedBox(width: 6),
                  ],
                  _pt(inRoom ? '房间中' : '在大厅', 10, inRoom ? _warn : _green),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
