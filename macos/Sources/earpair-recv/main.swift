import EarPairCore
import Foundation

// earpair-recv：EarPair 的命令行接收端。日常使用请用菜单栏 App；这个工具用于调试、无界面运行和自动化测试。

struct Options {
    var port: UInt16 = 47800
    var bufferMs = 60
    var duration: Double?
    var statsInterval = 1.0
    var driftCompensation = true
    var nullOutput = false
    var recordPath: String?
    var clockPPM = 0.0
    var sampleRate = 48_000.0
}

let usage = """
用法：earpair-recv [选项]

  --port N         监听的 UDP 端口（默认 47800）
  --buffer-ms N    缓冲目标，毫秒（默认 60）
  --duration S     运行 S 秒后退出（默认一直运行，Ctrl+C 退出）
  --stats S        每 S 秒打印一次统计（默认 1）
  --no-drift       关闭时钟漂移补偿（对照实验用）
  --null-output    不出声：在内部按实时节奏"播放"，用于测试
  --record PATH    （配合 --null-output）把输出录成 16-bit WAV
  --clock-ppm X    （配合 --null-output）模拟本机声卡时钟偏差 X ppm
  --rate HZ        （配合 --null-output）输出采样率（默认 48000）
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    func value(for name: String) -> String {
        guard let value = arguments.popFirst() else { fail("\(name) 需要一个参数") }
        return value
    }
    func number(for name: String) -> Double {
        guard let number = Double(value(for: name)) else { fail("\(name) 需要一个数字") }
        return number
    }
    while let argument = arguments.popFirst() {
        switch argument {
        case "--port":
            guard let port = UInt16(value(for: argument)), port > 0 else { fail("端口无效") }
            options.port = port
        case "--buffer-ms": options.bufferMs = Int(number(for: argument))
        case "--duration": options.duration = number(for: argument)
        case "--stats": options.statsInterval = max(0.1, number(for: argument))
        case "--no-drift": options.driftCompensation = false
        case "--null-output": options.nullOutput = true
        case "--record": options.recordPath = value(for: argument)
        case "--clock-ppm": options.clockPPM = number(for: argument)
        case "--rate": options.sampleRate = number(for: argument)
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("未知参数：\(argument)")
        }
    }
    if options.recordPath != nil && !options.nullOutput { fail("--record 需要和 --null-output 一起用") }
    return options
}

func format(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

func describe(_ s: ReceiverStats, kbps: Double) -> String {
    let state: String
    switch s.state {
    case .idle: state = s.endedBySender ? "已停止" : "等待"
    case .buffering: state = "缓冲"
    case .playing: state = "播放"
    }
    return "[\(state)] 收 \(s.packetsReceived) 丢 \(s.packetsLost)(\(format(s.lossPercent, 2))%) "
        + "迟到 \(s.packetsLate) 忽略 \(s.packetsIgnored) 欠载 \(s.underruns) 裁剪 \(s.latencyTrims) | "
        + "缓冲 \(format(s.bufferedMs))/\(format(s.targetMs, 0)) ms | "
        + "漂移 \(String(format: "%+.0f", s.driftPPM)) ppm | 抖动 \(format(s.jitterMs)) ms | \(format(kbps, 0)) kbps"
}

let options = parseOptions()
var configuration = ReceiverCore.Configuration()
configuration.targetLatency = Double(options.bufferMs) / 1000
configuration.driftCompensation = options.driftCompensation
let core = ReceiverCore(configuration: configuration)

var audioOutput: AudioOutput?
var nullOutput: NullOutput?
if options.nullOutput {
    let output = NullOutput(core: core, sampleRate: options.sampleRate, clockPPM: options.clockPPM,
                            recording: options.recordPath != nil)
    core.setOutputSampleRate(options.sampleRate)
    core.onStreamStarted = { format in
        print("新的音频流：\(format.sampleRate) Hz，\(format.channels) 声道")
        if Double(format.sampleRate) != options.sampleRate {
            print("注意：流的采样率和 --rate 不一致，输出会是静音")
        }
    }
    output.start()
    nullOutput = output
} else {
    let output = AudioOutput(core: core)
    core.onStreamStarted = { format in
        print("新的音频流：\(format.sampleRate) Hz，\(format.channels) 声道")
        DispatchQueue.main.async {
            do {
                try output.start(sampleRate: Double(format.sampleRate))
            } catch {
                print("无法打开音频输出：\(error.localizedDescription)")
            }
        }
    }
    audioOutput = output
}

/// 控制包回 STATUS 要用到接收器：用一个弱引用盒子接起来
final class ReceiverBox: @unchecked Sendable {
    weak var receiver: UDPReceiver?
}

let receiverBox = ReceiverBox()
let receiverID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
let responder = ControlResponder(
    core: core,
    info: ControlResponder.LocalInfo(id: receiverID, name: HostInfo.computerName, kind: HostInfo.kind.rawValue,
                                     app: "0.2.0",
                                     output: options.nullOutput ? nil : OutputDevice.current()?.name,
                                     transport: options.nullOutput ? nil : OutputDevice.current()?.protocolTransport)
) { data, endpoint in
    receiverBox.receiver?.send(data, to: endpoint)
}
let receiver = UDPReceiver(
    port: options.port,
    onPacket: { bytes, sender, now in core.ingest(bytes, from: sender, at: now) },
    onControl: { bytes, sender, now in responder.handle(bytes, from: sender, now: now) },
    onTick: { now in
        core.housekeeping(now: now)
        responder.tick(now: now)
    })
receiverBox.receiver = receiver
do {
    try receiver.start()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

// 在局域网里广播，Windows 端可以自动找到这台 Mac
let advertiser = ServiceAdvertiser()
advertiser.start(port: options.port, id: receiverID, kind: HostInfo.kind)

print("EarPair 接收端 0.2：在 UDP \(options.port) 端口等待发送端…")
let addresses = NetworkInfo.localIPv4Addresses()
if !addresses.isEmpty { print("本机局域网地址：\(addresses.joined(separator: "、"))") }
print(options.nullOutput ? "（--null-output：不会出声）" : "声音从系统当前的输出设备播放。按 Ctrl+C 退出。")

let startTime = MonotonicClock.now()
var lastBytes = 0

func finish() -> Never {
    receiver.stop()
    nullOutput?.stop()
    audioOutput?.stop()
    if let path = options.recordPath, let nullOutput {
        do {
            try nullOutput.writeWAV(to: path)
            print("已录制到 \(path)")
        } catch {
            print("写 WAV 失败：\(error.localizedDescription)")
        }
    }
    let s = core.statistics(now: MonotonicClock.now())
    print("结束：收到 \(s.packetsReceived) 包，丢失 \(s.packetsLost)，迟到 \(s.packetsLate)，欠载 \(s.underruns)，"
        + "裁剪 \(s.latencyTrims)，补静音 \(s.concealedFrames) 帧，时钟偏差 \(String(format: "%+.1f", s.driftPPM)) ppm")
    exit(0)
}

let statsTimer = DispatchSource.makeTimerSource(queue: .main)
statsTimer.schedule(deadline: .now() + options.statsInterval, repeating: options.statsInterval)
statsTimer.setEventHandler {
    let now = MonotonicClock.now()
    let stats = core.statistics(now: now)
    let kbps = Double(max(0, stats.bytesReceived - lastBytes)) * 8 / options.statsInterval / 1000
    lastBytes = stats.bytesReceived
    print(describe(stats, kbps: kbps))
    if let duration = options.duration, now - startTime >= duration { finish() }
}
statsTimer.resume()

signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler { finish() }
interruptSource.resume()

dispatchMain()
