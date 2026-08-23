# AIM PC 音频：8bit 音效合成（纯标准库）+ 战斗语音（复用手机版 mp3）+ BGM
# 与 tool/gen_sfx.py 对齐的合成器，直接生成 pygame.mixer.Sound（不落地文件）
# 语音互斥：播放中触发新语音直接丢弃（与手机版一致）
import io
import math
import os
import random
import struct
import wave

SR = 22050

# ── 合成器（对齐 tool/gen_sfx.py）──
def _synth_notes(notes, wave='square', vol=0.4, tau=0.06, noise_mix=0.0):
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


def _synth_pulse(f0, f1, dur, wave='square', vol=0.4, tau=0.05,
                 pulses=1, on=None, gap=None, noise_mix=0.0, attack=0.003):
    on = on or dur
    gap = gap or 0.0
    samples = []
    for _ in range(pulses):
        n = int(on * SR)
        phase = 0.0
        for i in range(n):
            t = i / SR
            f = f0 + (f1 - f0) * (t / on)
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
            atk_env = min(1.0, t / attack) if attack > 0 else 1.0
            env = atk_env * math.exp(-t / tau)
            samples.append(v * env)
        if gap > 0 and _ < pulses - 1:
            samples += [0.0] * int(gap * SR)
    return samples


def _to_wav_bytes(samples, vol=1.0):
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b''
        for s in samples:
            v = max(-1.0, min(1.0, s * vol))
            frames += struct.pack('<h', int(v * 32767))
        w.writeframes(frames)
    return buf.getvalue()


def build_sfx_bytes():
    """返回 {name: wav_bytes}，与手机版 sfx 一一对应"""
    return {
        'select': _to_wav_bytes(_synth_pulse(880, 1320, 0.09, vol=0.32, tau=0.04)),
        'move': _to_wav_bytes(_synth_pulse(620, 620, 0.12, vol=0.3, tau=0.03, pulses=2, on=0.04, gap=0.035)),
        'attack': _to_wav_bytes(_synth_pulse(190, 150, 0.14, wave='square', vol=0.45, tau=0.06, noise_mix=0.65)),
        'shoot': _to_wav_bytes(_synth_pulse(1500, 380, 0.20, wave='tri', vol=0.4, tau=0.08)),
        'bridge': _to_wav_bytes(_synth_pulse(500, 310, 0.12, vol=0.42, tau=0.05, noise_mix=0.2)),
        'roll': _to_wav_bytes(_synth_pulse(105, 105, 0.36, wave='tri', vol=0.42, tau=0.03, pulses=4, on=0.055, gap=0.045)),
        'devour': _to_wav_bytes(_synth_pulse(240, 110, 0.18, vol=0.4, tau=0.09)),
        'split': _to_wav_bytes(_synth_pulse(560, 560, 0.09, vol=0.35, tau=0.02, pulses=2, on=0.03, gap=0.02)),
        'produce': _to_wav_bytes(_synth_pulse(990, 990, 0.07, vol=0.3, tau=0.04)),
        'win': _to_wav_bytes(_synth_notes([(660, 0.09), (880, 0.09), (1320, 0.16)], vol=0.38, tau=0.06)),
        'lose': _to_wav_bytes(_synth_notes([(440, 0.13), (220, 0.22)], wave='tri', vol=0.4, tau=0.09)),
    }


# 语音单位映射（与手机版 battle_voice.md 一致）
VOICE_UNITS = {1, 2, 3, 4, 5, 7}


class Audio:
    """pygame 音频封装；pygame 不可用或静音时安全降级"""

    def __init__(self, asset_dir=None):
        self.ok = False
        self.sfx = {}
        self.voice = {}   # (type, v, variant) -> Sound
        self.voice_busy = False
        self.sfx_vol = 0.35
        self.voice_vol = 1.0
        self.bgm_vol = 0.5
        self._bgm_playing = None  # 'idle' | 'battle'
        try:
            import pygame
            pygame.mixer.pre_init(SR, -16, 1, 512)
            pygame.mixer.init()
            self._pygame = pygame
            self.ok = True
            for name, data in build_sfx_bytes().items():
                self.sfx[name] = pygame.mixer.Sound(buffer=data)
            if asset_dir:
                bdir = os.path.join(asset_dir, 'audio', 'battle')
                if os.path.isdir(bdir):
                    for fn in os.listdir(bdir):
                        if not fn.startswith('battle_') or not fn.endswith('.mp3'):
                            continue
                        # battle_{type}_{v}{a|b}.mp3
                        rest = fn[len('battle_'):-len('.mp3')]
                        parts = rest.rsplit('_', 1)
                        if len(parts) != 2:
                            continue
                        t_v, variant = parts[0], parts[1]
                        t_v = t_v.rsplit('_', 1)
                        if len(t_v) != 2:
                            continue
                        try:
                            snd = pygame.mixer.Sound(os.path.join(bdir, fn))
                            self.voice[(t_v[0], int(t_v[1]), variant)] = snd
                        except Exception:
                            pass
        except Exception:
            self.ok = False

    def play_sfx(self, name):
        if not self.ok or self.sfx_vol <= 0:
            return
        s = self.sfx.get(name)
        if s is None:
            return
        s.set_volume(self.sfx_vol)
        s.play()

    def play_voice(self, vtype, v):
        if not self.ok or self.voice_vol <= 0 or v not in VOICE_UNITS:
            return
        if self.voice_busy:
            return  # 播放中：直接丢弃
        variant = 'a' if random.random() < 0.5 else 'b'
        s = self.voice.get((vtype, v, variant)) or self.voice.get((vtype, v, 'a'))
        if s is None:
            return
        self.voice_busy = True
        s.set_volume(self.voice_vol)
        s.play()
        self._pygame.time.wait(50)  # 不给完成事件时用轮询解锁
        # 轮询解锁：mp3 短句播完才允许下一条（互斥）
        import threading
        def _unlock():
            while self._pygame.mixer.get_busy():
                self._pygame.time.wait(100)
            self.voice_busy = False
        threading.Thread(target=_unlock, daemon=True).start()

    def play_bgm(self, which, asset_dir=None):
        if not self.ok or self.bgm_vol <= 0:
            return
        if self._bgm_playing == which and self._pygame.mixer.music.get_busy():
            return
        if not asset_dir:
            return
        path = os.path.join(asset_dir, 'audio', 'bgm', f'bgm_{which}.mp3')
        if not os.path.isfile(path):
            return
        try:
            self._pygame.mixer.music.load(path)
            self._pygame.mixer.music.set_volume(self.bgm_vol)
            self._pygame.mixer.music.play(-1)
            self._bgm_playing = which
        except Exception:
            pass

    def stop_bgm(self):
        if not self.ok:
            return
        try:
            self._pygame.mixer.music.stop()
        except Exception:
            pass
        self._bgm_playing = None
