#!/usr/bin/env python3
"""检查 earpair-recv --null-output --record 录下的 WAV：测试正弦是否连续。需要 numpy。

查两类问题：
- 跳变（爆音）：纯正弦满足 x[n] = 2·cos(ω)·x[n-1] − x[n-2]。播放速度的细微调整（≤0.2%）只带来很小的残差，
  波形突然断开（跳帧、没有淡入淡出的缺口）会产生很大的残差。
- 断续：短时平均幅度掉到正常值一半以下的地方（丢包补的静音、欠载）。

用法：python3 tools/analyze_wav.py out.wav --tone 440 [--max-clicks 0] [--max-dropouts 0]
"""
import argparse
import sys
import wave

import numpy as np


def group(indices, max_gap):
    """把相邻的下标聚成 [起, 止] 区间"""
    events = []
    for i in indices:
        if events and i - events[-1][1] <= max_gap:
            events[-1][1] = i
        else:
            events.append([i, i])
    return events


def main():
    p = argparse.ArgumentParser()
    p.add_argument("wav")
    p.add_argument("--tone", type=float, default=440)
    p.add_argument("--max-clicks", type=int, default=0, help="允许的跳变次数")
    p.add_argument("--max-dropouts", type=int, default=0, help="允许的断续次数")
    args = p.parse_args()

    with wave.open(args.wav, "rb") as w:
        rate = w.getframerate()
        channels = w.getnchannels()
        data = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768
    x = data[0::channels]

    active = np.flatnonzero(np.abs(x) > 1e-3)
    if active.size == 0:
        print("录音里没有信号")
        return 1
    # 去掉开头的淡入和结尾数据耗尽的部分
    x = x[active[0] + 512: active[-1] - 512]

    omega = 2 * np.pi * args.tone / rate
    residual = x[2:] - 2 * np.cos(omega) * x[1:-1] + x[:-2]
    amplitude = np.sqrt(2) * np.std(x)
    clicks = group(np.flatnonzero(np.abs(residual) > 0.02 * amplitude), int(rate * 0.02))

    window = max(int(rate / args.tone * 1.5), 32)  # 至少一个半周期
    hop = window // 4
    level = np.array([np.mean(np.abs(x[i:i + window])) for i in range(0, len(x) - window, hop)])
    normal = np.median(level)
    dropouts = group(np.flatnonzero(level < 0.5 * normal), int(rate * 0.01 / hop) + 1)

    print("分析 %.1f 秒：幅度 %.3f，残差中位数 %.1e、最大 %.1e；跳变 %d 次，断续 %d 次"
          % (len(x) / rate, amplitude, np.median(np.abs(residual)), np.max(np.abs(residual)),
             len(clicks), len(dropouts)))
    for start, end in clicks[:5]:
        print("  跳变 %.3f s" % (start / rate))
    ok = len(clicks) <= args.max_clicks and len(dropouts) <= args.max_dropouts
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
