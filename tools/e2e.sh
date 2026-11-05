#!/bin/bash
# 端到端测试：真实 UDP（本机回环）。接收端不出声，把输出录成 WAV 再分析，每轮约 30 秒。
# 需要 Xcode 和带 numpy 的 Python 3；装了 .NET 8 SDK 时会多跑一轮"C# 发送端 → Swift 接收端"。
# 用法：tools/e2e.sh [输出目录]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$(mktemp -d)}"
PORT=47901
mkdir -p "$OUT"

(cd "$ROOT/macos" && source scripts/toolchain.sh >/dev/null && swift build -c release --product earpair-recv >/dev/null)
RECV="$ROOT/macos/.build/release/earpair-recv"
SENDER=(python3 "$ROOT/tools/test_sender.py" 127.0.0.1 --port $PORT --duration 25 --tone 440)
status=0

run() { # 名称 接收端参数 分析参数 发送命令...
  local name="$1" recv_args="$2" analyze_args="$3"
  shift 3
  "$RECV" --port $PORT --null-output --record "$OUT/$name.wav" --duration 29 --stats 5 $recv_args \
    > "$OUT/${name}_recv.log" 2>&1 &
  local pid=$!
  "$@" > "$OUT/${name}_send.log" 2>&1 || status=1
  wait $pid
  echo "== $name =="
  tail -1 "$OUT/${name}_send.log"
  tail -1 "$OUT/${name}_recv.log"
  python3 "$ROOT/tools/analyze_wav.py" "$OUT/$name.wav" --tone 440 $analyze_args || status=1
}

# 两端时钟相差 300 ppm：不应有任何跳变或断续
run drift "--clock-ppm -150" "" "${SENDER[@]}" --clock-ppm 150 --seed 1
# 8 ms 抖动 + 1% 丢包 + 2% 乱序：不应有跳变；断续次数约等于丢包数
run impaired "" "--max-dropouts 60" "${SENDER[@]}" --jitter-ms 8 --loss 1 --reorder 2 --seed 3

# C# 发送端的格式转换和打包代码 → Swift 接收端（验证两种语言的字节格式一致）
DOTNET="$(command -v dotnet || true)"
if [[ -z "$DOTNET" && -x "$HOME/.dotnet/dotnet" ]]; then DOTNET="$HOME/.dotnet/dotnet"; fi
if [[ -n "$DOTNET" ]]; then
  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
  "$DOTNET" build "$ROOT/windows/EarPair.Sender.SelfTest" -c Release >/dev/null
  run csharp "" "" "$DOTNET" "$ROOT/windows/EarPair.Sender.SelfTest/bin/Release/net8.0/EarPair.Sender.SelfTest.dll" \
    send 127.0.0.1 25 $PORT
else
  echo "（没找到 dotnet，跳过 C# 发送端这一轮）"
fi

echo "录音和日志在 $OUT"
if [[ $status -eq 0 ]]; then
  echo "通过"
else
  # 这是实时测试：机器很忙时，发送程序偶尔会被系统卡住几十毫秒，造成一次欠载。
  # 如果日志里"丢失"为 0 而"欠载"大于 1（结束时数据播完会自然记 1 次），多半是这个原因，重跑一次即可。
  echo "有检查没通过（如果没有丢包、只是多了一次欠载，可能是机器负载造成的停顿，可以重跑）"
fi
exit $status
