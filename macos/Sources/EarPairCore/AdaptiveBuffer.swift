import Foundation

/// 自动缓冲：按网络的实际情况决定缓冲目标。两部分取较大的：
///
/// 1. 平时的抖动。每 2 秒算一段：这段时间里每个包的传输时间（到达时刻 − 包里时间戳对应的时刻）
///    最长和最短差多少，也就是最晚的包比最顺利的包晚到了多久。缓冲至少要盖住它，再加上声卡一次
///    取走的量、一个包的时长（最新的包丢了时缺的就是它）和一点余量。取最近 15 段（半分钟）里第二大的：
///    偶尔一次延迟不算。
///
/// 2. 出过的问题，按原因和大小算。
///    - 卡顿（缓冲耗尽）：一定是包晚到了。卡顿后第一个到达的包比平时晚了多少，就知道当时缺多少缓冲。
///    - 迟到的包（到的时候那一段已经用静音补过了）：同样看它晚了多少。
///    - 丢包（包根本没来）：缓冲再大也没用，不算；接收端会在缓冲快用完时直接补静音，不让它卡顿。
///    同一次延迟引起的几个现象（卡顿加几个迟到包）算一次。最近 5 分钟里不到 3 次就不管；
///    满 3 次，目标定成刚好盖住其中第 3 严重的那次，也就是只放过最严重的两次。
///
/// 目标变大立即生效：卡顿后重新攒缓冲时一步到位，平时由漂移控制在几秒到几十秒里慢慢攒上去，听不出来。
/// 变小每秒最多 1 ms，同样由漂移控制慢慢消耗掉。
public struct AdaptiveBuffer: Sendable {
    public var minimum = 0.020
    public var maximum = 0.150
    /// 盖住抖动之外再留的余量（秒）
    public var margin = 0.005
    /// 一段的长度（秒）
    public var segmentDuration = 2.0
    /// 看最近多少段
    public var segments = 15
    /// 出过的问题看最近多久（秒），满几次才按它们加大
    public var incidentWindow = 300.0
    public var incidentCount = 3
    /// 相隔这么近（秒）的现象算同一次
    public var incidentMerge = 1.0
    /// 目标每秒最多减小多少（秒）
    public var decreaseRate = 0.001
    /// 两个包之间超过这么久算停顿（待机、发送端暂停），不算抖动：重新开始一段
    public var pauseThreshold = 0.5

    /// 一次问题：什么时候，要多大的缓冲才不会出
    public struct Incident: Sendable, Equatable {
        public var time: Double
        public var needed: Double
    }

    public private(set) var target: Double
    /// 最近 5 分钟里的问题（同一次延迟合并后）
    public private(set) var incidents: [Incident] = []

    private var spreads: [Double] = []
    /// 每段里最短的传输时间：最顺利时的基准，用来量“晚了多少”
    private var segmentMins: [Double] = []
    private var segmentStart: Double?
    private var segmentMin = 0.0
    private var segmentMax = 0.0
    private var lastArrival: Double?
    private var lastUpdate: Double?
    private var renderBlock = 0.0
    private var packetDuration = 0.0
    private var measureNextArrival = false

    public init(initial: Double = 0.040) {
        target = initial
    }

    /// 从某个值开始（打开自动时从当前缓冲开始）
    public mutating func start(from value: Double) {
        target = min(max(value, minimum), maximum)
        restart()
        incidents.removeAll()
    }

    /// 新的流、或者从待机恢复：之前的到达时间不能和之后的比，重新统计；已经定下的目标和出过的问题保留
    public mutating func restart() {
        spreads.removeAll()
        segmentMins.removeAll()
        segmentStart = nil
        lastArrival = nil
        lastUpdate = nil
        measureNextArrival = false
    }

    /// 声卡每次取走多少（秒）
    public mutating func setRenderBlock(_ seconds: Double) {
        renderBlock = seconds
    }

    /// 一个包有多长（秒）
    public mutating func setPacketDuration(_ seconds: Double) {
        packetDuration = seconds
    }

    /// 除了晚到的时间以外，缓冲还要留的：声卡一次取走的量、一个包、余量
    private var overhead: Double { renderBlock + packetDuration + margin }

    /// 收到一个按时（还没被跳过）的包。`transit` = 到达时刻 − 包的时间戳对应的时刻（秒），只看变化，基准无所谓。
    public mutating func packetArrived(transit: Double, at now: Double) {
        let paused = lastArrival.map { now - $0 > pauseThreshold } ?? false
        if paused {
            // 停顿之后的包不能拿来量卡顿（停顿本身不是延迟）
            segmentStart = nil
            measureNextArrival = false
        }
        if measureNextArrival, let base = baseline {
            measureNextArrival = false
            record(delay: transit - base, at: now)
        }
        track(transit: transit, at: now)
    }

    /// 收到一个迟到的包：它那一段已经补过静音了，说明缓冲不够
    public mutating func latePacketArrived(transit: Double, at now: Double) {
        if let base = baseline { record(delay: transit - base, at: now) }
        track(transit: transit, at: now)
    }

    /// 缓冲耗尽了：等下一个包到了，看它晚了多少
    public mutating func underrun() {
        measureNextArrival = true
    }

    /// 最近半分钟最顺利时的传输时间
    private var baseline: Double? {
        let current = segmentStart != nil ? [segmentMin] : []
        return (segmentMins + current).min()
    }

    private mutating func track(transit: Double, at now: Double) {
        lastArrival = now
        guard let start = segmentStart else {
            segmentStart = now
            segmentMin = transit
            segmentMax = transit
            return
        }
        segmentMin = min(segmentMin, transit)
        segmentMax = max(segmentMax, transit)
        if now - start >= segmentDuration {
            spreads.append(segmentMax - segmentMin)
            segmentMins.append(segmentMin)
            if spreads.count > segments {
                spreads.removeFirst(spreads.count - segments)
                segmentMins.removeFirst(segmentMins.count - segments)
            }
            segmentStart = nil
            update(now: now)
        }
    }

    private mutating func record(delay: Double, at now: Double) {
        let needed = max(delay, 0) + overhead
        if let last = incidents.last, now - last.time < incidentMerge {
            incidents[incidents.count - 1].needed = max(last.needed, needed)
        } else {
            incidents.append(Incident(time: now, needed: needed))
        }
        update(now: now)
    }

    private mutating func update(now: Double) {
        incidents.removeAll { now - $0.time > incidentWindow }
        var required = minimum
        if !spreads.isEmpty {
            let sorted = spreads.sorted(by: >)
            required = (sorted.count >= 2 ? sorted[1] : sorted[0]) + overhead
        }
        if incidents.count >= incidentCount {
            let worst = incidents.map(\.needed).sorted(by: >)
            required = max(required, worst[incidentCount - 1])
        }
        required = min(max(required, minimum), maximum)
        let elapsed = lastUpdate.map { now - $0 } ?? segmentDuration
        lastUpdate = now
        if required >= target {
            target = required
        } else {
            target = max(required, target - decreaseRate * elapsed)
        }
    }
}
