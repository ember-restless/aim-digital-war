// AI 训练场独立入口（flutter build web -t lib/train/train_main.dart --base-href /train/）
import 'package:flutter/material.dart';

import '../screens/train_screen.dart';

void main() {
  runApp(const MaterialApp(
    title: 'AIM 训练场',
    debugShowCheckedModeBanner: false,
    home: TrainScreen(),
  ));
}
