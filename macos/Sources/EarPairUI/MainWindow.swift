import AppKit
import EarPairCore
import SwiftUI

/// 主窗口的页面
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case overview, sound, network, connection

    public var id: Self { self }

    var title: Text {
        switch self {
        case .overview: return Text("Overview", bundle: .module)
        case .sound: return Text("Sound", bundle: .module)
        case .network: return Text("Network", bundle: .module)
        case .connection: return Text("Connection", bundle: .module)
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

    /// 只往下传，自己不订阅：各页面自己订阅控制器，侧边栏和分栏不用跟着每次更新重算
    let controller: ReceiverController
    @State private var selection: MainSection?

    public init(controller: ReceiverController, initialSection: MainSection = .overview) {
        self.controller = controller
        _selection = State(initialValue: initialSection)
    }

    public var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $selection) { section in
                Label {
                    section.title
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
            .background { SidebarCollapseFix().frame(width: 0, height: 0) }
        }
        // 表单超过 1100 pt 宽以后，标签和数值之间全是空白：限制最大宽度（系统设置也是这样）
        .frame(minWidth: 760, idealWidth: 900, maxWidth: 1120, minHeight: 520, idealHeight: 640)
        // 窗口打开时出现在 Dock 和 ⌘Tab 里，关掉后回到只在菜单栏
        .onAppear {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            // 从“应用程序”冷启动时系统不会把只在菜单栏的 App 带到前台（那时还没有窗口）。窗口出来后还不在前台的话：
            // 先把窗口放到最前面，别被别的窗口挡住（激活请求是异步的，也可能被拒），再请求激活
            DispatchQueue.main.async {
                guard !NSApp.isActive else { return }
                NSApp.windows.first { $0.identifier?.rawValue == Self.id }?.orderFrontRegardless()
                NSApp.activate()
            }
        }
        .onDisappear {
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

/// 展开侧边栏时，系统默认的折叠方式（collapseBehavior = .default）会在动画里把右栏临时撑到
/// “窗口宽 + 侧边栏宽”，动画结束再缩回去，看起来跳一下；侧边栏按钮这时也放不下，被挤进右上角的“»”里。
/// 窗口宽到接近最大宽度时没有这个问题。改成按约束布局（.useConstraints）后两样都没有了，动画照旧（macOS 27.3 实测）。
/// SwiftUI 没有这个接口：顺着视图往上找到分栏，改它的侧边栏项。SwiftUI 建好分栏后会把这个值设回默认，
/// 所以盯着它，被改回去就再改过来。找不到分栏（SwiftUI 换了实现）就什么也不做。
/// 只在 macOS 26 起的浮动侧边栏上改：问题只在那里出现，也只在那里实测过。
struct SidebarCollapseFix: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.attach() }

    final class Probe: NSView {
        private weak var sidebar: NSSplitViewItem?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        /// 只是个探针，不接收点击
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func attach() {
            guard #available(macOS 26, *), window != nil else { return }
            var view = superview
            while let current = view, !(current is NSSplitView) { view = current.superview }
            guard let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }),
                  item !== sidebar else { return }
            sidebar = item
            item.collapseBehavior = .useConstraints
            observation = item.observe(\.collapseBehavior) { item, _ in
                MainActor.assumeIsolated {
                    if item.collapseBehavior != .useConstraints { item.collapseBehavior = .useConstraints }
                }
            }
        }
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
