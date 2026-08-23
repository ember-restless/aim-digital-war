// web 实现：无文件系统，只有内置包（此文件只在 web 编译）
import 'package:flutter/painting.dart';

ImageProvider fileImage(String path) =>
    const AssetImage('assets/art/default/units/0.png');

Future<List<(String, String, String)>> scanCustomPacks() async => [];

Future<String> customPackPath(String packId) async => '/art/$packId';
