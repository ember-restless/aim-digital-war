// AIM 网络层（socket.io 封装）
import 'package:socket_io_client/socket_io_client.dart' as io;

class AIMSocket {
  io.Socket? _socket;
  final String url;
  void Function(String event, dynamic data)? onEvent;
  void Function(String msg)? onServerError;

  AIMSocket(this.url);

  bool get connected => _socket?.connected ?? false;

  void connect() {
    _socket = io.io(url, io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .build());
    _socket!.onConnect((_) => onEvent?.call('connect', null));
    _socket!.onDisconnect((_) => onEvent?.call('disconnect', null));
    _socket!.on('hello_ok', (d) => onEvent?.call('hello_ok', d));
    _socket!.on('player_list', (d) => onEvent?.call('player_list', d));
    _socket!.on('kicked', (d) => onEvent?.call('kicked', d));
    _socket!.on('you_are', (d) => onEvent?.call('you_are', d));
    _socket!.on('room_update', (d) => onEvent?.call('room_update', d));
    _socket!.on('room_list', (d) => onEvent?.call('room_list', d));
    _socket!.on('game_state', (d) => onEvent?.call('game_state', d));
    _socket!.on('game_over', (d) => onEvent?.call('game_over', d));
    _socket!.on('repeat_warn', (d) => onEvent?.call('repeat_warn', d));
    _socket!.on('chat', (d) => onEvent?.call('chat', d));
    _socket!.on('ingame_chat', (d) => onEvent?.call('ingame_chat', d));
    _socket!.on('error', (d) => onServerError?.call((d as Map?)?['msg']?.toString() ?? '错误'));
    _socket!.connect();
  }

  void emit(String event, [dynamic data]) {
    if (data == null) {
      _socket?.emit(event);
    } else {
      _socket?.emit(event, data);
    }
  }

  void dispose() {
    _socket?.dispose();
  }
}
