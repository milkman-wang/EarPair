import CoreAudio
import Foundation

/// 系统默认输出设备（EarPair 的声音从这里出来），比如“milkman的AirPods Pro”、“MacBook Air扬声器”。
public struct OutputDevice: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, thunderbolt, virtual, other

        init(code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAutoAggregate: self = .virtual
            default: self = .other
            }
        }
    }

    public var id: AudioObjectID
    public var name: String
    public var model: String?
    public var transport: Transport
    /// 内置输出当前走的是耳机口（数据源 'hdpn'）
    public var usesHeadphoneJack: Bool

    public init(id: AudioObjectID = 0, name: String, model: String? = nil, transport: Transport,
                usesHeadphoneJack: Bool = false) {
        self.id = id
        self.name = name
        self.model = model
        self.transport = transport
        self.usesHeadphoneJack = usesHeadphoneJack
    }

    /// 控制包 STATUS 里的 transport 字段
    public var protocolTransport: String {
        switch transport {
        case .builtIn: return usesHeadphoneJack ? "headphones" : "builtin"
        case .bluetooth: return "bluetooth"
        case .usb: return "usb"
        case .airPlay: return "airplay"
        case .hdmi, .displayPort: return "hdmi"
        case .thunderbolt, .virtual, .other: return "other"
        }
    }

    /// 当前的默认输出设备；没有输出设备时返回 nil。
    public static func current() -> OutputDevice? {
        let id: AudioObjectID = OutputDeviceMonitor.value(OutputDeviceMonitor.system,
                                                          kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        return id == kAudioObjectUnknown ? nil : OutputDeviceMonitor.describe(id)
    }
}

/// 跟踪系统默认输出设备（AVAudioEngine 跟的就是它）：换设备、改名、插拔耳机都会回调。只在主线程用。
@MainActor
public final class OutputDeviceMonitor {
    public private(set) var current: OutputDevice?
    public var onChange: ((OutputDevice?) -> Void)?

    nonisolated static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let unknown = AudioObjectID(kAudioObjectUnknown)
    private static let deviceProperties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
    ]

    private var watched = OutputDeviceMonitor.unknown
    /// 添加和移除监听必须用同一个 block 实例
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
    }

    public init() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, listener)
        refresh()
    }

    public func refresh() {
        let id: AudioObjectID = Self.value(Self.system, kAudioHardwarePropertyDefaultOutputDevice) ?? Self.unknown
        if id != watched { watch(id) }
        let device = id == Self.unknown ? nil : Self.describe(id)
        guard device != current else { return }
        current = device
        onChange?(device)
    }

    private func watch(_ id: AudioObjectID) {
        for (selector, scope) in Self.deviceProperties {
            var address = Self.address(selector, scope)
            if watched != Self.unknown {
                AudioObjectRemovePropertyListenerBlock(watched, &address, .main, listener)
            }
            if id != Self.unknown, AudioObjectHasProperty(id, &address) {
                AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
            }
        }
        watched = id
    }

    nonisolated static func describe(_ id: AudioObjectID) -> OutputDevice {
        let transport: UInt32 = value(id, kAudioDevicePropertyTransportType) ?? 0
        let source: UInt32? = value(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        return OutputDevice(id: id,
                            name: string(id, kAudioObjectPropertyName) ?? "",
                            model: string(id, kAudioObjectPropertyModelName),
                            transport: .init(code: transport),
                            usesHeadphoneJack: source == 0x6864_706E /* 'hdpn' */)
    }

    nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size,
                                                       alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return nil }
        return storage.load(as: T.self)
    }

    /// 返回的 CFString 由调用方释放，所以用 takeRetainedValue
    nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var text: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &text) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let text else { return nil }
        let result = text.takeRetainedValue() as String
        return result.isEmpty ? nil : result
    }
}
