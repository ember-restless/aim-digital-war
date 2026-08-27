#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
权重扩展：64 单元 → 128 单元（net2net 精确复制）
新增 64 单元 = 旧 64 单元的精确副本（输出权重减半），前向 100% 一致——
行为不变（起点保住 v104 的 45 分），且副本单元初始即有梯度，训练时能继续学习。
用法：python3 expand_weights.py [src] [dst]
"""
import json
import sys

import numpy as np

SRC = sys.argv[1] if len(sys.argv) > 1 else '/root/aim/server/public/downloads/train_weights.json'
DST = sys.argv[2] if len(sys.argv) > 2 else '/root/aim/train_data/weights_128_start.json'
IN_DIM, OUT = 53, 97


def main():
    w = json.load(open(SRC, encoding='utf-8'))
    old_h = int(w.get('hidden', 64))
    new_h = old_h * 2

    w1 = np.array(w['w1'], dtype=np.float64).reshape(old_h, IN_DIM)   # 加载端语义 (hidden, in)
    b1 = np.array(w['b1'], dtype=np.float64)
    w2 = np.array(w['w2'], dtype=np.float64).reshape(old_h, old_h)    # (hidden, hidden)
    b2 = np.array(w['b2'], dtype=np.float64)
    wo = np.array(w['wo'], dtype=np.float64).reshape(OUT, old_h)      # 加载端语义 (out, hidden)！
    bo = np.array(w['bo'], dtype=np.float64)

    # net2net：复制每个单元，输出侧权重减半 → 前向逐位一致
    # 注意：权重文件 flatten 顺序 = 训练端 xavier(IN_DIM,HIDDEN) 的行主序，
    # 加载端 reshape(HIDDEN,IN_DIM) 不转置，所以这里必须用「加载端语义」构造。
    W1 = np.vstack([w1, w1])                     # (2h, in) 前 64 行=旧，后 64 行=副本
    B1 = np.concatenate([b1, b1])                # (2h,)
    W2 = np.zeros((new_h, new_h))
    W2[:old_h, :old_h] = w2 / 2.0                # 旧→旧
    W2[old_h:, :old_h] = w2 / 2.0                # 副本→旧
    W2[:old_h, old_h:] = w2 / 2.0                # 旧→副本
    W2[old_h:, old_h:] = w2 / 2.0                # 副本→副本
    B2 = np.concatenate([b2, b2])
    WO = np.hstack([wo / 2.0, wo / 2.0])         # (out, 2h) 列=hidden 单元，复制列
    # 注意：加载端 wo reshape(out, hidden) 列对应 hidden 单元，复制单元 = 复制列
    data = {
        'version': int(w.get('version', 0)),
        'updatedAt': w.get('updatedAt', ''),
        'in': IN_DIM, 'hidden': new_h, 'out': OUT,
        'w1': [float(x) for x in W1.flatten()],
        'b1': [float(x) for x in B1],
        'w2': [float(x) for x in W2.flatten()],
        'b2': [float(x) for x in B2],
        'wo': [float(x) for x in WO.flatten()],
        'bo': [float(x) for x in bo],
        'base': int(w.get('version', 0)),
    }
    json.dump(data, open(DST, 'w', encoding='utf-8'), ensure_ascii=False)
    print(f'net2net 扩展完成: {old_h} → {new_h} 单元 → {DST}')


if __name__ == '__main__':
    main()
