#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_demo_song.py —— 合成一段示范节拍曲，供音游模块测试 / 演示

为什么要它：音游模块（rhythm）此前只有内部计时、没有音频，无法真机试手感。
本脚本用纯标准库合成一段 120 BPM 的鼓点 + 简易贝斯，直接产出可用的 wav，
再用 gen_rhythm_chart.py 生成对应谱面，就能立刻进游戏玩。

输出：<工程>/audio/demo_beat.wav （16bit / 单声道 / 22050Hz）

用法：
  python make_demo_song.py
  python make_demo_song.py --bpm 150 --bars 32 --out "J:\\live2d_game\\audio\\my_beat.wav"
"""

import argparse
import math
import os
import random
import struct
import sys
import wave

_enc = os.environ.get("PYTHONIOENCODING", "").split(":")[0].strip() or "utf-8"
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding=_enc, errors="replace")
    except Exception:
        pass

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SR = 22050


def _kick(buf, t0, gain=1.0):
    dur = 0.28
    n = int(SR * dur)
    i0 = int(t0 * SR)
    for i in range(n):
        idx = i0 + i
        if idx >= len(buf):
            break
        t = i / SR
        f = 45.0 + 95.0 * math.exp(-t / 0.035)          # 音高快速下滑
        env = math.exp(-t / 0.115)
        buf[idx] += gain * 0.95 * math.sin(2 * math.pi * f * t) * env


def _snare(buf, t0, gain=1.0):
    dur = 0.22
    n = int(SR * dur)
    i0 = int(t0 * SR)
    prev = 0.0
    for i in range(n):
        idx = i0 + i
        if idx >= len(buf):
            break
        t = i / SR
        env = math.exp(-t / 0.075)
        noise = random.uniform(-1.0, 1.0)
        hp = noise - prev * 0.85                        # 简易高通，出「沙沙」感
        prev = noise
        tone = 0.35 * math.sin(2 * math.pi * 190.0 * t) * math.exp(-t / 0.05)
        buf[idx] += gain * 0.55 * (hp * env + tone)


def _hihat(buf, t0, gain=1.0, open_=False):
    dur = 0.26 if open_ else 0.055
    n = int(SR * dur)
    i0 = int(t0 * SR)
    prev = 0.0
    for i in range(n):
        idx = i0 + i
        if idx >= len(buf):
            break
        t = i / SR
        env = math.exp(-t / (0.13 if open_ else 0.018))
        noise = random.uniform(-1.0, 1.0)
        hp = noise - prev
        prev = noise
        buf[idx] += gain * 0.20 * hp * env


def _bass(buf, t0, dur, freq, gain=1.0):
    n = int(SR * dur)
    i0 = int(t0 * SR)
    for i in range(n):
        idx = i0 + i
        if idx >= len(buf):
            break
        t = i / SR
        env = min(1.0, t / 0.01) * math.exp(-t / (dur * 0.55))
        s = math.sin(2 * math.pi * freq * t) + 0.3 * math.sin(4 * math.pi * freq * t)
        buf[idx] += gain * 0.30 * s * env


def build(bpm, bars):
    beat = 60.0 / bpm
    bar = beat * 4.0
    step = beat / 4.0                     # 16 分音符
    total = bar * bars + 1.5
    buf = [0.0] * int(SR * total)

    for b in range(bars):
        t_bar = b * bar
        phase = b % 8

        # 前 2 小节：只有 hihat，当作前奏
        intro = b < 2

        for s in range(16):
            t = t_bar + s * step
            if not intro:
                # kick
                if s in (0, 6, 10) or (phase in (4, 5) and s == 14):
                    _kick(buf, t, 1.0 if s == 0 else 0.82)
                elif phase >= 6 and s == 8:
                    _kick(buf, t, 0.7)
                # snare
                if s in (4, 12):
                    _snare(buf, t, 1.0 if s == 12 else 0.85)
                elif phase >= 6 and s == 15:
                    _snare(buf, t, 0.5)
            # hihat：八分 + 少量十六分点缀
            if s % 2 == 0 or (phase >= 2 and s % 4 == 1):
                _hihat(buf, t, 0.9 if s % 4 == 0 else 0.6,
                       open_=(s == 14 and phase % 4 == 3))

        # 简易贝斯：跟根音走，每小节 2 个音
        if not intro:
            roots = [110.0, 110.0, 146.83, 130.81]     # A A D C
            f = roots[b % 4]
            _bass(buf, t_bar, beat * 1.5, f, 1.0)
            _bass(buf, t_bar + beat * 2, beat * 1.2, f, 0.8)
            if phase >= 4:
                _bass(buf, t_bar + beat * 3.5, beat * 0.5, f * 1.5, 0.6)

    peak = max(1e-9, max(abs(v) for v in buf))
    scale = 30000.0 / peak
    out = bytearray()
    for v in buf:
        x = int(v * scale)
        x = -32768 if x < -32768 else (32767 if x > 32767 else x)
        out += struct.pack("<h", x)
    return bytes(out), total


def main():
    ap = argparse.ArgumentParser(description="合成音游示范节拍曲")
    ap.add_argument("--bpm", type=float, default=120.0, help="速度，默认 120")
    ap.add_argument("--bars", type=int, default=28, help="小节数，默认 28（120BPM 约 56 秒）")
    ap.add_argument("--out", default="", help="输出 wav 路径，默认 audio/demo_beat.wav")
    args = ap.parse_args()

    out = args.out or os.path.join(PROJECT_ROOT, "audio", "demo_beat.wav")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    random.seed(20260913)
    data, dur = build(args.bpm, args.bars)
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    print("已生成示范曲：%s" % out)
    print("时长 %.1f 秒 / %d BPM / %d 小节 / %.1f KB" % (dur, args.bpm, args.bars, len(data) / 1024.0))
    print("下一步：python tools\\gen_rhythm_chart.py \"%s\" --bpm %g" % (out, args.bpm))
    return 0


if __name__ == "__main__":
    sys.exit(main())
