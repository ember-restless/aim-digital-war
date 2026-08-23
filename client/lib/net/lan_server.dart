// 局域网主机 - 条件导出（io 用 WebSocket/UDP，web 不支持局域网）
export 'lan_server_io.dart' if (dart.library.html) 'lan_server_web.dart';
