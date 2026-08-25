// AIM 服务端配置
'use strict';
module.exports = {
  APP_VERSION: '1.1.0',
  APP_VERSION_CODE: 4,
  // ── 服务器自身信息（目录注册用）──
  SERVER_NAME: 'AIM 官方服',
  SERVER_MAX_PLAYERS: 20,      // 服务器同时在线人数上限（小破服务器保护）
  SERVER_PUBLIC: true,         // 是否公开（注册进目录，别人可自动选）
  SERVER_DESC: '官方服务器',
  // ── 目录服务（官方服务器自身也是目录）──
  DIRECTORY_URL: 'http://127.0.0.1:5000/api/server/register', // 本机注册地址（官方服自己）
};
