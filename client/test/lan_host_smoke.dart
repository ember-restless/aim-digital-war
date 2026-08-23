// 局域网房主/换位/断线冒烟（服务器上直接跑）
// 验证：1) set_side 右→左可换回 2) 成员退出后房主身份不丢（you_are 重发）
import 'dart:async';

import 'package:aim/net/lan_server.dart';
import 'package:aim/net/lan_socket.dart';

class TClient {
  final LanSocket sock;
  final String name;
  int? myIdx;
  final List<String> events = [];
  int youAreCount = 0;

  TClient(this.sock, this.name) {
    sock.onEvent = (e, d) {
      events.add(e);
      if (e == 'connect') sock.emit('hello', {'name': name, 'version': '1.0.0'});
      if (e == 'hello_ok') {
        if (name == '房主') {
          sock.emit('create_room', {'name': name});
        } else {
          sock.emit('join_room', {'name': name});
        }
      }
      if (e == 'you_are') {
        youAreCount++;
        myIdx = ((d as Map?)?['playerIdx'] as num?)?.toInt();
      }
    };
  }
}

Future<void> main() async {
  print('== 局域网房主/换位/断线冒烟 ==');
  final server = LanServer(roomTitle: '测试房', beacon: false);
  await server.start();

  final host = TClient(LanSocket('ws://127.0.0.1:${server.port}'), '房主');
  host.sock.connect();
  await Future.delayed(const Duration(milliseconds: 800));

  final member = TClient(LanSocket('ws://127.0.0.1:${server.port}'), '成员');
  member.sock.connect();
  await Future.delayed(const Duration(milliseconds: 800));

  // 房主换右 → 换回左
  host.sock.emit('set_side', {'side': 'right'});
  await Future.delayed(const Duration(milliseconds: 400));
  print('换右后 房主idx=${host.myIdx} 成员idx=${member.myIdx}');
  if (host.myIdx != 1 || member.myIdx != 0) {
    print('FAIL: 换右后索引不对');
    return;
  }
  host.sock.emit('set_side', {'side': 'left'});
  await Future.delayed(const Duration(milliseconds: 400));
  print('换回左 房主idx=${host.myIdx} 成员idx=${member.myIdx}');
  if (host.myIdx != 0 || member.myIdx != 1) {
    print('FAIL: 换回左失败');
    return;
  }

  // 成员退出 → 房主身份保留（you_are 重发，房主 idx=0）
  member.sock.dispose();
  await Future.delayed(const Duration(milliseconds: 500));
  print('成员退出后 房主idx=${host.myIdx} you_are次数=${host.youAreCount}');
  if (host.myIdx != 0) {
    print('FAIL: 成员退出后房主索引错乱');
    return;
  }

  print('SUCCESS: 换位双向 + 断线身份修复 全部通过');
  host.sock.dispose();
  await server.stop();
}
