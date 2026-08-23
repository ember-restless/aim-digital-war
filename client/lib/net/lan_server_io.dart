// 局域网主机（创建者设备）：WebSocket 房间服务器 + UDP 组播广播（Minecraft 式发现）
// 规则用本地 AimGame；协议事件名与联机服务端一致，客户端界面完全复用
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as _m;

import '../game/rules.dart';

const int kLanWsPort = 45679; // WebSocket 房间服务端口
class _BeaconRnd {
  final _rnd = _m.Random();
  int nextInt(int max) => _rnd.nextInt(max);
}

const int kLanUdpPort = 45678; // UDP 发现端口
const String kLanMulticast = '224.0.2.60'; // Minecraft 同款组播地址

class LanPlayer {
  final WebSocket ws; // 全部玩家（含主机）都走 WebSocket，统一逻辑
  String name;
  bool ready;
  LanPlayer(this.ws, this.name, {this.ready = false});
}

class LanServer {
  final String roomTitle;
  final String? password;
  final int limit0;
  final int port; // 可配置（测试用不同端口避免冲突）
  final bool allowOwnRollerAttack; // 规则开关：己方能否攻击己方滚木（创建房间时定，默认开）

  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _beaconTimer;
  final List<LanPlayer> _players = []; // 最多2
  final List<LanPlayer> _spectators = [];
  AimGame? game;
  String status = 'waiting'; // waiting | playing | ended
  int limit;
  int hostIdx = 0;
  String? winner;
  int _seq = 1;
  String? _localIp;

  /// 本机局域网 IP（供大厅注入自己的房间条目 / 判断"是不是自己"）
  String? get localIp => _localIp;

  // 事件回调（给 UI 层：日志等）
  void Function(String msg)? onSysLog;

  LanServer({required this.roomTitle, this.password, this.limit0 = 16, this.port = kLanWsPort, this.beacon = true, this.allowOwnRollerAttack = true})
      : limit = limit0;

  final bool beacon; // 是否启动 UDP 组播广播（测试环境沙箱禁 UDP，关掉）

  String get id => 'LAN';

