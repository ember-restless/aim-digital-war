// AIM 服务器体系：目录拉取 + 延迟测量 + 自动选服
// 客户端内置官方目录地址；公开服务器启动时向目录注册，客户端拉列表测延迟
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';

class AimServer {
  final String id;
  final String name;
  final String host;
  final int port;
  final int players;
  final int maxPlayers;
  final String version;
  final String desc;
  final bool official;
  int? latencyMs; // 测得的延迟（null=未测/失败）

  AimServer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.players,
    required this.maxPlayers,
    required this.version,
    this.desc = '',
    this.official = false,
    this.latencyMs,
  });

  String get url => 'http://$host:$port';
  bool get full => players >= maxPlayers;

  factory AimServer.fromJson(Map<String, dynamic> j) {
    return AimServer(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? 'AIM 服务器',
      host: (j['host'] as String?) ?? '',
      port: (j['port'] as num?)?.toInt() ?? 5000,
      players: (j['players'] as num?)?.toInt() ?? 0,
      maxPlayers: (j['maxPlayers'] as num?)?.toInt() ?? 20,
      version: (j['version'] as String?) ?? '?',
      desc: (j['desc'] as String?) ?? '',
      official: (j['official'] == true),
    );
  }
}

/// 从目录服务器拉公开服务器列表（官方服务器永远在列表里）
Future<List<AimServer>> fetchServers({String? directoryUrl}) async {
  final url = directoryUrl ?? AppConfig.serverUrl;
  try {
    final res = await http.get(Uri.parse('$url/api/servers')).timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) return [];
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final list = (j['servers'] as List?) ?? [];
    return list.map((e) => AimServer.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
}

/// 测量服务器延迟：GET /api/version 往返计时（多次取最低），失败返回 null
Future<int?> measureLatency(AimServer s, {int tries = 3}) async {
  int? best;
  for (int i = 0; i < tries; i++) {
    final sw = Stopwatch()..start();
    try {
      await http.get(Uri.parse('${s.url}/api/version')).timeout(const Duration(seconds: 2));
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      if (best == null || ms < best) best = ms;
    } catch (_) {
      // 失败重试
    }
    if (best != null && best < 20) break; // 本地/极快就不测了
  }
  return best;
}

/// 自动选服：排除满员 → 延迟升序 → 延迟差 50ms 内选人数最少
/// 返回 (选中的服务器, 全部服务器列表带延迟)
Future<(AimServer?, List<AimServer>)> autoSelectServer({String? directoryUrl}) async {
  final servers = await fetchServers(directoryUrl: directoryUrl);
  if (servers.isEmpty) return (null, <AimServer>[]);
  // 并行测延迟
  await Future.wait(servers.map((s) async {
    s.latencyMs = await measureLatency(s);
  }));
  final alive = servers.where((s) => s.latencyMs != null).toList();
  if (alive.isEmpty) return (null, servers);
  final candidates = alive.where((s) => !s.full).toList();
  final pool = candidates.isEmpty ? alive : candidates; // 全满时退而求其次
  pool.sort((a, b) {
    final la = a.latencyMs!;
    final lb = b.latencyMs!;
    if ((la - lb).abs() <= 50) return a.players.compareTo(b.players);
    return la.compareTo(lb);
  });
  return (pool.first, servers);
}
