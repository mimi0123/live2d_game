#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_rhythm_chart.py —— 音频 → 音游谱面（双轨「光圈」）自动生成

配套工程：J:\\live2d_game
对应模块：scripts\\gd\\rhythm\\rhythm_game.gd（autoload RhythmGame）
谱面目录：data\\rhythm_charts\\*.json

谱面 JSON 格式：
{
  "name": "曲名",
  "audio": "res://audio/xxx.wav",     // 必须放在工程 audio 目录内；留空则用内部计时
  "lead_time": 1.6,                   // 光圈从出生到命中的秒数
  "lanes": [ [2.0, 3.0, ...], [2.5, 3.5, ...] ]   // 左轨 / 右轨，单位秒
}

用法：
  python gen_rhythm_chart.py "D:\\music\\song.mp3"
  python gen_rhythm_chart.py song.wav --difficulty 1.3 --name "我的谱面"
  python gen_rhythm_chart.py "D:\\music\\x.flac" --bpm 174 --min-gap 0.08
  python gen_rhythm_chart.py song.mp3 --sensitivity 2.5 --out data/rhythm_charts/song.json

依赖：仅 Python 标准库（wav 直接读取）。
      mp3 / flac / ogg 需要 ffmpeg —— 脚本会自动到常见位置查找，也可用 --ffmpeg 指定。
