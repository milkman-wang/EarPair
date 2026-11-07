import CoreAudio
import Foundation
import os

private let captureLog = Logger(subsystem: "app.earpair", category: "mac-audio")

/// 给空间音频提供一路立体声的来源（渲染线程上调用 read）
public protocol StereoSource: AnyObject, Sendable {
    var sampleRate: Double { get }
    /// 填 frames 帧；返回这一块有没有声音（没有时已经填了静音）
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool
    /// 停止：Mac 上的 App 恢复原样播放
    func stop()
}

public enum MacAudioError: Error, LocalizedError {
    case unsupported
    case ownProcess
    case tap(OSStatus)
    case format
    case aggregate(OSStatus)
    case io(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "macOS 14.2 or later is required"
        case .ownProcess: return "can’t find EarPair’s own audio process"
        case .tap(let status): return "can’t create the audio tap (\(status))"
        case .format: return "unsupported audio format"
        case .aggregate(let status): return "can’t create the capture device (\(status))"
        case .io(let status): return "can’t start capturing (\(status))"
        }
    }
}

/// 截取这台 Mac 上其他 App 的声音（不含 EarPair 自己），交给空间音频按 Mac 的方向重新播放。
///
/// 用 Core Audio 的进程 tap（macOS 14.2 起）：全局立体声 tap，排除 EarPair 自己（不然它会截到自己放出来的声音），
/// muteBehavior 是 mutedWhenTapped——只在我们读 tap 的时候原声静音；stop() 之后或者 EarPair 退出（包括崩溃），
/// 系统自动恢复原声。tap 放在一个只属于这个进程的聚合设备里读。
@available(macOS 14.2, *)
public final class MacAudioCapture: StereoSource, @unchecked Sendable {
    public let sampleRate: Double
    private let ring: CaptureRing
    private let lock = UnfairLock()
    private var tapID: AudioObjectID
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var stopped = false
    private let queue = DispatchQueue(label: "app.earpair.mac-audio", qos: .userInteractive)

    public init() throws {
        guard let own = Self.ownProcessObject() else { throw MacAudioError.ownProcess }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
        description.uuid = UUID()
        description.name = "EarPair"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw MacAudioError.tap(status) }
        tapID = tap
        guard let format = Self.tapFormat(tap), format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              format.mChannelsPerFrame >= 1, format.mSampleRate > 0 else {
            AudioHardwareDestroyProcessTap(tap)
            throw MacAudioError.format
        }
        sampleRate = format.mSampleRate
        ring = CaptureRing(sampleRate: format.mSampleRate)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)
        do {
            // 先试只含 tap 的聚合设备（不把耳机加进来，免得系统为了读它的麦克风把 AirPods 切到通话模式）；
            // 起不来就照 Apple 的示例，把默认输出设备当作主设备一起放进去
            do {
                try start(tapUID: description.uuid.uuidString, outputUID: nil, interleaved: interleaved, channels: channels)
            } catch {
                captureLog.error("只含 tap 的聚合设备起不来（\(error.localizedDescription, privacy: .public)），改用带输出设备的")
                teardownDevice()
                try start(tapUID: description.uuid.uuidString, outputUID: Self.defaultOutputUID(),
                          interleaved: interleaved, channels: channels)
            }
        } catch {
            teardownDevice()
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
        captureLog.notice("开始截取 Mac 的声音：\(format.mSampleRate) Hz，\(channels) 声道")
    }

    deinit { stop() }

    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        ring.read(left: left, right: right, frames: frames)
    }

    public func stop() {
        let alreadyStopped = lock.withLock { () -> Bool in
            defer { stopped = true }
            return stopped
        }
        guard !alreadyStopped else { return }
        teardownDevice()
        AudioHardwareDestroyProcessTap(tapID)
        captureLog.notice("停止截取 Mac 的声音")
    }

    // MARK: - 设备

    private func start(tapUID: String, outputUID: String?, interleaved: Bool, channels: Int) throws {
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EarPair Mac Audio",
            kAudioAggregateDeviceUIDKey: "app.earpair.mac-audio." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                               kAudioSubTapDriftCompensationKey: outputUID != nil]],
        ]
        if let outputUID {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        } else {
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[String: Any]]()
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr else { throw MacAudioError.aggregate(status) }
        aggregateID = aggregate

        let ring = self.ring
        let firstBuffer = DispatchSemaphore(value: 0)
        var signalled = false
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
            ring.write(input, interleaved: interleaved, channels: channels)
            if !signalled {
                signalled = true
                firstBuffer.signal()
            }
        }
        guard status == noErr, let proc else { throw MacAudioError.io(status) }
        ioProc = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw MacAudioError.io(status) }
        // 设备起来了但不出数据：当作失败（换另一种组合再试）
        guard firstBuffer.wait(timeout: .now() + 0.5) == .success else { throw MacAudioError.io(-1) }
    }

    private func teardownDevice() {
        if let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            self.ioProc = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - 查询

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr ? format : nil
    }

    private static func defaultOutputUID() throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr else {
            throw MacAudioError.aggregate(-1)
        }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { throw MacAudioError.aggregate(-1) }
        return value as String
    }
}

