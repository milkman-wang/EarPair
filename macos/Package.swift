// swift-tools-version: 5.10
import PackageDescription

// 命令行工具没有 App 那样的 Info.plist，链接时塞一份进可执行文件：允许资源包按系统语言（或 --lang）自己选翻译。
// 不加的话，资源包只跟着可执行文件本身的语言走，而它没有任何本地化，结果永远是英文。
let toolInfoPlist: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                  "-Xlinker", Context.packageDirectory + "/Resources/Tools-Info.plist"]),
]

let package = Package(
    name: "EarPair",
    // 代码里的文字是英文；翻译在各 target 的 Resources/<语言>.lproj/Localizable.strings
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // 菜单栏 App（用 scripts/build-app.sh 打包成 EarPair.app）
        .executable(name: "EarPair", targets: ["EarPair"]),
        // 命令行接收端：调试、无界面运行、自动化测试
        .executable(name: "earpair-recv", targets: ["earpair-recv"]),
        // 把界面渲染成 PNG，用来检查设计
        .executable(name: "earpair-snapshot", targets: ["earpair-snapshot"]),
    ],
    targets: [
        .target(name: "EarPairCore", resources: [.process("Resources")]),
        .target(name: "EarPairUI", dependencies: ["EarPairCore"], resources: [.process("Resources")]),
        .executableTarget(name: "EarPair", dependencies: ["EarPairUI"]),
        .executableTarget(name: "earpair-recv", dependencies: ["EarPairCore"], linkerSettings: toolInfoPlist),
        .executableTarget(name: "earpair-snapshot", dependencies: ["EarPairUI"], linkerSettings: toolInfoPlist),
        .testTarget(name: "EarPairCoreTests", dependencies: ["EarPairCore"]),
    ]
)
