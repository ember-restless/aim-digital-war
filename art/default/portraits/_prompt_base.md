# AIM 立绘 Prompt 库（Legio Numeri 军团）

## 全局基底（每个 prompt 前缀都加这段）
```
Chunky 8-bit/16-bit retro pixel art portrait illustration. Vertical 3:4 head-and-shoulders bust. Large visible pixel blocks at LOW resolution (each pixel clearly visible, like a 64x96 source sprite scaled up 4x to 256x384). Strict limited palette restricted to warm brick orange (#FF4E35) for accents and highlights, cream parchment white (#FFF5DC) for mid-tones and skin, warm brown-grey (#5A554C) for shadows and outlines, with a single warm tanned-skin tone (#D4A574). Maximum 2 shading tones per material (1 mid + 1 shadow, no extra highlight tones). Hard pixel edges with large clear pixel clusters - NOT fine-grained detail. Pixel art aesthetic must be visibly chunky/retro, NOT a high-resolution painting with pixel filter. Transparent background, isolated character on alpha. NO moe sparkles, NO chibi, NO anime eyes too large.
```

## 角色设定

### 1. Primus — 一号·新兵
- 少年，约18岁，栗色短发微卷，发尾翘起
- 浅色眼睛（橄榄绿），脸上还有一点婴儿肥，眼神坚定但稚气
- 装备：最朴素的皮革胸甲，铜扣，左肩带皮护肩
- 体格偏瘦
- 身份标签：军中第 1 序新兵

### 2. Secundus — 二号·斥候
- 少女，约19岁，银灰色短发到耳下，机灵相
- 翠绿色眼睛，左眉尾有颗小痣
- 装备：轻皮甲+暗色短斗篷，胸口别一枚铜质羽毛徽章
- 体格矫健偏瘦
- 身份标签：军中第 2 序斥候

### 3. Tertius — 三号·弓手
- 沉默青年，约24岁，黑色长发扎高马尾，几缕碎发落脸侧
- 深棕色眼睛，目光锐利内敛
- 装备：暗棕色皮甲，左臂有弓手护腕，斜背一个空箭袋
- 右手搭在胸前（扶弓姿势的暗示）
- 身份标签：军中第 3 序弓手

### 4. Quartus — 四号·炮兵
- 沉稳壮年，约32岁，深褐色短发剃得很短，下巴有修剪整齐的短胡
- 灰色眼睛
- 装备：厚皮甲外套一件深色粗呢短披风（披在左肩，绕一圈粗麻绳固定），左胸缝一枚方形的黄铜片
- 脖子裹一条厚围巾（米白底有暗红条纹）
- 体格厚重
- 身份标签：军中第 4 序炮兵

### 5. Quintus — 五号·重骑兵
- 豪爽壮年，约30岁，深色短发梳成偏分，颧骨高，下颌宽
- 深棕色眼睛，浓眉，嘴角常带点硬朗的笑意
- 装备：半身板甲（暗钢色，带战锤痕迹的凹痕），胸前刻着一个粗犷的「5」字纹章
- 肩膀宽阔，脖子粗壮
- 身份标签：军中第 5 序重骑

### 7. Septimus — 七号·盾卫
- 老人，约62岁，花白短发与短胡茬，右眼一道旧伤疤横过
- 浅蓝色眼睛（左眼），右眼闭合留疤
- 装备：老旧圆形木盾斜挎背后（盾面有刀痕坑），厚皮胸甲磨得发白，胸前刻着「7」字纹章
- 脖子系一条褪色红布巾（军团色）
- 皱纹深，神态温和
- 身份标签：军中第 7 序盾卫

## 表情差分

### neutral — 普通（基准）
```
neutral composed expression, eyes forward, mouth closed in calm line, no strong emotion
```

### combat — 战斗
```
determined battle expression, brows furrowed, mouth set in a hard line, eyes intense and focused forward, slightly aggressive stance
```

### smile — 微笑
```
gentle warm smile, slight upward curve at mouth corners, eyes softened with a hint of warmth
```

### hurt — 受伤
```
grimacing in pain, one eye slightly narrowed, mouth open showing clenched teeth, a fresh shallow cut on cheek with a thin line of red, exhaustion visible
```

## 拼接示例（给 image_generate 用）

完整 prompt 模板 = `[全局基底] + [角色描述] + [表情差分], upper body portrait bust, looking slightly toward viewer, no text, no logo, no border, no watermark, clean cutout for transparent PNG background`