/// 截来的声音：IO 线程写，渲染线程读。开头先攒 25 ms 再出声；攒得太多（超过目标 50 ms）就丢掉旧的，
/// 读空了就重新攒。两边都跟着同一个输出设备的时钟走，平时不会漂。
public final class CaptureRing: @unchecked Sendable {
    private let lock = UnfairLock()
    private let ring: StereoRing
    private let target: Int
    private let ceiling: Int
    private var playing = false
    private let writeScratch: UnsafeMutablePointer<Float>
    private let readScratch: UnsafeMutablePointer<Float>
    private static let scratchFrames = 16_384

    public init(sampleRate: Double) {
        ring = StereoRing(capacity: max(4096, Int(sampleRate)))
        target = max(1024, Int(0.025 * sampleRate))
        ceiling = target + Int(0.050 * sampleRate)
        writeScratch = .allocate(capacity: Self.scratchFrames * 2)
        readScratch = .allocate(capacity: Self.scratchFrames * 2)
    }

    deinit {
        writeScratch.deallocate()
        readScratch.deallocate()
    }

    /// IO 线程：tap 交来的一块（Float32，交错或不交错，1 或 2 声道）
    public func write(_ list: UnsafePointer<AudioBufferList>, interleaved: Bool, channels: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let frames: Int
        if interleaved {
            frames = min(Int(first.mDataByteSize) / (4 * max(1, channels)), Self.scratchFrames)
            let source = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                writeScratch[i * 2] = source[i * channels]
                writeScratch[i * 2 + 1] = channels > 1 ? source[i * channels + 1] : source[i * channels]
            }
        } else {
            frames = min(Int(first.mDataByteSize) / 4, Self.scratchFrames)
            let left = data.assumingMemoryBound(to: Float.self)
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left : left
            for i in 0..<frames {
                writeScratch[i * 2] = left[i]
                writeScratch[i * 2 + 1] = right[i]
            }
        }
        guard frames > 0 else { return }
        _ = lock.withLock { ring.write(writeScratch, frames: min(frames, ring.capacity)) }
    }

    /// 渲染线程
    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int) -> Bool {
        left.update(repeating: 0, count: n)
        right.update(repeating: 0, count: n)
        guard n <= Self.scratchFrames else { return false }
        let available: Int = lock.withLock {
            if !playing {
                guard ring.count >= target else { return 0 }
                playing = true
            }
            if ring.count > ceiling { ring.discard(frames: ring.count - target) }
            let count = min(ring.count, n)
            if count < n { playing = false }  // 读空了：这次能放多少放多少，然后重新攒
            ring.peek(into: readScratch, frames: count)
            ring.discard(frames: count)
            return count
        }
        var sound = false
        for i in 0..<available {
            left[i] = readScratch[i * 2]
            right[i] = readScratch[i * 2 + 1]
            if !sound && (left[i] != 0 || right[i] != 0) { sound = true }
        }
        return sound
    }
}

/// 截取系统声音的权限（“屏幕与系统录音”里的“仅系统录音”）。系统没有公开查询的接口，这里用 TCC 的私有函数，
/// 找不到时当作不知道（开始截取时系统会自己问）。
public enum SystemAudioPermission {
    public enum Status: Sendable {
        case authorized, denied, unknown
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// 让系统问用户；回调在任意线程。找不到私有函数时直接回调 true（交给系统在开始截取时问）
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            completion(true)
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in completion(granted) }
    }
}
