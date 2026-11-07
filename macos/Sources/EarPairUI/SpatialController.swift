import AppKit
import EarPairCore
import Foundation

/// 空间音频的状态：用户的开关、校准、什么时候真正用上（发送端在发、戴着支持头部追踪的耳机）。
///
/// - 用户关掉：一直关着。
/// - 发送端手动停止、网络断开超过几秒、还没连上：暂时不用，回来后自动接着用（开关不变）。网络抖一下不切换。
/// - 校准：先脸正对 Mac，再脸正对发送端的屏幕，各稳住 1.5 秒自动记下，最后问要不要保存。
/// - Mac 自己的声音：用着空间音频时截下来（原声静音），放在 Mac 的方向；要“系统录音”权限。不用时马上恢复原样。
@MainActor
public final class SpatialController: ObservableObject {
    /// 校准时界面显示的步骤
    public enum SetupStep: Equatable, Sendable {
        case mac
        case sender
        /// 两步都记下了，等用户保存：发送端在 Mac 左边多少度（右边为负）
        case review(angle: Double)
        case failed
    }

    /// 用户的开关
    @Published public var enabled: Bool {
        didSet {
            save(enabled, Keys.enabled)
            if !enabled { keepHeadUntil = MonotonicClock.now() + Self.headKeepAlive }
            refresh()
        }
    }

    /// Mac 自己的声音也跟着摆
    @Published public var includeMac: Bool {
        didSet {
            save(includeMac, Keys.includeMac)
            macFailure = nil
            refresh()
        }
    }

    /// 看别处时那台的声音保留多少（0…1）
    @Published public var awayVolume: Double {
        didSet {
            tracker.setAwayGain(awayVolume)
            save(awayVolume, Keys.awayVolume)
        }
    }

    @Published public private(set) var mode: SpatialMode = .off
    /// 截取 Mac 声音的权限被拒绝了
    @Published public private(set) var macPermissionDenied = false
    /// 截取 Mac 声音失败的原因
    @Published public private(set) var macFailure: String?
    /// 这台 Mac 能截取系统声音（macOS 14.2 起）
    public let macSoundSupported: Bool
    /// 校准过的夹角：发送端在 Mac 左边多少度（右边为负）；还没校准过时为 nil
    @Published public private(set) var angle: Double?
    /// 正在校准时的步骤；没在校准时为 nil
    @Published public private(set) var setup: SetupStep?
    /// 校准这一步头稳住了多久（0…1）
    @Published public private(set) var setupProgress = 0.0
    /// 每次加一：菜单栏面板请主窗口翻到空间音频这一页
    @Published public private(set) var pageRequest = 0
    private var handledPageRequest = 0
    /// 两台相对头的方向，约 10 次/秒（单独发布，只有示意图订阅）
    public let live = SpatialLive()

    private enum Keys {
        static let enabled = "spatialEnabled"
        static let awayVolume = "spatialAwayVolume"
        static let includeMac = "spatialIncludeMac"
        static let angle = "spatialAngle"
        static let main = "spatialMainScreen"
        static let map = "spatialGazeMap"
    }

    /// 网络断开后等多久才算发送端不在（和断开通知一样）
    nonisolated static let senderGrace = ConnectionNoticePolicy.graceSeconds
    /// 关掉空间音频后头部数据再读这么久（秒）：很快又打开时方向接得上，不用重新找
    nonisolated static let headKeepAlive = 600.0

    private let tracker: SpatialTracker
    private let head: HeadTracker?
    private weak var output: AudioOutput?
    private let isLive: Bool
    private var linkState = LinkState.waiting
    private var senderGoneSince: Double?
    private var outputDevice: OutputDevice?
    private var ticks = 0
    private var terminationObserver: NSObjectProtocol?
    private var keepHeadUntil = -Double.infinity
    private var macPermission = SystemAudioPermission.Status.unknown
    private var askingPermission = false
    /// 问过权限、系统说可以，但查不到状态（私有函数不在了）：照常截取，让系统自己处理
    private var permissionAssumed = false

