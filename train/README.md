# AIM 训练场（AI 行为克隆）

## 架构
- 训练场页面：http://192.140.166.178:5000/train/ （独立 Flutter web 构建，玩家 vs AI）
- 对局数据：服务器 `POST /api/train/upload` → `train_data/games.jsonl`（每行一局）
- 统计：`GET /api/train/stats` → {games, steps, modelVersion, modelUpdatedAt}
- 权重：`server/public/downloads/train_weights.json`（训练后部署，客户端/训练场拉取即生效）

## 训练
```bash
python3 train/train_bc.py --epochs 80 --deploy
```
- 读 train_data/games.jsonl，行为克隆（MLP 53→64→64→49），输出权重 JSON
- --deploy 部署到 downloads（version 自增，无需重启服务器）

## 网络约定（与 client/lib/train/train_ai.dart 一致）
- 输入 53 维：8格×6特征（v/9, o0, o1, bridge, onBridge, auto）+ 5 全局（turn, phaseA, phaseP, points/10, produceLeft/8）
- 输出 49 槽位：8格×6操作（move1, move2, attack, devour, split, produce）+ endTurn
- 槽位：i*6+(0|1) move, +2 attack, +3 devour, +4 split, +5 produce, 48 endTurn
