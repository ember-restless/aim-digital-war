#!/usr/bin/env python3
"""批量合成 AIM 战斗语音（36 条中文，6 角色 × 选中/移动/攻击 × 2 句随机）
用法: python3 /root/aim/tool/gen_battle_voice.py [--test 角色] 
依赖: /opt/speak_volc.py + /root/.lili_volc_config.json（豆包 TTS）"""
import json, os, subprocess, sys, time

VOICES = {
    "1": "S_1FdrG37a2",  # Primus   小兵（新兵结巴）
    "2": "S_ZEdrG37a2",  # Secundus 轻骑兵（热血话痨）
    "3": "S_YEdrG37a2",  # Tertius  弓手（极简冷）
    "4": "S_XEdrG37a2",  # Quartus  炮兵（冷静哲思）
    "5": "S_WEdrG37a2",  # Quintus  重骑兵（俺腔自夸）
    "7": "S_VEdrG37a2",  # Septimus 盾兵（老长辈）
}

# (类型, 角色, 变体, 日文台词) —— 中文内容稿见 design/battle_voice.md
# 语气已处理：结巴（は、はい！）、促音（へへっ/えいっ）、长音（～/——）、省略号（……）、终助词（ぞ/ぜ/だよ）
LINES = [
    # 1 小兵 Primus：新兵紧张结巴
    ("select", "1", "a", "は、はい！し、新兵プリムスです！"),
    ("select", "1", "b", "は、はい！いつでもご命令を！"),
    ("move",   "1", "a", "い、今すぐ突っ込みます！"),
    ("move",   "1", "b", "は、はい！前へ進みます！"),
    ("attack", "1", "a", "や、やります！僕にだってできます！"),
    ("attack", "1", "b", "えいっ！新兵だって負けません！"),
    # 2 轻骑兵 Secundus：欢脱少女骑手
    ("select", "2", "a", "来た来た！騎兵セクンドゥス、いつでもどうぞ～！"),
    ("select", "2", "b", "私？へへっ、その言葉を待ってたよ！"),
    ("move",   "2", "a", "駆けるよ——！風を切って！"),
    ("move",   "2", "b", "突撃！騎兵ってやつを見せてやる！"),
    ("attack", "2", "a", "食らえ！見て見て、この一撃！"),
    ("attack", "2", "b", "斬っちゃうよ！ははっ、痛快！"),
    # 3 弓手 Tertius：沉默极简
    ("select", "3", "a", "……いる。何用だ。"),
    ("select", "3", "b", "……ああ。言え。"),
    ("move",   "3", "a", "……行く。急かすな。"),
    ("move",   "3", "b", "……前進。"),
    ("attack", "3", "a", "……当たる。"),
    ("attack", "3", "b", "……放つ。"),
    # 4 炮兵 Quartus：冷淡毒舌
    ("select", "4", "a", "……ふん。クォートゥス、配置についた。"),
    ("select", "4", "b", "……この一発、撃つ価値があるか考えてた。"),
    ("move",   "4", "a", "……前進。堅実にいこう。"),
    ("move",   "4", "b", "……悪くない位置だ。移るぞ。"),
    ("attack", "4", "a", "……撃て。思い知らせてやれ。"),
    ("attack", "4", "b", "……角度も風向きも、もう計算済みだ。放て。"),
    # 5 重骑兵 Quintus：豪爽大汉
    ("select", "5", "a", "俺か？へへっ、用があれば言ってくれ！"),
    ("select", "5", "b", "おっ？！俺クイントゥス、暇で仕方ねえんだ！"),
    ("move",   "5", "a", "いくぞ！俺の馬は、一歩で奴らの二歩分だ！"),
    ("move",   "5", "b", "どけどけどけ！俺が通るぞ！"),
    ("attack", "5", "a", "食らえ！俺の突撃、立ってられるか！"),
    ("attack", "5", "b", "潰してやる！この重さ、冗談じゃねえぞ！"),
    # 7 盾兵 Septimus：沉稳老兵
    ("select", "7", "a", "待機。私がいる限り、仲間は安心だ。"),
    ("select", "7", "b", "……うむ。言ってみろ。聞いている。"),
    ("move",   "7", "a", "……付いてこい。私が先頭を行く。"),
    ("move",   "7", "b", "……側面を固めろ。急ぐな。"),
    ("attack", "7", "a", "守れ！後ろには皆いる！"),
    ("attack", "7", "b", "任せろ。この壁、崩れはしない。"),
]

OUT_DIR = "/root/aim/client/assets/audio/battle"

def synth(text, voice, outpath):
    r = subprocess.run(
        ["/opt/embedding_env/bin/python3", "/opt/speak_volc.py", text, voice, outpath],
        capture_output=True, text=True, timeout=90)
    ok = r.returncode == 0 and os.path.exists(outpath) and os.path.getsize(outpath) > 1000
    if not ok:
        print(f"  [FAIL] {text[:24]}... {r.stderr.strip()[:120]}")
    return ok

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    test_only = None
    if len(sys.argv) > 2 and sys.argv[1] == "--test":
        test_only = sys.argv[2]
    done, fail = 0, 0
    for typ, ch, v, text in LINES:
        if test_only and ch != test_only:
            continue
        outpath = os.path.join(OUT_DIR, f"battle_{typ}_{ch}{v}.mp3")
        if os.path.exists(outpath) and os.path.getsize(outpath) > 1000:
            print(f"[skip] {os.path.basename(outpath)} 已存在")
            done += 1
            continue
        print(f"[synth] {os.path.basename(outpath)} 角色{ch} {text}")
        if synth(text, VOICES[ch], outpath):
            done += 1
        else:
            fail += 1
        time.sleep(0.4)
    print(f"\n完成 {done} 条, 失败 {fail} 条 → {OUT_DIR}")

if __name__ == "__main__":
    main()
