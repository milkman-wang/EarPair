import CryptoKit
import EarPairCore
import Foundation
import Testing

@Suite("更新")
struct UpdaterTests {
    @Test("版本比较：逐段按数字比，v 和预发布标记不算")
    func versionComparison() {
        #expect(Updater.isNewer("0.2.10", than: "0.2.9"))
        #expect(Updater.isNewer("v0.3.0", than: "0.2.1"))
        #expect(Updater.isNewer("1.0", than: "0.9.9"))
        #expect(Updater.isNewer("0.2.1.1", than: "0.2.1"))
        #expect(!Updater.isNewer("0.2.1", than: "0.2.1"))
        #expect(!Updater.isNewer("0.2.1-beta", than: "0.2.1"))
        #expect(!Updater.isNewer("0.2.0", than: "0.2.1"))
    }

    @Test("GitHub 的 releases/latest：找出 Mac 的 dmg、版本号和 SHA-256")
    func parsesRelease() throws {
        let json = """
        {"tag_name": "v0.2.2", "html_url": "https://github.com/milkman-wang/EarPair/releases/tag/v0.2.2",
         "draft": false, "prerelease": false, "assets": [
          {"name": "EarPair-0.2.2-win-x64-setup.exe", "size": 10,
           "browser_download_url": "https://example.com/win.exe", "digest": "sha256:aa"},
          {"name": "EarPair-0.2.2-macos-universal.dmg", "size": 2239111,
           "browser_download_url": "https://example.com/mac.dmg", "digest": "sha256:D9EAAC"}]}
        """
        let release = try Updater.parseRelease(Data(json.utf8))
        #expect(release.version == "0.2.2")
        #expect(release.dmg.absoluteString == "https://example.com/mac.dmg")
        #expect(release.size == 2_239_111)
        #expect(release.sha256 == "d9eaac")

        let windowsOnly = json.replacingOccurrences(of: "macos-universal.dmg", with: "other.zip")
        #expect(throws: UpdateError.noMacPackage) { try Updater.parseRelease(Data(windowsOnly.utf8)) }
        #expect(throws: UpdateError.badResponse) { try Updater.parseRelease(Data("{}".utf8)) }
    }

    @Test("下载：内容一致；大小或 SHA-256 不对就当作损坏")
    func downloadVerifiesChecksum() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("EarPair-9.9.9-macos-universal.dmg")
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try content.write(to: file)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let page = URL(string: "https://example.com")!

        let good = AppRelease(version: "9.9.9", page: page, dmg: file, size: content.count, sha256: digest)
        let downloaded = try await Updater.download(good)
        #expect(try Data(contentsOf: downloaded) == content)

        let tampered = AppRelease(version: "9.9.9", page: page, dmg: file, size: content.count, sha256: String(repeating: "0", count: 64))
        await #expect(throws: UpdateError.corrupted) { _ = try await Updater.download(tampered) }
    }

    @Test("从 dmg 里取出新版放到旧版旁边，App 退出后换上（真的 dmg、假的 App）")
    func stagesAndSwaps() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let applications = folder.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let target = applications.appendingPathComponent("EarPair.app")
        try makeApp(at: target, version: "0.2.1")

        let source = folder.appendingPathComponent("dmg-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(at: source.appendingPathComponent("EarPair.app"), version: "9.9.9")
        let dmg = folder.appendingPathComponent("EarPair-9.9.9-macos-universal.dmg")
        try shell("/usr/bin/hdiutil", "create", "-volname", "EarPair", "-srcfolder", source.path, "-fs", "HFS+",
                  "-format", "UDZO", "-ov", dmg.path)

        // 版本号不对：不要
        #expect(throws: UpdateError.invalidPackage) {
            try Updater.stage(dmg: dmg, expectedVersion: "9.9.8", beside: target)
        }
        let staged = try Updater.stage(dmg: dmg, expectedVersion: "9.9.9", beside: target)
        #expect(staged.deletingLastPathComponent().standardizedFileURL.path == applications.standardizedFileURL.path)
        #expect(version(of: staged) == "9.9.9")

        // 一个很快就退出的进程当作“正在运行的 App”
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.5"]
        try app.run()
        try Updater.swapAndRelaunch(staged: staged, target: target, pid: app.processIdentifier, relaunch: false)
        #expect(version(of: target) == "0.2.1")  // 还在运行：没换
        for _ in 0..<50 where version(of: target) != "9.9.9" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(version(of: target) == "9.9.9")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        #expect(leftovers == ["EarPair.app"])
    }

    @Test("真的去 GitHub：查最新版本、下载 Mac 的 dmg、取出 EarPair（要联网，设 EARPAIR_LIVE_UPDATE_TEST=1 才跑）",
          .enabled(if: ProcessInfo.processInfo.environment["EARPAIR_LIVE_UPDATE_TEST"] == "1"))
    func liveRelease() async throws {
        let release = try await Updater.fetchLatest()
        #expect(release.sha256 != nil)
        let dmg = try await Updater.download(release)
        defer { try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent()) }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("EarPair.app")
        try makeApp(at: target, version: "0.0.1")
        let staged = try Updater.stage(dmg: dmg, expectedVersion: release.version, beside: target)
        #expect(version(of: staged) == release.version)
        print("live: \(release.version) \(release.size) bytes, staged \(staged.lastPathComponent)")
    }

    // MARK: - 工具

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EarPairTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 一个能通过签名检查的假 App：可执行文件是 /usr/bin/true 的副本，本机临时签名
    private func makeApp(at url: URL, version: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macOS.appendingPathComponent("EarPair"))
        let info: NSDictionary = ["CFBundleIdentifier": "app.earpair.EarPair", "CFBundleShortVersionString": version,
                                  "CFBundleExecutable": "EarPair", "CFBundlePackageType": "APPL"]
        try info.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try shell("/usr/bin/codesign", "--force", "--sign", "-", url.path)
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private func shell(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " "))")
    }
}
