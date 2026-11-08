import CoreMotion
import Foundation

/// 空间音频的调试记录（平时关着）：每个头部样本写进 motion.csv，连接、校准、对准、开关和每秒的状态写进 events.jsonl。
/// 格式和 HeadProbe（实测 AirPods 头部数据的探针）一样，可以直接拿去回放，和当时的实际表现对比。
/// 放在 ~/Library/Logs/EarPair/<时间>/，先进缓冲，每秒落一次盘；开始新记录时删掉 7 天前的。
/// 时间都是 MonotonicClock 的秒数。
public final class SpatialRecorder: @unchecked Sendable {
    public static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/EarPair", isDirectory: true)
    static let motionHeader = "t,ts,qx,qy,qz,qw,yaw,pitch,roll,rx,ry,rz,gx,gy,gz,ax,ay,az,loc\n"

    private let queue = DispatchQueue(label: "app.earpair.recorder")
    private var motionHandle: FileHandle?
    private var eventHandle: FileHandle?
    private var motionBuffer = ""
    private var eventBuffer = ""
    private var timer: DispatchSourceTimer?
    private var currentFolder: URL?
    private let lock = UnfairLock()
    private var recording = false

    public init() {}

    public var isRecording: Bool { lock.withLock { recording } }

    public var folder: URL? { queue.sync { currentFolder } }

    /// 开一个新的记录文件夹（正在记的先写完关掉）
    @discardableResult
    public func start(in root: URL = SpatialRecorder.root) throws -> URL {
        stop()
        Self.removeOld(in: root)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let motion = folder.appendingPathComponent("motion.csv")
        let events = folder.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: motion.path, contents: Data(Self.motionHeader.utf8))
        FileManager.default.createFile(atPath: events.path, contents: nil)
        let motionHandle = try FileHandle(forWritingTo: motion)
        let eventHandle = try FileHandle(forWritingTo: events)
        try motionHandle.seekToEnd()
        queue.sync {
            self.motionHandle = motionHandle
            self.eventHandle = eventHandle
            currentFolder = folder
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.flushLocked() }
            timer.resume()
            self.timer = timer
        }
        lock.withLock { recording = true }
        return folder
    }

    /// 写完缓冲，关掉文件
    public func stop() {
        lock.withLock { recording = false }
        queue.sync {
            timer?.cancel()
            timer = nil
            flushLocked()
            try? motionHandle?.close()
            try? eventHandle?.close()
            motionHandle = nil
            eventHandle = nil
            currentFolder = nil
        }
    }

    /// 一个头部样本（头部数据的队列上调用）
    public func motion(_ m: CMDeviceMotion, at time: Double) {
        guard isRecording else { return }
        let q = m.attitude.quaternion, r = m.rotationRate, g = m.gravity, a = m.userAcceleration
        let line = String(format: "%.4f,%.4f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%d\n",
                          time, m.timestamp, q.x, q.y, q.z, q.w, m.attitude.yaw, m.attitude.pitch, m.attitude.roll,
                          r.x, r.y, r.z, g.x, g.y, g.z, a.x, a.y, a.z, m.sensorLocation.rawValue)
        queue.async { self.motionBuffer += line }
    }

    /// 一个事件；fields 里的值要能写成 JSON（数字、字符串、布尔、nil 用 NSNull）。任何线程
    public func event(_ type: String, _ fields: [String: Any] = [:], at time: Double = MonotonicClock.now()) {
        guard isRecording else { return }
        var object = fields
        object["t"] = time
        object["type"] = type
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        queue.async { self.eventBuffer += line + "\n" }
    }

    private func flushLocked() {
        if !motionBuffer.isEmpty {
            try? motionHandle?.write(contentsOf: Data(motionBuffer.utf8))
            motionBuffer = ""
        }
        if !eventBuffer.isEmpty {
            try? eventHandle?.write(contentsOf: Data(eventBuffer.utf8))
            eventBuffer = ""
        }
    }

    /// 删掉 7 天前的记录
    static func removeOld(in root: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: folder) }
        }
    }
}
