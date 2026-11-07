import CryptoKit
import Foundation
import os

private let updateLog = Logger(subsystem: "app.earpair", category: "update")

/// GitHub 上发布的一个版本里 Mac 用的那个 dmg
public struct AppRelease: Equatable, Sendable {
    /// 去掉了 v 的版本号，比如 0.2.2
    public var version: String
    /// 发布页
    public var page: URL
    public var dmg: URL
    /// 字节数
    public var size: Int
    /// SHA-256（十六进制小写）；GitHub 没给时为 nil
    public var sha256: String?

    public init(version: String, page: URL, dmg: URL, size: Int, sha256: String?) {
        self.version = version
        self.page = page
        self.dmg = dmg
        self.size = size
        self.sha256 = sha256
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case badResponse
    case noMacPackage
    case download(String)
    case corrupted
    case invalidPackage
    case notWritable
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse:
            return String(localized: "GitHub returned something unexpected.", bundle: .module)
        case .noMacPackage:
            return String(localized: "This release has no Mac package.", bundle: .module)
        case .download(let reason):
            return String(localized: "The download failed: \(reason)", bundle: .module)
        case .corrupted:
            return String(localized: "The download is damaged.", bundle: .module)
        case .invalidPackage:
            return String(localized: "The package doesn’t contain a valid EarPair.", bundle: .module)
        case .notWritable:
            return String(localized: "EarPair can’t replace itself in this folder.", bundle: .module)
        case .install(let reason):
            return String(localized: "Installing failed: \(reason)", bundle: .module)
        }
    }
}

/// 更新：从 GitHub 发布页查最新版本，下载 Mac 的 dmg，校验大小和 SHA-256，挂载后把里面的 EarPair 复制到正在运行的那份旁边，
/// 检查 bundle id、版本号和签名完整，最后交给一个小脚本：等 App 退出后换上新的、再打开。
/// 发布页由 .github/workflows/release.yml 生成，dmg 名字是 EarPair-<版本>-macos-<平台>.dmg。
public enum Updater {
    public static let feed = URL(string: "https://api.github.com/repos/milkman-wang/EarPair/releases/latest")!

    /// 版本比较：按点分开的数字逐段比，0.2.10 比 0.2.9 新；前面的 v 和后面的预发布标记（-beta）不算
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
            let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 解析 GitHub 的 releases/latest
    public static func parseRelease(_ data: Data) throws -> AppRelease {
        struct Asset: Decodable {
            var name: String
            var size: Int
            var browser_download_url: URL
            var digest: String?
        }
        struct Release: Decodable {
            var tag_name: String
            var html_url: URL
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true else { throw UpdateError.badResponse }
        guard let asset = release.assets.first(where: {
            $0.name.hasPrefix("EarPair-") && $0.name.contains("-macos-") && $0.name.hasSuffix(".dmg")
        }) else { throw UpdateError.noMacPackage }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let sha256 = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return AppRelease(version: version, page: release.html_url, dmg: asset.browser_download_url,
                          size: asset.size, sha256: sha256)
    }

    public static func fetchLatest(from feed: URL = feed) async throws -> AppRelease {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.badResponse }
        return try parseRelease(data)
    }

    /// 下载到一个新的临时文件夹，边下边算 SHA-256；progress 是 0…1（任意线程）
    public static func download(_ release: AppRelease,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EarPair-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(release.dmg.lastPathComponent)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw UpdateError.download("can’t write") }
        defer { try? handle.close() }
        let bytes: URLSession.AsyncBytes
        do {
            let (stream, response) = try await URLSession.shared.bytes(from: release.dmg)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("HTTP \(http.statusCode)")
            }
            bytes = stream
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        var hasher = SHA256()
        var chunk = [UInt8]()
        chunk.reserveCapacity(1 << 16)
        var received = 0
        var reported = -1
        do {
            for try await byte in bytes {
                chunk.append(byte)
                guard chunk.count == 1 << 16 else { continue }
                received += chunk.count
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                let percent = release.size > 0 ? min(99, received * 100 / release.size) : 0
                if percent != reported {
                    reported = percent
                    progress(Double(percent) / 100)
                }
            }
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        received += chunk.count
        hasher.update(data: chunk)
        try handle.write(contentsOf: chunk)
        progress(1)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard received == release.size, release.sha256.map({ $0 == digest }) ?? true else {
            updateLog.error("下载的文件不对：\(received) 字节，SHA-256 \(digest, privacy: .public)")
            throw UpdateError.corrupted
        }
        return file
    }

    /// 挂载 dmg，把里面的 EarPair.app 复制到 target 旁边（同一个文件夹，换的时候只是改名），
    /// 检查 bundle id、版本号和签名完整。返回复制好的那份
    public static func stage(dmg: URL, expectedVersion: String, beside target: URL,
                             bundleID: String = "app.earpair.EarPair") throws -> URL {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: target.path) else { throw UpdateError.notWritable }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("EarPair-mount-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                     "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let source = mount.appendingPathComponent("EarPair.app")
        let staged = parent.appendingPathComponent(".EarPair-\(expectedVersion)-\(UUID().uuidString.prefix(8)).app")
        try run("/usr/bin/ditto", [source.path, staged.path])
        do {
            let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == bundleID,
                  info?["CFBundleShortVersionString"] as? String == expectedVersion else { throw UpdateError.invalidPackage }
            do {
                try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            } catch {
                throw UpdateError.invalidPackage
            }
            // 从网上下来的文件不能带隔离标记，不然打开时系统会拦
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// 交给一个小脚本：等进程 pid 退出，把 target 换成 staged（失败就放回原来的），再打开 target。
    /// 调用后应当马上退出 App
    public static func swapAndRelaunch(staged: URL, target: URL, pid: Int32 = getpid(), relaunch: Bool = true) throws {
        let script = """
        pid="$1"; target="$2"; staged="$3"; relaunch="$4"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
        backup="$target.old.$$"
        if mv "$target" "$backup"; then
          if mv "$staged" "$target"; then rm -rf "$backup"; else mv "$backup" "$target"; fi
        fi
        rm -rf "$staged"
        [ "$relaunch" = 1 ] && /usr/bin/open "$target"
        exit 0
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "earpair-update", String(pid), target.path, staged.path, relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
        updateLog.notice("交给脚本换上新版：\(staged.lastPathComponent, privacy: .public)")
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            updateLog.error("\(tool, privacy: .public) 失败：\(output, privacy: .public)")
            throw UpdateError.install("\((tool as NSString).lastPathComponent) \(process.terminationStatus)")
        }
        return output
    }
}