    /// 正常运行：读取存下来的设置和校准，开始跟踪
    init(output: AudioOutput) {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        awayVolume = defaults.object(forKey: Keys.awayVolume) as? Double ?? 0.5
        includeMac = defaults.object(forKey: Keys.includeMac) as? Bool ?? true
        if #available(macOS 14.2, *) { macSoundSupported = true } else { macSoundSupported = false }
        var saved: SpatialTracker.Saved?
        if let angle = defaults.object(forKey: Keys.angle) as? Double {
            let main: ScreenAnchors.Screen = defaults.string(forKey: Keys.main) == "mac" ? .mac : .windows
            saved = SpatialTracker.Saved(angle: angle, main: main, map: defaults.array(forKey: Keys.map) as? [Double] ?? [])
        }
        tracker = SpatialTracker(saved: saved)
        angle = saved?.angle
        head = HeadTracker()
        self.output = output
        isLive = true
        tracker.setAwayGain(awayVolume)
        let tracker = self.tracker
        tracker.onPlace = { [weak output] sender, mac in output?.place(sender: sender, mac: mac) }
        output.onMacAudioFailure = { [weak self] reason in self?.macFailure = reason }
        macPermission = SystemAudioPermission.status
        head?.onSample = { sample in tracker.add(sample) }
        head?.onConnectionChange = { [weak self] _ in
            tracker.connectionChanged()
            Task { @MainActor in self?.refresh() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
        refresh()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// 只用来渲染界面
    public init(preview mode: SpatialMode, enabled: Bool, angle: Double?, setup: SetupStep? = nil,
                setupProgress: Double = 0, macRelative: Double? = 0, senderRelative: Double? = 50,
                includeMac: Bool = true, macPermissionDenied: Bool = false) {
        self.enabled = enabled
        self.includeMac = includeMac
        self.macPermissionDenied = macPermissionDenied
        macSoundSupported = true
        awayVolume = 0.5
        tracker = SpatialTracker(saved: nil)
        head = nil
        isLive = false
        self.mode = mode
        self.angle = angle
        self.setup = setup
        self.setupProgress = setupProgress
        live.update(macRelative: macRelative, senderRelative: senderRelative)
    }

    // MARK: - 来自接收控制器

    /// 连接状态（每次 tick 都可以调）。网络断开的时刻记下来：断开后 senderGrace 秒内还算发送端在
    func update(linkState: LinkState, now: Double) {
        if linkState == .reconnecting || linkState == .disconnected {
            if senderGoneSince == nil { senderGoneSince = now }
        } else {
            senderGoneSince = nil
        }
        guard linkState != self.linkState else { return }
        self.linkState = linkState
        refresh()
    }

    func update(outputDevice: OutputDevice?) {
        self.outputDevice = outputDevice
        refresh()
    }

    // MARK: - 操作

    /// 菜单栏面板上的开关：还没校准过时打开主窗口的空间音频页
    public func toggleFromPanel() {
        if angle == nil {
            enabled = true
            pageRequest += 1
            _ = MainWindowOpener.shared.show()
        } else {
            enabled.toggle()
        }
    }

    /// 主窗口出现或收到请求时调用：有没处理的翻页请求就翻过去
    func takePageRequest() -> Bool {
        defer { handledPageRequest = pageRequest }
        return pageRequest != handledPageRequest
    }

    public func beginSetup() {
        tracker.beginCalibration()
        setup = .mac
        setupProgress = 0
        refresh()
    }

    public func cancelSetup() {
        tracker.cancelCalibration()
        setup = nil
        refresh()
    }

    /// 校准记下了两台：保存
    public func saveSetup() {
        guard let saved = tracker.commitCalibration() else { return }
        angle = saved.angle
        setup = nil
        enabled = true
        persist()
        refresh()
    }

    /// 看着 Mac 时点：把 Mac 的方向定在现在的朝向
    public func recenter() {
        tracker.recenter()
        NSSound(named: "Tink")?.play()
    }

    public func openAudioCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openMotionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Motion") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 定时

    private func tick() {
        ticks += 1
        let status = tracker.status()
        live.update(macRelative: status.macRelative, senderRelative: status.senderRelative)
        if setup != nil { updateSetup(status) }
        if ticks % 5 == 0 { refresh() }
        // 被拒绝时隔一会儿再查：用户可能去系统设置里打开了
        if ticks % 50 == 0, macPermission == .denied {
            macPermission = SystemAudioPermission.status
            if macPermission != .denied { refresh() }
        }
        if ticks % 600 == 0 { persist() }
    }

    private func updateSetup(_ status: SpatialTracker.Status) {
        let next: SetupStep
        switch status.calibration {
        case .mac?: next = .mac
        case .sender?: next = .sender
        case .done(let mac, let sender)?: next = .review(angle: ScreenAnchors.wrap(sender - mac))
        case .failed?: next = .failed
        case nil: return
        }
        if next != setup {
            if case .mac? = setup, next == .sender { NSSound(named: "Tink")?.play() }
            if case .review = next { NSSound(named: "Glass")?.play() }
            setup = next
        }
        let progress = (status.calibrationProgress * 20).rounded() / 20
        if progress != setupProgress { setupProgress = progress }
    }

    /// 算出现在用不用空间音频，跟着开关耳机的头部数据和音频图
    private func refresh() {
        guard isLive else { return }
        let now = MonotonicClock.now()
        let senderPresent: Bool
        switch linkState {
        case .connecting, .playing, .standby, .outputFailed:
            senderPresent = true
        case .reconnecting, .disconnected:
            senderPresent = now - (senderGoneSince ?? now) < Self.senderGrace
        case .waiting, .stopped, .receiveFailed:
            senderPresent = false
        }
        let headphones = (head?.isConnected ?? false) && outputDevice?.transport == .bluetooth
        let next = SpatialMode.decide(enabled: enabled, calibrated: angle != nil, authorization: HeadTracker.authorization,
                                      headphones: headphones, senderPresent: senderPresent)
        // 头部数据：开着空间音频、发送端最近还在（一分钟内）或者正在校准时读；读不到耳机时也要读，才知道它什么时候连上
        let wantsHead = setup != nil
            || (angle != nil && linkState != .waiting && (enabled || now < keepHeadUntil))
        if let head {
            if wantsHead, !head.isRunning {
                // 重新开始读，读数会从头算：先告诉跟踪的那边
                tracker.motionRestarted()
                head.start()
            } else if !wantsHead {
                head.stop()
            }
        }
        if next != mode {
            if next == .active { macFailure = nil }
            mode = next
        }
        tracker.setActive(next == .active)
        // 先定要不要截取，再切空间音频：打开时只重建一次音频图
        output?.setMacAudio(next == .active && wantsMacAudio())
        output?.setSpatial(next == .active)
        let denied = includeMac && macPermission == .denied
        if denied != macPermissionDenied { macPermissionDenied = denied }
    }

    /// 要不要截取 Mac 的声音；还没问过权限时先问（问完再 refresh）
    private func wantsMacAudio() -> Bool {
        guard includeMac, macSoundSupported, macFailure == nil else { return false }
        switch macPermission {
        case .authorized: return true
        case .denied: return false
        case .unknown:
            if permissionAssumed { return true }
            if !askingPermission {
                askingPermission = true
                SystemAudioPermission.request { [weak self] granted in
                    Task { @MainActor in self?.permissionAnswered(granted) }
                }
            }
            return false
        }
    }

    private func permissionAnswered(_ granted: Bool) {
        askingPermission = false
        macPermission = SystemAudioPermission.status
        if macPermission == .unknown {
            if granted { permissionAssumed = true } else { macPermission = .denied }
        }
        refresh()
    }

    private func persist() {
        guard isLive, let saved = tracker.saved() else { return }
        let defaults = UserDefaults.standard
        defaults.set(saved.angle, forKey: Keys.angle)
        defaults.set(saved.main == .mac ? "mac" : "windows", forKey: Keys.main)
        defaults.set(saved.map, forKey: Keys.map)
    }

    private func save(_ value: Any, _ key: String) {
        if isLive { UserDefaults.standard.set(value, forKey: key) }
    }
}

/// 两台相对头的方向（度，左为正），约 10 次/秒；只有示意图订阅
@MainActor
public final class SpatialLive: ObservableObject {
    @Published public private(set) var macRelative: Double?
    @Published public private(set) var senderRelative: Double?

    nonisolated init() {}

    func update(macRelative: Double?, senderRelative: Double?) {
        // 一度以内的变化不发布，头不动时不重画
        if !Self.same(macRelative, self.macRelative) { self.macRelative = macRelative }
        if !Self.same(senderRelative, self.senderRelative) { self.senderRelative = senderRelative }
    }

    private static func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) < 1
        default: return false
        }
    }
}
