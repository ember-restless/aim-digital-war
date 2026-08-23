// 局域网客户端连接：伪装成 AIMSocket，实际走 WebSocket + JSON 事件协议
// 事件名与联机服务端一致（room_list/you_are/room_update/game_state/...），界面完全复用
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'socket.dart';

class LanSocket extends AIMSocket {
  WebSocket? _ws;
  bool _closed = false;

  LanSocket(String url) : super(url);

  @override
  bool get connected => _ws != null && !_closed;

  @override
  void connect() {
    WebSocket.connect(widgetUrl()).timeout(const Duration(seconds: 5), onTimeout: () {
      throw TimeoutException('连接超时');
    }).then((ws) {
      if (_closed) {
        ws.close();
        return;
      }
      _ws = ws;
      onEvent?.call('connect', null);
      ws.listen(
        (raw) {
          try {
            final m = jsonDecode(raw as String) as Map<String, dynamic>;
            onEvent?.call(m['e'] as String? ?? '', m['d']);
          } catch (_) {}
        },
        onDone: () {
          _closed = true;
          onEvent?.call('disconnect', null);
        },
        onError: (_) {
          _closed = true;
          onEvent?.call('disconnect', null);
        },
        cancelOnError: true,
      );
    }).catchError((e) {
      _closed = true;
      // 连接失败要可见：弹窗提示（之前完全静默，牢大：点了没反应）
      onServerError?.call('无法连接局域网主机（${widgetUrl()}）\n请确认对方已建房、在同一 WiFi 且没有开启 AP 隔离');
      onEvent?.call('disconnect', null);
    });
  }

  String widgetUrl() {
    // 传入的是 ws://host:port
    return url;
  }

  @override
  void emit(String event, [dynamic data]) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode({'e': event, 'd': data ?? {}}));
    } catch (_) {}
  }

  @override
  void dispose() {
    _closed = true;
    try {
      _ws?.close();
    } catch (_) {}
    _ws = null;
  }
}
