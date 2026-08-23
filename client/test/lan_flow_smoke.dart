// 局域网链路冒烟（服务器上直接跑）：LanServer + LanSocket 全流程
// 验证：connect → hello → hello_ok → create_room → you_are（建房进房链路）
import 'dart:async';

import 'package:aim/net/lan_server.dart';
import 'package:aim/net/lan_socket.dart';

Future<void> main() async {
  print('== 局域网链路冒烟 ==');
  final server = LanServer(roomTitle: '测试房', beacon: false);
  final ok = await server.start();
  print('LanServer.start: $ok  port=${server.port}  localIp=${server.localIp}');
  if (!ok) {
    print('FAIL: 服务器起不来');
    return;
  }

  final sock = LanSocket('ws://127.0.0.1:${server.port}');
  final events = <String>[];
  sock.onEvent = (e, d) {
    events.add(e);
    print('  <- 事件: $e  data=$d');
    if (e == 'connect') {
      sock.emit('hello', {'name': '玩家A', 'version': '1.0.0'});
    }
    if (e == 'hello_ok') {
      sock.emit('create_room', {'name': '玩家A'});
    }
    if (e == 'you_are') {
      print('SUCCESS: 收到 you_are → 进房间页链路通');
      sock.dispose();
      server.stop();
    }
  };
  sock.onServerError = (m) => print('  !! 错误: $m');
  sock.connect();

  // 超时 8s
  await Future.delayed(const Duration(seconds: 8));
  if (!events.contains('you_are')) {
    print('FAIL: 8s 内没收到 you_are。事件序列: $events');
    server.stop();
  }
  print('done');
}
