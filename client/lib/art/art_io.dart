// io 平台实现：文件系统资源包（web 不编译此文件）
import 'dart:io';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

ImageProvider fileImage(String path) => FileImage(File(path));

Future<List<(String, String, String)>> scanCustomPacks() async {
  final list = <(String, String, String)>[];
  try {
    final dir = await getApplicationDocumentsDirectory();
    final artDir = Directory('${dir.path}/art');
    if (await artDir.exists()) {
      await for (final e in artDir.list()) {
        if (e is Directory) {
          final pid = e.path.split('/').last;
          final pj = File('${e.path}/pack.json');
          var name = pid, author = '?';
          if (await pj.exists()) {
            try {
              final j = await pj.readAsString();
              final m = RegExp(r'"name"\s*:\s*"([^"]+)"').firstMatch(j);
              final a = RegExp(r'"author"\s*:\s*"([^"]+)"').firstMatch(j);
              if (m != null) name = m.group(1)!;
              if (a != null) author = a.group(1)!;
            } catch (_) {}
          }
          list.add((pid, name, author));
        }
      }
    }
  } catch (_) {}
  return list;
}

Future<String> customPackPath(String packId) async {
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/art/$packId';
}
