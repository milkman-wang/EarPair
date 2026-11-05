// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EarPair",
    platforms: [.macOS(.v14)],
    products: [
        // 菜单栏 App（用 scripts/build-app.sh 打包成 EarPair.app）
        .executable(name: "EarPair", targets: ["EarPair"]),
        // 命令行接收端：调试、无界面运行、自动化测试
        .executable(name: "earpair-recv", targets: ["earpair-recv"]),
    ],
    targets: [
        .target(name: "EarPairCore"),
        .executableTarget(name: "EarPair", dependencies: ["EarPairCore"]),
        .executableTarget(name: "earpair-recv", dependencies: ["EarPairCore"]),
        .testTarget(name: "EarPairCoreTests", dependencies: ["EarPairCore"]),
    ]
)
