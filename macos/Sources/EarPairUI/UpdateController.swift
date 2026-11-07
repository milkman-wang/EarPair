import AppKit
import EarPairCore
import Foundation
import os
import SwiftUI

private let updateLog = Logger(subsystem: "app.earpair", category: "update")

/// 自动更新：打开后过一会儿查一次 GitHub，之后每 6 小时查一次；有新版本时菜单栏面板上出现“更新到 x.y.z”，
/// 点了就下载、校验、换掉正在运行的 EarPair 并重新打开。设置环境变量 EARPAIR_UPDATE_FEED 可以换成别的地址（测试用）。
@MainActor
public final class UpdateController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        case available(AppRelease)
        /// 下载进度 0…1
        case downloading(Double)
        case installing
        case failed(String, AppRelease?)
    }

    @Published public private(set) var state = State.idle
    public let currentVersion: String

    nonisolated static let firstCheckDelay = 15.0
    nonisolated static let interval = 6.0 * 3600

    private let feed: URL
    private let isLive: Bool
    private var checkTask: Task<Void, Never>?

    init(currentVersion: String) {
        self.currentVersion = currentVersion
        feed = ProcessInfo.processInfo.environment["EARPAIR_UPDATE_FEED"].flatMap(URL.init(string:)) ?? Updater.feed
        isLive = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstCheckDelay))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// 只用来渲染界面
    public init(preview state: State, currentVersion: String = "0.2.2") {
        self.currentVersion = currentVersion
        self.state = state
        feed = Updater.feed
        isLive = false
    }

    /// 有新版本时那一行要显示的版本
    public var availableVersion: String? {
        switch state {
        case .available(let release): return release.version
        case .failed(_, let release?): return release.version
        default: return nil
        }
    }

    /// 查一次。用户点的“检查更新”会弹窗告诉结果（有新版本时可以直接更新）
    public func check(userInitiated: Bool) async {
        guard isLive else { return }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        let previous = state
        state = .checking
        do {
            let release = try await Updater.fetchLatest(from: feed)
            if Updater.isNewer(release.version, than: currentVersion) {
                updateLog.notice("有新版本：\(release.version, privacy: .public)（现在 \(self.currentVersion, privacy: .public)）")
                state = .available(release)
                if userInitiated { offer(release) }
            } else {
                state = .idle
                if userInitiated { tellUpToDate() }
            }
        } catch {
            updateLog.error("检查更新失败：\(error.localizedDescription, privacy: .public)")
            // 自动检查失败不打扰用户，保留原来的状态
            state = previous == .checking ? .idle : previous
            if userInitiated { tellCheckFailed(error.localizedDescription) }
        }
    }

    public func checkFromMenu() {
        NSApp.activate()
        Task { await check(userInitiated: true) }
    }

    /// 下载、校验、换上新版、重新打开
    public func install() {
        let release: AppRelease
        switch state {
        case .available(let r): release = r
        case .failed(_, let r?): release = r
        default: return
        }
        state = .downloading(0)
        Task {
            do {
                let dmg = try await Updater.download(release) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.state { self.state = .downloading(fraction) }
                    }
                }
                state = .installing
                let target = Bundle.main.bundleURL
                let staged = try await Task.detached(priority: .userInitiated) {
                    try Updater.stage(dmg: dmg, expectedVersion: release.version, beside: target)
                }.value
                try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent())
                try Updater.swapAndRelaunch(staged: staged, target: target)
                updateLog.notice("更新到 \(release.version, privacy: .public)，退出后由脚本换上")
                NSApp.terminate(nil)
            } catch {
                updateLog.error("更新失败：\(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription, release)
            }
        }
    }

    public func openReleasePage() {
        let page: URL
        switch state {
        case .available(let release), .failed(_, let release?): page = release.page
        default: page = URL(string: "https://github.com/milkman-wang/EarPair/releases/latest")!
        }
        NSWorkspace.shared.open(page)
    }

    // MARK: - 弹窗（只在用户自己点“检查更新”时）

    private func offer(_ release: AppRelease) {
        let alert = NSAlert()
        alert.messageText = String(localized: "EarPair \(release.version) is available", bundle: .module)
        alert.informativeText = String(localized: "You have \(currentVersion).", bundle: .module)
        alert.addButton(withTitle: String(localized: "Update", bundle: .module))
        alert.addButton(withTitle: String(localized: "Later", bundle: .module))
        if alert.runModal() == .alertFirstButtonReturn { install() }
    }

    private func tellUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "EarPair is up to date", bundle: .module)
        alert.informativeText = String(localized: "\(currentVersion) is the latest version.", bundle: .module)
        alert.runModal()
    }

    private func tellCheckFailed(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t check for updates", bundle: .module)
        alert.informativeText = reason
        alert.runModal()
    }
}

/// 菜单栏面板上的更新那一行：有新版本时“更新到 x.y.z”，下载、安装时显示进度，失败时说原因、可以去 GitHub 下载
struct UpdateRow: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        switch updates.state {
        case .available(let release):
            MenuRow(title: Text("Update to \(release.version)", bundle: .module)) { updates.install() }
                .fontWeight(.semibold)
        case .downloading(let fraction):
            progress(Text("Downloading update… \(Format.percent(fraction))", bundle: .module))
        case .installing:
            progress(Text("Installing update…", bundle: .module))
        case .failed(let reason, let release):
            Text("Couldn’t update: \(reason)", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            if let release {
                MenuRow(title: Text("Update to \(release.version)", bundle: .module)) { updates.install() }
            }
            MenuRow(title: Text("Download from GitHub", bundle: .module)) { updates.openReleasePage() }
        case .idle, .checking:
            EmptyView()
        }
    }

    private func progress(_ title: Text) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            title.foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// App 菜单里的“检查更新…”
public struct UpdateCommands: Commands {
    let updates: UpdateController

    public init(updates: UpdateController) {
        self.updates = updates
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button { updates.checkFromMenu() } label: { Text("Check for Updates…", bundle: .module) }
        }
    }
}
