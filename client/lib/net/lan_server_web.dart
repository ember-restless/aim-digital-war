// web：浏览器不允许开 socket，局域网不可用（成员保持与 io 版同签名，调用即抛错）
const int kLanWsPort = 45679; // WebSocket 房间服务端口
const int kLanUdpPort = 45678; // UDP 发现端口
const String kLanMulticast = '224.0.2.60'; // Minecraft 同款组播地址

class LanPlayer {}

class LanServer {
  final String roomTitle;
  final int limit0;
  final bool allowOwnRollerAttack;
  final String? password;
  final int port;
  final bool beacon;
  LanServer({
    required this.roomTitle,
    this.password,
    required this.limit0,
    this.port = kLanWsPort,
    this.beacon = true,
    required this.allowOwnRollerAttack,
  }) {
    throw UnsupportedError('浏览器不支持局域网直连');
  }
  String get id => 'LAN';
  String? get localIp => null;
  void Function(String msg)? onSysLog;
  String status = 'waiting';
  int hostIdx = 0;
  Future<bool> start() async => false;
  void stop() {}
}

class LanBeacon {
  final String id = 'bweb';
  Future<void> start(String name) async {}
  void stop() {}
}

class LanDiscoverer {
  final List<Map<String, dynamic>> rooms = [];
  void Function()? onChanged;
  String? _scanName;
  set scanName(String? name) => _scanName = name;
  Future<void> start() async {}
  void stop() {}
}
