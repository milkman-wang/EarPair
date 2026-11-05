#!/usr/bin/env python3
"""EarPair 测试发送端：没有 Windows 也能按协议 v1 往接收端发音频。只用标准库。

示例：
  python3 tools/test_sender.py 127.0.0.1                         # 440 Hz 正弦，30 秒
  python3 tools/test_sender.py 192.168.1.20 --wav song.wav       # 播放 16-bit PCM WAV
  python3 tools/test_sender.py 127.0.0.1 --clock-ppm 200 --jitter-ms 5 --loss 1 --reorder 2
  python3 tools/test_sender.py --vector                          # 打印协议文档里的测试向量
"""
import argparse
import heapq
import math
import random
import socket
import struct
import sys
import time
import wave

HEADER = struct.Struct("<4sBBBBIIQIHH")  # 32 字节，见 protocol/audio-packet.md
MAX_PACKET = 1472


def encode_packet(stream_id, sequence, sample_time, sample_rate, channels, samples):
    """samples：交错的 16-bit 整数样本"""
    frames = len(samples) // channels
    header = HEADER.pack(b"EARP", 1, 0, 1, channels, stream_id, sequence & 0xFFFFFFFF,
                         sample_time, sample_rate, frames, 0)
    return header + struct.pack("<%dh" % len(samples), *samples)


def tone_source(freq, amplitude, rate):
    """无限长的立体声正弦（左右相同）"""
    step = 2 * math.pi * freq / rate
    n = 0
    while True:
        value = int(round(amplitude * 32767 * math.sin(step * n)))
        yield value, value
        n += 1


def wav_source(path):
    """读 16-bit PCM WAV，返回（采样率, 帧生成器）"""
    w = wave.open(path, "rb")
    if w.getsampwidth() != 2:
        sys.exit("只支持 16-bit PCM WAV")
    channels = w.getnchannels()
    rate = w.getframerate()

    def frames():
        while True:
            chunk = w.readframes(1024)
            if not chunk:
                return
            values = struct.unpack("<%dh" % (len(chunk) // 2), chunk)
            for i in range(0, len(values), channels):
                left = values[i]
                right = values[i + 1] if channels > 1 else left
                yield left, right

    return rate, frames()


def main():
    p = argparse.ArgumentParser(description="EarPair 测试发送端")
    p.add_argument("host", nargs="?", help="Mac 接收端的 IP")
    p.add_argument("--port", type=int, default=47800)
    p.add_argument("--duration", type=float, default=30, help="发送多少秒（WAV 模式下最多到文件结束）")
    p.add_argument("--tone", type=float, default=440, help="正弦频率 Hz")
    p.add_argument("--amplitude", type=float, default=0.25)
    p.add_argument("--rate", type=int, default=48000, help="正弦模式的采样率")
    p.add_argument("--wav", help="改为发送这个 WAV 文件")
    p.add_argument("--frames", type=int, default=240, help="每包帧数")
    p.add_argument("--clock-ppm", type=float, default=0, help="模拟发送端时钟偏差（正数=比标称快）")
    p.add_argument("--jitter-ms", type=float, default=0, help="每包随机增加 0…N ms 的延迟")
    p.add_argument("--loss", type=float, default=0, help="随机丢包率（%%）")
    p.add_argument("--reorder", type=float, default=0, help="随机推迟 1.5 个包间隔的比例（%%），造成乱序")
    p.add_argument("--seed", type=int, help="随机数种子")
    p.add_argument("--vector", action="store_true", help="只打印协议测试向量")
    args = p.parse_args()

    if args.vector:
        packet = encode_packet(0x01020304, 7, 480, 48000, 2, [1000, -1000, 32767, -32768])
        print(packet.hex(" "))
        return
    if not args.host:
        p.error("需要接收端 IP")

    if args.wav:
        rate, source = wav_source(args.wav)
    else:
        rate, source = args.rate, tone_source(args.tone, args.amplitude, args.rate)
    if 32 + args.frames * 4 > MAX_PACKET:
        p.error("每包帧数太多，包会超过 %d 字节" % MAX_PACKET)

    rng = random.Random(args.seed)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    destination = (args.host, args.port)
    stream_id = rng.getrandbits(32)
    interval = args.frames / (rate * (1 + args.clock_ppm / 1e6))
    total = int(args.duration * rate / args.frames)
    jitter = args.jitter_ms / 1000

    print("发送到 %s:%d：%d Hz 立体声，每包 %d 帧（%.2f ms），共 %.1f 秒"
          % (args.host, args.port, rate, args.frames, args.frames / rate * 1000, total * args.frames / rate))
    if args.clock_ppm or jitter or args.loss or args.reorder:
        print("模拟：时钟偏差 %+g ppm，抖动 0–%g ms，丢包 %g%%，乱序 %g%%"
              % (args.clock_ppm, args.jitter_ms, args.loss, args.reorder))

    start = time.perf_counter() + 0.05
    queue = []  # (发送时刻, 序号, 包)
    made = sent = dropped = reordered = 0
    finished_source = False
    last_report = start
    while (made < total and not finished_source) or queue:
        now = time.perf_counter()
        # 生成到点的包（实际发送时刻 = 标称时刻 + 抖动 / 乱序延迟）
        while made < total and not finished_source and start + made * interval <= now:
            samples = []
            for _ in range(args.frames):
                try:
                    left, right = next(source)
                except StopIteration:
                    finished_source = True
                    break
                samples += (left, right)
            if finished_source:
                break
            packet = encode_packet(stream_id, made, made * args.frames, rate, 2, samples)
            due = start + made * interval + (rng.uniform(0, jitter) if jitter else 0)
            made += 1
            if rng.random() * 100 < args.loss:
                dropped += 1
                continue
            if rng.random() * 100 < args.reorder:
                due += interval * 1.5
                reordered += 1
            heapq.heappush(queue, (due, made, packet))
        while queue and queue[0][0] <= now:
            _, _, packet = heapq.heappop(queue)
            sock.sendto(packet, destination)
            sent += 1
        if now - last_report >= 5:
            last_report = now
            print("  已发送 %d 包（%.0f 秒）" % (sent, sent * args.frames / rate))
        next_event = min(queue[0][0] if queue else math.inf,
                         start + made * interval if made < total and not finished_source else math.inf)
        wait = next_event - time.perf_counter()
        if wait > 0:
            time.sleep(min(wait, 0.005))

    print("完成：生成 %d 包，发送 %d，故意丢弃 %d，故意乱序 %d" % (made, sent, dropped, reordered))


if __name__ == "__main__":
    main()