  Future<bool> start() async {
    try {
      // 本机局域网 IP（用于广播）
      _localIp = await _findLocalIp();
      _http = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _http!.listen(_handleHttp);
      // UDP 组播广播（Minecraft 式房间发现）
      if (beacon) {
        try {
          _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true);
          _udp!.listen((ev) {});
          _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) => _beacon());
        } catch (_) {}
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<String?> _findLocalIp() async {
    // 纯本地枚举网卡 IPv4（不依赖外网/服务器，局域网断外网也能用）
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifs) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue; // 回环/APIPA
          return ip;
        }
      }
    } catch (_) {}
    return null; // 拿不到就广播 255.255.255.255
  }

  // 广播房间信息：组播 + 广播双发（部分路由器过滤组播时广播兜底）
  void _beacon() {
    if (_udp == null) return;
    final data = jsonEncode({
      'name': roomTitle,
      'host': _localIp,
      'selfIp': _localIp,
      'port': port,
      'players': _players.where((p) => p != null).length,
      'maxPlayers': 2,
      'spectators': _spectators.length,
      'hasPassword': password != null,
      'status': status,
      'version': '0.3.0',
      'lan': true,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    final bytes = utf8.encode(data);
    final target = _localIp != null
        ? InternetAddress(kLanMulticast)
        : InternetAddress('255.255.255.255');
    try {
      _udp!.send(bytes, target, kLanUdpPort);
      // 广播兜底
      if (_localIp != null) {
        _udp!.send(bytes, InternetAddress('255.255.255.255'), kLanUdpPort);
      }
    } catch (_) {}
  }

  void _handleHttp(HttpRequest req) async {
    if (req.uri.path == '/api/version') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'name': 'AIM LAN', 'version': '0.3.0'}));
      await req.response.close();
      return;
    }
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      try {
        final ws = await WebSocketTransformer.upgrade(req);
        _handleClient(ws);
      } catch (_) {
        req.response.statusCode = 400;
        await req.response.close();
      }
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  void _handleClient(WebSocket ws) {
    ws.listen((raw) {
      try {
        final m = jsonDecode(raw as String) as Map<String, dynamic>;
        _dispatch(ws, m['e'] as String? ?? '', (m['d'] as Map?) ?? {});
      } catch (_) {}
    }, onDone: () => _onDisconnect(ws), onError: (_) => _onDisconnect(ws));
  }

  void _send(WebSocket ws, String event, dynamic data) {
    try {
      ws.add(jsonEncode({'e': event, 'd': data}));
    } catch (_) {}
  }

  void _broadcast(String event, dynamic data) {
    for (final p in [..._players, ..._spectators]) {
      _send(p.ws, event, data);
    }
  }

  void _sys(String msg) {
    _broadcast('chat', {'name': '系统', 'msg': msg, 'sys': true});
    onSysLog?.call(msg);
  }

  String _clipName(String? name, String fallback) {
    var n = (name == null || name.isEmpty) ? fallback : name;
    if (n.length > 12) n = n.substring(0, 12);
    return n;
  }

  void _dispatch(WebSocket ws, String event, Map d) {
    switch (event) {
      case 'hello':
        _send(ws, 'hello_ok', {'name': _clipName(d['name'] as String?, '玩家'), 'server': {'name': '局域网 · $roomTitle', 'maxPlayers': 2, 'online': _players.length + _spectators.length}});
        break;
      case 'create_room':
        if (_players.isNotEmpty) {
          _send(ws, 'error', {'msg': '房间已存在'});
          return;
        }
        _players.add(LanPlayer(ws, _clipName(d['name'] as String?, '玩家1')));
        hostIdx = 0;
        _send(ws, 'you_are', {'roomId': 'LAN', 'playerIdx': 0});
        _broadcastRoom();
        _broadcastPlayers();
        _sys('「${_players[0].name}」创建了房间「$roomTitle」');
        break;
      case 'join_room':
        if (_players.length >= 2 && status == 'waiting') {
          _send(ws, 'error', {'msg': '房间已满'});
          return;
        }
        if (password != null && password != (d['password'] as String? ?? '')) {
          _send(ws, 'error', {'msg': '密码错误'});
          return;
        }
        if (_players.length >= 2) {
          // playing 观战
          if (status == 'playing' && _spectators.length < 8) {
            _spectators.add(LanPlayer(ws, _clipName(d['name'] as String?, '观战者')));
            _send(ws, 'you_are', {'roomId': 'LAN', 'playerIdx': -1, 'spectator': true});
            if (game != null) {
              _send(ws, 'game_state', game!.viewForSpectator());
            }
            _broadcastRoom();
            _sys('「${_spectators.last.name}」进入观战');
          } else {
            _send(ws, 'error', {'msg': '房间已满'});
          }
          return;
        }
        final idx = _players.isEmpty ? 0 : 1;
        _players.add(LanPlayer(ws, _clipName(d['name'] as String?, '玩家${idx + 1}')));
        if (_players.length == 1) hostIdx = 0;
        _send(ws, 'you_are', {'roomId': 'LAN', 'playerIdx': idx});
        _broadcastRoom();
        _broadcastPlayers();
        _sys('「${_players[idx].name}」加入房间');
        break;
      case 'ready':
        final p = _findByWs(ws);
        if (p != null && status == 'waiting') {
          p.ready = d['ready'] == true;
          _broadcastRoom();
        }
        break;
      case 'set_limit':
        if (ws == _players[hostIdx].ws && status == 'waiting' && [12, 14, 16].contains(d['limit'])) {
          limit = (d['limit'] as num).toInt();
          _broadcastRoom();
        }
        break;
      case 'set_side':
        if (ws == _players[hostIdx].ws && status == 'waiting' && _players.length == 2) {
          final side = d['side'];
          // 双向切换：房主在左可换右，在右可换回左（原实现只处理 right → 换回左失效）
          final wantSwap = (side == 'right' && hostIdx == 0) || (side == 'left' && hostIdx == 1);
          if (wantSwap) {
            final tmp = _players[0];
            _players[0] = _players[1];
            _players[1] = tmp;
            hostIdx = hostIdx == 0 ? 1 : 0;
            // 重发 you_are：双方 playerIdx 随交换更新
            for (int i = 0; i < _players.length; i++) {
              _send(_players[i].ws, 'you_are', {'roomId': 'LAN', 'playerIdx': i});
            }
          }
          _broadcastRoom();
        }
        break;
      case 'kick':
        final targetIdx = (d['targetIdx'] as num?)?.toInt();
        if (ws == _players[hostIdx].ws && status == 'waiting' && targetIdx != null &&
            targetIdx >= 0 && targetIdx < _players.length && targetIdx != hostIdx) {
          final kicked = _players[targetIdx];
          _send(kicked.ws, 'kicked', {'roomId': 'LAN'});
          _players.removeAt(targetIdx);
          if (hostIdx > targetIdx) hostIdx--;
          _broadcastRoom();
          _broadcastPlayers();
          _sys('玩家被移出了房间');
        }
        break;
      case 'start_game':
        if (ws == _players[hostIdx].ws && status == 'waiting') {
          final count = _players.length;
          if (count < 2) {
            _send(ws, 'error', {'msg': '需要两名玩家'});
            return;
          }
          if (!_players.every((p) => p == null || p == _players[hostIdx] || p.ready)) {
            _send(ws, 'error', {'msg': '有玩家未准备'});
            return;
          }
          game = AimGame(limit: limit, allowOwnRollerAttack: allowOwnRollerAttack);
          status = 'playing';
          _broadcastGame();
          _sys('对局开始！');
        }
        break;
      case 'action':
        final p = _findByWs(ws);
        if (p == null || game == null || status != 'playing') return;
        final pi = _players.indexOf(p);
        if (pi < 0) return; // 观战者不能操作
        final res = game!.applyAction(game!.turn, (d['action'] as Map).cast<String, dynamic>(),
            deferRoll: true);
        if (res['ok'] != true) {
          _send(ws, 'error', {'msg': res['reason']?.toString() ?? '操作不合法'});
          return;
        }
        _broadcastGame();
        break;
      case 'roll_step':
        if (game == null || status != 'playing') return;
        final acts = game!.rollStepOnce(game!.turn);
        if (acts == null) {
          game!.clearPendingRoll();
        }
        if (game!.winner != null) {
          status = 'ended';
          _broadcast('game_over', {
            'winner': game!.winner,
            'winnerName': '玩家${game!.winner! + 1}',
          });
        }
        _broadcastGame();
        break;
      case 'chat':
        final p = _findByWs(ws);
        final name = p?.name ?? '玩家';
        var msg = (d['msg'] as String? ?? '').toString();
        if (msg.length > 200) msg = msg.substring(0, 200);
        _broadcast('chat', {'name': name, 'msg': msg});
        break;
      case 'ingame_chat':
        // 对局内快捷消息（Kards 式）：发给房间内其他玩家/观战，不含自己
        final p2 = _findByWs(ws);
        final name2 = p2?.name ?? '玩家';
        var m2 = (d['msg'] as String? ?? '').toString();
        if (m2.length > 40) m2 = m2.substring(0, 40);
        if (m2.trim().isEmpty) break;
        for (final q in [..._players, ..._spectators]) {
          if (q != null && q.ws != ws) _send(q.ws, 'ingame_chat', {'name': name2, 'msg': m2});
        }
        break;
      case 'list_rooms':
        _send(ws, 'room_list', [pub()]);
        break;
      case 'leave_room':
        _onDisconnect(ws);
        break;
    }
  }

  LanPlayer? _findByWs(WebSocket ws) {
    for (final p in _players) {
      if (p.ws == ws) return p;
    }
    for (final p in _spectators) {
      if (p.ws == ws) return p;
    }
    return null;
  }

  void _onDisconnect(WebSocket ws) {
    final pi = _players.indexWhere((p) => p.ws == ws);
    if (pi >= 0) {
      final name = _players[pi].name;
      final wasHost = pi == hostIdx;
      if (status == 'playing' && game != null && game!.winner == null) {
        game!.winner = 1 - pi;
        status = 'ended';
        _broadcast('game_over', {'winner': 1 - pi, 'winnerName': '玩家${2 - pi}'});
      }
      _players.removeAt(pi);
      if (pi < hostIdx) hostIdx--;
      if (hostIdx < 0 || hostIdx >= _players.length) hostIdx = _players.isEmpty ? 0 : 0;
      // 房主退出 → 剩余第一个玩家接管房主
      if (wasHost) hostIdx = 0;
      // 关键修复：重发 you_are 给剩余玩家，更新 playerIdx（否则换过位后成员退出，
      // 房主的客户端 myIdx 还是旧索引 → 被当成成员，只剩准备键）
      for (int i = 0; i < _players.length; i++) {
        _send(_players[i].ws, 'you_are', {'roomId': 'LAN', 'playerIdx': i});
      }
      _broadcastRoom();
      _broadcastPlayers();
      _sys('「$name」断开了连接');
      return;
    }
    final si = _spectators.indexWhere((p) => p.ws == ws);
    if (si >= 0) {
      _spectators.removeAt(si);
      _broadcastRoom();
      _broadcastPlayers();
    }
  }

  void _broadcastRoom() {
    _broadcast('room_update', pub());
  }

  // 在线玩家列表（大厅右侧「在线的人」）——局域网单房间，所有入房者都在线
  void _broadcastPlayers() {
    final list = [
      for (final p in _players) {'name': p.name, 'status': 'room:LAN', 'roomId': 'LAN'},
      for (final sp in _spectators) {'name': sp.name, 'status': 'room:LAN', 'roomId': 'LAN'},
    ];
    _broadcast('player_list', list);
  }

  void _broadcastGame() {
    if (game == null) return;
    for (int i = 0; i < _players.length; i++) {
      _send(_players[i].ws, 'game_state', game!.viewFor(i));
    }
    final sv = game!.viewForSpectator();
    for (final sp in _spectators) {
      _send(sp.ws, 'game_state', sv);
    }
  }

  Map<String, dynamic> pub() {
    return {
      'id': 'LAN',
      'title': roomTitle,
      'name': 'LAN',
      'status': status,
      'mode': 'online',
      'limit': limit,
      'hostSide': hostIdx == 1 ? 'right' : 'left',
      'hostIdx': hostIdx,
      'hasPassword': password != null,
      'players': [
        for (int i = 0; i < 2; i++)
          i < _players.length
              ? {'name': _players[i].name, 'disconnected': false, 'ready': _players[i].ready}
              : null
      ],
      'spectators': [for (final s in _spectators) {'name': s.name, 'disconnected': false}],
    };
  }

  Future<void> stop() async {
    _beaconTimer?.cancel();
    _udp?.close();
    for (final p in [..._players, ..._spectators]) {
      try {
        p.ws.close();
      } catch (_) {}
    }
    await _http?.close(force: true);
  }
}

