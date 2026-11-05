import AppKit
import EarPairCore
import SwiftUI

/// 主窗口的页面
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case overview, sound, network, connection

    public var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "概览"
        case .sound: return "声音"
        case .network: return "网络"
        case .connection: return "连接"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "waveform"
        case .sound: return "speaker.wave.2.fill"
        case .network: return "network"
        case .connection: return "link"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return .blue
        case .sound: return .pink
        case .network: return .green
        case .connection: return .orange
        }
    }
}

/// 主窗口：左边侧边栏选页面，右边是页面内容。macOS 26 起侧边栏和工具栏由系统渲染成 Liquid Glass。
public struct MainWindow: View {
    public static let id = "main"

    @ObservedObject var controller: ReceiverController
    @State private var selection: MainSection?

    public init(controller: ReceiverController, initialSection: MainSection = .overview) {
        self.controller = controller
        _selection = State(initialValue: initialSection)
    }

    public var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    SidebarIcon(symbol: section.symbol, tint: section.tint)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            let section = selection ?? .overview
            Group {
                switch section {
                case .overview: OverviewPane(controller: controller)
                case .sound: SoundPane(controller: controller)
                case .network: NetworkPane(controller: controller)
                case .connection: ConnectionPane(controller: controller)
                }
            }
            .navigationTitle(section.title)
        }
        .frame(minWidth: 740, minHeight: 500)
        // 窗口打开时出现在 Dock 和 ⌘Tab 里，关掉后回到只在菜单栏
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// 系统设置风格的侧边栏图标：彩色圆角方块里放白色符号
struct SidebarIcon: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