"""

import argparse
import array
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave

# 输出编码：优先跟随 PYTHONIOENCODING（双击 bat 时设为 gbk，匹配中文控制台）；
# 否则用 UTF-8（bash / 开发者终端）。
_enc = os.environ.get("PYTHONIOENCODING", "").split(":")[0].strip() or "utf-8"
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding=_enc, errors="replace")
    except Exception:
        pass

# 工程根目录：本脚本位于 <工程>/tools/ 下
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHART_DIR = os.path.join(PROJECT_ROOT, "data", "rhythm_charts")
AUDIO_DIR = os.path.join(PROJECT_ROOT, "audio")

FFMPEG_CANDIDATES = [
    r"F:\ffmpeg-master-latest-win64-gpl-shared\bin\ffmpeg.exe",
    r"C:\ffmpeg\bin\ffmpeg.exe",
    r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
]

HOP_S = 0.01      # 分析步长 10ms
WIN_S = 0.03      # 分析窗 30ms
THR_WIN_S = 0.50  # 自适应阈值统计窗 ±0.5s


# ---------------------------------------------------------------- ffmpeg
def find_ffmpeg(explicit=None):
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    found = shutil.which("ffmpeg")
    if found:
        return found
    for p in FFMPEG_CANDIDATES:
        if os.path.isfile(p):
            return p
    return None


def to_wav(src, ffmpeg):
    """把任意音频转成 16bit / 单声道 / 22050Hz 的临时 wav，返回 (路径, 是否临时)。"""
    if src.lower().endswith(".wav"):
        return src, False
    if ffmpeg is None:
        raise RuntimeError(
            "输入不是 .wav，且未找到 ffmpeg。请用 --ffmpeg 指定 ffmpeg.exe 路径，"
            "或先把音频转成 wav。"
        )
    tmp = os.path.join(tempfile.gettempdir(), "rhythm_src_%d.wav" % os.getpid())
    cmd = [ffmpeg, "-y", "-loglevel", "error", "-i", src,
           "-ac", "1", "-ar", "22050", "-sample_fmt", "s16", tmp]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0 or not os.path.isfile(tmp):
        raise RuntimeError("ffmpeg 转换失败：" + r.stderr.decode("utf-8", "replace")[:400])
    return tmp, True


# ---------------------------------------------------------------- 读取 / 分析
def read_mono(path):
    with wave.open(path, "rb") as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise RuntimeError("仅支持 16bit PCM wav（当前 %d bit）。请用 ffmpeg 重采样。" % (sw * 8))
    a = array.array("h")
    a.frombytes(raw)
    if sys.byteorder == "big":
        a.byteswap()
    if ch == 2:
        mono = array.array("h", [0]) * (len(a) // 2)
        for i in range(len(mono)):
            mono[i] = (a[2 * i] + a[2 * i + 1]) // 2
        a = mono
    elif ch > 2:
        step = ch
        mono = array.array("h", [0]) * (len(a) // step)
        for i in range(len(mono)):
            mono[i] = a[i * step]
        a = mono
    return a, sr


def energy_envelope(samples, sr):
    """滑窗 RMS 能量，按 HOP_S 采样。返回 float 列表。"""
    hop = max(1, int(sr * HOP_S))
    win = max(hop, int(sr * WIN_S))
    n = len(samples)
    frames = max(1, (n - win) // hop + 1)
    # 前缀平方和（用 int 累加，避免溢出损失）
    pref = [0] * (n + 1)
    acc = 0
    for i in range(n):
        s = samples[i]
        acc += s * s
        pref[i + 1] = acc
    env = [0.0] * frames
    for f in range(frames):
        i0 = f * hop
        i1 = i0 + win
        e = (pref[i1] - pref[i0]) / float(win)
        env[f] = math.sqrt(e)
    return env


def novelty(env):
    """能量上升沿（只取正差），突出「起音」。"""
    out = [0.0] * len(env)
    for i in range(1, len(env)):
        d = env[i] - env[i - 1]
        out[i] = d if d > 0.0 else 0.0
    return out


def adaptive_threshold(nov, sens):
    """滑动均值 + sens × 滑动标准差，作为逐点阈值。"""
    n = len(nov)
    w = max(1, int(THR_WIN_S / HOP_S))
    pref = [0.0] * (n + 1)
    pref2 = [0.0] * (n + 1)
    for i in range(n):
        v = nov[i]
        pref[i + 1] = pref[i] + v
        pref2[i + 1] = pref2[i] + v * v
    thr = [0.0] * n
    for i in range(n):
        a = max(0, i - w)
        b = min(n, i + w + 1)
        cnt = b - a
        m = (pref[b] - pref[a]) / cnt
        m2 = (pref2[b] - pref2[a]) / cnt
        var = max(0.0, m2 - m * m)
        thr[i] = m + sens * math.sqrt(var)
    return thr


def pick_peaks(nov, thr, min_gap):
    """局部极大 + 超阈值，再做最小间隔去重（间隔内保留更强的）。"""
    cand = []
    for i in range(1, len(nov) - 1):
        if nov[i] <= 0.0 or nov[i] < thr[i]:
            continue
        lo = max(0, i - 2)
        hi = min(len(nov), i + 3)
        if nov[i] >= max(nov[lo:hi]):
            cand.append((i * HOP_S, nov[i]))
    kept = []
    for t, s in cand:
        if kept and t - kept[-1][0] < min_gap:
            if s > kept[-1][1]:
                kept[-1] = (t, s)
            continue
        kept.append((t, s))
    return kept


def snap_to_grid(t, bpm):
    """把时间吸附到 1/4 拍网格（仅当偏移小于半格）。"""
    if not bpm:
        return t
    step = (60.0 / float(bpm)) / 4.0
    g = round(t / step) * step
    return g if abs(g - t) <= step * 0.5 else t


def assign_lanes(peaks, min_gap):
    """左右交替分配；若目标轨太密则让位给另一轨，都太密就丢弃。"""
    lanes = [[], []]
    last_t = [-1e9, -1e9]
    turn = 0
    for t, _s in peaks:
        placed = -1
        for ln in (turn, 1 - turn):
            if t - last_t[ln] >= min_gap:
                placed = ln
                break
        if placed < 0:
            continue
        lanes[placed].append(round(t, 3))
        last_t[placed] = t
        turn = 1 - placed
    return lanes


# ---------------------------------------------------------------- 主流程
def build_chart(audio_path, args):
    ffmpeg = find_ffmpeg(args.ffmpeg)
    wav_path, is_tmp = to_wav(audio_path, ffmpeg)
    try:
        samples, sr = read_mono(wav_path)
        dur = len(samples) / float(sr)
        print("音频: %s  时长 %.1f s  采样率 %d Hz" % (os.path.basename(audio_path), dur, sr))
        env = energy_envelope(samples, sr)
        nov = novelty(env)
        thr = adaptive_threshold(nov, args.sensitivity)
        peaks = pick_peaks(nov, thr, args.min_gap)
        print("检测到起音点 %d 个（灵敏度 %.2f，最小间隔 %.3f s）"
              % (len(peaks), args.sensitivity, args.min_gap))
        if args.bpm:
            peaks = [(snap_to_grid(t, args.bpm), s) for t, s in peaks]
            peaks.sort(key=lambda x: x[0])
        lanes = assign_lanes(peaks, args.min_gap)
        print("双轨分配完成：左轨 %d 个 / 右轨 %d 个" % (len(lanes[0]), len(lanes[1])))
    finally:
        if is_tmp and os.path.isfile(wav_path):
            os.remove(wav_path)

    # audio 字段：只有放进工程 audio\ 目录才能被 Godot 以 res:// 引用
    audio_field = ""
    ap = os.path.abspath(audio_path)
    try:
        rel = os.path.relpath(ap, AUDIO_DIR)
        if not rel.startswith(".."):
            audio_field = "res://audio/" + rel.replace("\\", "/")
    except ValueError:
        pass
    if not audio_field:
        print("提示：音频不在工程 audio\\ 目录内，谱面 audio 字段留空（用内部计时）。")
        print("      想带音乐玩，请把音频放到  %s  后重新运行。" % AUDIO_DIR)

    name = args.name or os.path.splitext(os.path.basename(audio_path))[0]
    return {
        "name": name,
        "audio": audio_field,
        "lead_time": args.lead_time,
        "lanes": lanes,
    }


def main():
    ap = argparse.ArgumentParser(description="音频 → 音游谱面自动生成")
    ap.add_argument("audio", help="音频文件（wav 直读；mp3/flac/ogg 需 ffmpeg）")
    ap.add_argument("--out", default="", help="输出 JSON 路径，默认 data/rhythm_charts/<音频名>.json")
    ap.add_argument("--name", default="", help="谱面显示名，默认取音频文件名")
    ap.add_argument("--difficulty", type=float, default=1.0,
                    help="难度系数：>1 更密（阈值更低），<1 更疏。等价于 --sensitivity 1/diff")
    ap.add_argument("--sensitivity", type=float, default=0.0,
                    help="峰值灵敏度阈值倍数（默认由 difficulty 推导，如 3.0）")
    ap.add_argument("--min-gap", type=float, default=0.10, help="音符最小间隔秒数（默认 0.10）")
    ap.add_argument("--lead-time", type=float, default=1.6, help="光圈出生→命中秒数（默认 1.6）")
    ap.add_argument("--bpm", type=float, default=0.0, help="指定 BPM 后把音符吸附到 1/4 拍网格")
    ap.add_argument("--ffmpeg", default="", help="ffmpeg.exe 路径（非 wav 输入时需要）")
    args = ap.parse_args()

    if not os.path.isfile(args.audio):
        print("找不到音频文件：" + args.audio)
        return 1
    if args.sensitivity <= 0.0:
        args.sensitivity = max(0.8, 3.0 / max(0.2, args.difficulty))

    try:
        chart = build_chart(args.audio, args)
    except Exception as e:
        print("生成失败：" + str(e))
        return 1

    out = args.out or os.path.join(CHART_DIR, os.path.splitext(os.path.basename(args.audio))[0] + ".json")
    if not os.path.isabs(out):
        out = os.path.join(PROJECT_ROOT, out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(chart, f, ensure_ascii=False, indent=2)
    total = len(chart["lanes"][0]) + len(chart["lanes"][1])
    print("谱面已写入：%s  （共 %d 个音符）" % (out, total))
    print("进游戏按 F7 或点工具栏「音游」按钮即可游玩。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
