#!/usr/bin/env python3
"""AIM 战斗 8-bit 音效合成器（纯 Python 标准库，无第三方依赖）
生成 assets/audio/sfx/*.wav —— 方波/三角波/噪声 + 包络 + 滑音 + 脉冲
跑法：python3 /root/aim/tool/gen_sfx.py
"""
import wave
import math
import random
import os

SR = 22050  # 采样率（8-bit 风格足够，文件小）
OUT_DIR = "/root/aim/client/assets/audio/sfx"


def synth_notes(notes, wave='square', vol=0.4, tau=0.06, noise_mix=0.0):
    """音符序列：[(freq, dur_sec), ...] 依次播放（无间隔）"""
    samples = []
    for f, dur in notes:
        n = int(dur * SR)
        phase = 0.0
        for i in range(n):
            t = i / SR
            phase += f / SR
            p = phase % 1.0
            if wave == 'square':
                v = 1.0 if p < 0.5 else -1.0
            elif wave == 'tri':
                v = 2.0 * abs(2.0 * p - 1.0) - 1.0
            elif wave == 'sine':
                v = math.sin(2.0 * math.pi * p)
            else:
                v = 2.0 * p - 1.0
            if noise_mix > 0:
                v = (1 - noise_mix) * v + noise_mix * random.uniform(-1, 1)
            env = math.exp(-t / tau) if tau > 0 else 1.0
            samples.append(v * env)
    return samples


def synth_pulse(f0, f1, dur, wave='square', vol=0.4, tau=0.05,
                pulses=1, on=None, gap=None, noise_mix=0.0, attack=0.003):
    """单音/多脉冲：频率从 f0 滑到 f1"""
    on = on or dur
    gap = gap or 0.0
    samples = []
    for _ in range(pulses):
        n = int(on * SR)
        phase = 0.0
        for i in range(n):
            t = i / SR
            f = f0 + (f1 - f0) * (t / on)  # 线性滑音
            phase += f / SR
            p = phase % 1.0
            if wave == 'square':
                v = 1.0 if p < 0.5 else -1.0
            elif wave == 'tri':
                v = 2.0 * abs(2.0 * p - 1.0) - 1.0
            elif wave == 'sine':
                v = math.sin(2.0 * math.pi * p)
            else:
                v = 2.0 * p - 1.0
            if noise_mix > 0:
                v = (1 - noise_mix) * v + noise_mix * random.uniform(-1, 1)
            # 包络：attack 线性升 + exp 衰减
            atk_env = min(1.0, t / attack) if attack > 0 else 1.0
            env = atk_env * math.exp(-t / tau)
            samples.append(v * env)
        if gap > 0 and _ < pulses - 1:
            samples += [0.0] * int(gap * SR)
    return samples


def save_wav(name, samples, vol=1.0):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b''
        for s in samples:
            v = max(-1.0, min(1.0, s * vol))
            frames += struct_pack(v)
        w.writeframes(frames)
    print(f"  [OK] {name}  {len(samples) / SR:.2f}s  {os.path.getsize(path)}B")


def struct_pack(v):
    import struct
    return struct.pack('<h', int(v * 32767))


def main():
    print("合成 8-bit 音效 →", OUT_DIR)
    # 选中：短促高音"哔"
    save_wav('sfx_select.wav', synth_pulse(880, 1320, 0.09, vol=0.32, tau=0.04))
    # 移动：双脉冲脚步"嗒嗒"
    save_wav('sfx_move.wav', synth_pulse(620, 620, 0.12, vol=0.3, tau=0.03, pulses=2, on=0.04, gap=0.035))
    # 近战攻击：噪声+低频"啪"
    save_wav('sfx_attack.wav', synth_pulse(190, 150, 0.14, wave='square', vol=0.45, tau=0.06, noise_mix=0.65))
    # 远程（弓/炮）：滑音"嗖"
    save_wav('sfx_shoot.wav', synth_pulse(1500, 380, 0.20, wave='tri', vol=0.4, tau=0.08))
    # 插桥：低音"咚"（木桥）
    save_wav('sfx_bridge.wav', synth_pulse(500, 310, 0.12, vol=0.42, tau=0.05, noise_mix=0.2))
    # 滚木：低频 4 脉冲"隆隆隆"
    save_wav('sfx_roll.wav', synth_pulse(105, 105, 0.36, wave='tri', vol=0.42, tau=0.03, pulses=4, on=0.055, gap=0.045))
    # 吞噬：下滑"咕"
    save_wav('sfx_devour.wav', synth_pulse(240, 110, 0.18, vol=0.4, tau=0.09))
    # 拆分：双快脉冲"咔嚓"
    save_wav('sfx_split.wav', synth_pulse(560, 560, 0.09, vol=0.35, tau=0.02, pulses=2, on=0.03, gap=0.02))
    # 造兵："叮"
    save_wav('sfx_produce.wav', synth_pulse(990, 990, 0.07, vol=0.3, tau=0.04))
    # 胜利：上行琶音"叮叮叮↑"
    save_wav('sfx_win.wav', synth_notes([(660, 0.09), (880, 0.09), (1320, 0.16)], vol=0.38, tau=0.06))
    # 失败：下行"咚…咚"
    save_wav('sfx_lose.wav', synth_notes([(440, 0.13), (220, 0.22)], wave='tri', vol=0.4, tau=0.09))
    print("完成")


if __name__ == "__main__":
    main()
