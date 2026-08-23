// AIM 资源包管理：内置 assets + 应用目录自定义包，游戏内可选
import 'package:flutter/material.dart';
import 'art_io.dart' if (dart.library.html) 'art_web.dart' as artio;

class PackInfo {
  final String id;      // 包标识（目录名）
  final String name;    // 显示名
  final String author;
  final bool builtin;   // 是否内置
  PackInfo(this.id, this.name, this.author, this.builtin);
}

class ArtManager {
  static const builtinId = 'default';
  static final Map<String, ImageProvider> _cache = {};

  // 列出所有资源包：内置 + 应用文档目录 art/ 下的自定义包
  static Future<List<PackInfo>> listPacks() async {
    final list = <PackInfo>[
      PackInfo(builtinId, '经典像素', '离离', true),
    ];
    for (final (pid, name, author) in await artio.scanCustomPacks()) {
      list.add(PackInfo(pid, name, author, false));
    }
    return list;
  }

  // 取单位/地形图标（默认数字包不分敌我，敌我靠边框色区分）
  static ImageProvider unit(String packId, int v, int owner, {bool onBridge = false}) {
    final file = onBridge ? 'dash' : (v == 0 ? '0' : '$v');
    final key = '$packId|$file';
    return _load(packId, 'units', key, file);
  }

  static ImageProvider bridge(String packId) => _load(packId, 'units', '$packId|dash', 'dash');

  static ImageProvider _load(String packId, String sub, String cacheKey, String file) {
    return _cache.putIfAbsent(cacheKey, () {
      if (packId == builtinId) {
        return AssetImage('assets/art/$builtinId/$sub/$file.png');
      }
      return artio.fileImage('${_customDir(packId)}/$sub/$file.png');
    });
  }

  static String _customDir(String packId) {
    // 懒初始化：返回占位，实际加载时再拼路径
    return '/documents/art/$packId';
  }

  // 自定义包需要真实目录，这里提供异步解析
  static Future<String> customPackPath(String packId) => artio.customPackPath(packId);

  // 自定义包的 ImageProvider（异步路径）
  static Future<ImageProvider> customUnit(String packId, String file) async {
    if (packId == builtinId) return AssetImage('assets/art/$builtinId/units/$file.png');
    final p = await customPackPath(packId);
    return artio.fileImage('$p/units/$file.png');
  }
}
