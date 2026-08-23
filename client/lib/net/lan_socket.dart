// 局域网客户端连接 - 条件导出（io 用 WebSocket，web 不支持局域网）
export 'lan_socket_io.dart' if (dart.library.html) 'lan_socket_web.dart';