/// 局域网在线信标（客户端）：进入局域网大厅就周期广播「我在这」，
/// 这样同一 WiFi 下的人都看得见对方（不建房也有存在感）
class LanBeacon {
  RawDatagramSocket? _sock;
  Timer? _timer;

  /// 唯一标识：自己过滤自己的回环信标（否则在线列表出现两个自己）
  final String id =
      'b${DateTime.now().millisecondsSinceEpoch}${_rnd.nextInt(999999)}';
  static final _rnd = _BeaconRnd();
  String _name = '';

  Future<void> start(String name) async {
    _name = name;
    stop();
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sock!.broadcastEnabled = true;
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _ping());
      _ping(); // 立即发一包
    } catch (_) {}
  }

  void _ping() {
    if (_sock == null) return;
    final data = utf8.encode(jsonEncode({
      'id': id,
      'name': _name,
      'lan': true,
      'status': 'lobby', // 无 port：在线的人（非房间）
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
    try {
      _sock!.send(data, InternetAddress(kLanMulticast), kLanUdpPort);
      _sock!.send(data, InternetAddress('255.255.255.255'), kLanUdpPort);
    } catch (_) {}
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _sock?.close();
    _sock = null;
  }
}

/// 局域网房间发现（客户端）：监听 UDP 组播/广播
class LanDiscoverer {
  RawDatagramSocket? _sock;
  final List<Map<String, dynamic>> rooms = [];
  void Function()? onChanged;

  Future<void> start() async {
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kLanUdpPort, reuseAddress: true);
      try {
        _sock!.joinMulticast(InternetAddress(kLanMulticast));
      } catch (_) {}
      _sock!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = _sock!.receive();
        if (dg == null) return;
        try {
          final j = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (j['lan'] != true) return;
          final host = (j['selfIp'] as String?) ?? dg.address.address;
          final key = '$host:${j['port']}';
          final exists = rooms.indexWhere((r) => r['key'] == key);
          final entry = {...j, 'key': key, 'host': host};
          if (exists >= 0) {
            rooms[exists] = entry;
          } else {
            rooms.add(entry);
          }
          // 清理过期条目（信标/房间 2s 一包，7s 没收到视为离线）
          final now = DateTime.now().millisecondsSinceEpoch;
          rooms.removeWhere((r) {
            final ts = r['ts'];
            if (ts is! int) return false;
            return now - ts > 7000;
          });
          onChanged?.call();
        } catch (_) {}
      });
      // 同网段单播扫描：组播/广播被路由器过滤时（AP 隔离/部分路由器），
      // 直接向网段内每个 IP 发探测包，对方同样在监听 45678 就能收到 → 双向可见
      _scanTimer = Timer.periodic(const Duration(seconds: 5), (_) => _scanOnce());
      _scanOnce();
    } catch (_) {}
  }

  Timer? _scanTimer;

  Future<void> _scanOnce() async {
    final sock = _sock;
    if (sock == null) return;
    // 探测包：带自己信息（对方收到即显示我方在线）
    final probe = utf8.encode(jsonEncode({
      'name': _scanName ?? '玩家',
      'lan': true,
      'status': 'lobby',
      'probe': true,
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final seen = <String>{};
      for (final i in ifs) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          if (!seen.add(ip)) continue;
          final parts = ip.split('.');
          if (parts.length != 4) continue;
          // 本网段 /24 内每个 IP 发一包（255 个 UDP 包，轻量）
          for (int k = 1; k <= 254; k++) {
            try {
              sock.send(probe, InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.$k'), kLanUdpPort);
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  String? _scanName;

  /// 设置探测包里的名字（进大厅时传玩家名，对方在线列表显示）
  set scanName(String? name) => _scanName = name;

  void stop() {
    _scanTimer?.cancel();
    _sock?.close();
  }
}
