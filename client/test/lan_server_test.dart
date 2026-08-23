// 局域网主机协议集成测试：LanServer 建房/加入/准备/开始/对局/密码
// 跑法：cd /root/aim/client && timeout 120 /opt/flutter/bin/flutter test --no-version-check test/lan_server_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aim/net/lan_server.dart';

class TClient {
  final WebSocket ws;
  final List<Map<String, dynamic>> events = [];
  TClient(this.ws);
  Future<Map<String, dynamic>> next(String event, {Duration timeout = const Duration(seconds: 5)}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      for (int i = 0; i < events.length; i++) {
        if (events[i]['e'] == event) return events.removeAt(i);
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('等待事件 $event 超时，已有: ${events.map((e) => e['e']).toList()}');
  }
}

Future<TClient> connect(int port) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port');
  final c = TClient(ws);
  ws.listen((raw) {
    c.events.add(jsonDecode(raw as String) as Map<String, dynamic>);
  });
  return c;
}

// 等一条玩家聊天（跳过系统消息）
Future<Map<String, dynamic>> nextPlayerChat(TClient c, {Duration timeout = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    for (int i = 0; i < c.events.length; i++) {
      final e = c.events[i];
      if (e['e'] == 'chat' && (e['d'] as Map)['sys'] != true) return c.events.removeAt(i);
    }
    await Future.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('等待玩家聊天超时，已有: ${c.events.map((e) => e['e']).toList()}');
}

void main() {
  test('局域网全流程：建房→加入→密码→准备→开局→吞噬', () async {
    final server = LanServer(roomTitle: '测试房', password: '1234', port: 45681, beacon: false);
    expect(await server.start(), true);

    // 房主连入
    final host = await connect(45681);
    host.ws.add(jsonEncode({'e': 'hello', 'd': {'name': '房主'}}));
    await host.next('hello_ok');
    host.ws.add(jsonEncode({'e': 'create_room', 'd': {'name': '房主', 'title': '测试房', 'password': '1234'}}));
    final hyou = await host.next('you_are');
    expect(hyou['d']['playerIdx'], 0);
    final hroom = await host.next('room_update');
    expect(hroom['d']['title'], '测试房');
    expect(hroom['d']['hasPassword'], true);
    expect(hroom['d']['hostIdx'], 0);
    // 在线列表：创建房间后至少房主自己
    final hpl = await host.next('player_list');
    expect(hpl['d'].length, 1);
    expect(hpl['d'][0]['name'], '房主');

    // 密码错误
    final bad = await connect(45681);
    bad.ws.add(jsonEncode({'e': 'hello', 'd': {'name': '坏蛋'}}));
    await bad.next('hello_ok');
    bad.ws.add(jsonEncode({'e': 'join_room', 'd': {'name': '坏蛋', 'password': 'wrong'}}));
    final berr = await bad.next('error');
    expect(berr['d']['msg'], '密码错误');
    bad.ws.close();

    // 正确密码加入
    final guest = await connect(45681);
    guest.ws.add(jsonEncode({'e': 'hello', 'd': {'name': '客人'}}));
    await guest.next('hello_ok');
    guest.ws.add(jsonEncode({'e': 'join_room', 'd': {'name': '客人', 'password': '1234'}}));
    final gyou = await guest.next('you_are');
    expect(gyou['d']['playerIdx'], 1);
    // 房主也收到 room_update（广播）
    final hroom2 = await host.next('room_update');
    expect(hroom2['d']['players'][1]['name'], '客人');
    // 在线列表：2 人
    final hpl2 = await host.next('player_list');
    expect(hpl2['d'].length, 2);

    // 未准备不能开始
    host.ws.add(jsonEncode({'e': 'start_game', 'd': {}}));
    final herr = await host.next('error');
    expect(herr['d']['msg'], '有玩家未准备');

    // 客人准备 → 房主开始
    guest.ws.add(jsonEncode({'e': 'ready', 'd': {'ready': true}}));
    await host.next('room_update'); // 客人准备状态广播
    host.ws.add(jsonEncode({'e': 'start_game', 'd': {}}));
    final hgs = await host.next('game_state');
    expect(hgs['d']['yourIdx'], 0);
    expect(hgs['d']['cells'], isA<List>());
    final ggs = await guest.next('game_state');
    expect(ggs['d']['yourIdx'], 1);

    // 房主造兵（本地引擎驱动）
    host.ws.add(jsonEncode({'e': 'action', 'd': {'action': {'type': 'produce', 'i': 0, 'j': 1}}}));
    final hgs2 = await host.next('game_state');
    final cells = (hgs2['d']['cells'] as List);
    expect((cells[1] as Map)['v'], 1, reason: '本地引擎造兵应生效');

    // 聊天广播
    host.ws.add(jsonEncode({'e': 'chat', 'd': {'msg': '大家好'}}));
    final gchat = await nextPlayerChat(guest);
    expect(gchat['d']['msg'], '大家好');
    expect(gchat['d']['name'], '房主');

    await server.stop();
  });

  test('等待中满员拒绝 + 对局中观战', () async {
    final server = LanServer(roomTitle: '满员房', port: 45682, beacon: false);
    expect(await server.start(), true);

    final a = await connect(45682);
    a.ws.add(jsonEncode({'e': 'hello', 'd': {'name': 'A'}}));
    await a.next('hello_ok');
    a.ws.add(jsonEncode({'e': 'create_room', 'd': {'name': 'A'}}));
    await a.next('you_are');

    final b = await connect(45682);
    b.ws.add(jsonEncode({'e': 'hello', 'd': {'name': 'B'}}));
    await b.next('hello_ok');
    b.ws.add(jsonEncode({'e': 'join_room', 'd': {'name': 'B'}}));
    await b.next('you_are');

    // 第三人：waiting 满员拒绝
    final c = await connect(45682);
    c.ws.add(jsonEncode({'e': 'hello', 'd': {'name': 'C'}}));
    await c.next('hello_ok');
    c.ws.add(jsonEncode({'e': 'join_room', 'd': {'name': 'C'}}));
    final cerr = await c.next('error');
    expect(cerr['d']['msg'], '房间已满');
    c.ws.close();

    // 开局后第三人可观战
    b.ws.add(jsonEncode({'e': 'ready', 'd': {'ready': true}}));
    a.ws.add(jsonEncode({'e': 'start_game', 'd': {}}));
    await a.next('game_state');
    await b.next('game_state');

    final d = await connect(45682);
    d.ws.add(jsonEncode({'e': 'hello', 'd': {'name': 'D'}}));
    await d.next('hello_ok');
    d.ws.add(jsonEncode({'e': 'join_room', 'd': {'name': 'D'}}));
    final dyou = await d.next('you_are');
    expect(dyou['d']['spectator'], true, reason: '对局中第三人观战');
    final dgs = await d.next('game_state');
    expect(dgs['d']['spectator'], true);

    // 观战者不能操作
    d.ws.add(jsonEncode({'e': 'action', 'd': {'action': {'type': 'endTurn'}}}));
    // 不应收到 game_state（静默忽略）；等一会确认无报错
    await Future.delayed(const Duration(milliseconds: 300));

    await server.stop();
  });
}
