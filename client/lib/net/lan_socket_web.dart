import 'socket.dart';
// web：浏览器不允许开 socket，局域网不可用
class LanSocket extends AIMSocket {
  LanSocket(String url) : super(url) {
    throw UnsupportedError('浏览器不支持局域网直连');
  }
}
