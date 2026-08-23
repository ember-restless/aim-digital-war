# AIM 网络客户端（python-socketio）
import json
import socketio
import urllib.request

SERVER = 'http://192.140.166.178:5000'  # 单端口：游戏+下载页一体（3000 是 math）
APP_VERSION = '0.2.0'


def check_update(timeout=4):
    """检查服务端最新版本，返回 {version, downloadPage, ...} 或 None"""
    try:
        with urllib.request.urlopen(SERVER + '/api/version', timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


class AIMClient:
    def __init__(self, on_event):
        self.on_event = on_event  # cb(event_name, data)
        self.sio = socketio.Client(reconnection=True, reconnection_attempts=0)
        self._bind()
        self.connected = False
        self.playerIdx = None
        self.roomId = None

    def _bind(self):
        s = self.sio
        s.on('connect', lambda: self._emit('connect', None))
        s.on('disconnect', lambda: self._emit('disconnect', None))
        s.on('you_are', lambda d: self._emit('you_are', d))
        s.on('room_update', lambda d: self._emit('room_update', d))
        s.on('room_list', lambda d: self._emit('room_list', d))
        s.on('game_state', lambda d: self._emit('game_state', d))
        s.on('game_over', lambda d: self._emit('game_over', d))
        s.on('chat', lambda d: self._emit('chat', d))
        s.on('error', lambda d: self._emit('server_error', d))

    def _emit(self, name, data):
        self.on_event(name, data)

    def connect(self, url=SERVER):
        try:
            self.sio.connect(url, wait_timeout=5)
            self.connected = True
            return True
        except Exception as e:
            return str(e)

    def disconnect(self):
        try:
            self.sio.disconnect()
        except Exception:
            pass

    def create_room(self, name, mode='online'):
        self.sio.emit('create_room', {'name': name, 'mode': mode})

    def join_room(self, room_id, name):
        self.sio.emit('join_room', {'roomId': room_id, 'name': name})

    def list_rooms(self):
        self.sio.emit('list_rooms')

    def start_game(self, limit=16):
        self.sio.emit('start_game', {'limit': limit})

    def action(self, action):
        self.sio.emit('action', action)

    def chat(self, msg):
        self.sio.emit('chat', {'msg': msg})
