using EarPair.App.Services;
using EarPair.Sender;

namespace EarPair.App.ViewModels;

/// <summary>托盘图标：未发送 / 发送中 / 有问题</summary>
public enum TrayGlyph { Idle, On, Warn }

/// <summary>路线上的节点：正常 / 占位（虚线圆，还没连上）/ 变暗（暂时不在工作）</summary>
public enum NodeLook { Normal, Placeholder, Dimmed }

/// <summary>连线的线型，和 Mac 端同一套</summary>
public enum LinkLook
{
    /// <summary>静止的点线：等待</summary>
    Waiting,
    /// <summary>向右流动的点线：正在连接</summary>
    Connecting,
    /// <summary>淡色实线：连着，没声音</summary>
    Quiet,
    /// <summary>实线加流动的光点，光点亮度跟着电平（没声音时看不见光点，和 Quiet 一样）</summary>
    Flowing,
    /// <summary>灰色实线：这一段没在用</summary>
    Inactive,
    /// <summary>黄色短划线，中间一个 ⚠：Mac 没有响应</summary>
    Warning,
    /// <summary>红色实线，中间一个 ✕：出错</summary>
    Failed,
}

public enum NoticeKind { Informational, Warning, Error }

/// <summary>提示条上按钮的动作</summary>
public enum NoticeAction { None, SendAnyway, Retry, DismissPostMute }

/// <summary>路线上的一个设备：图标、名字、样子；悬停提示放 IP、采集设备这类细节</summary>
public sealed record NodeView(string Glyph, string Name, NodeLook Look = NodeLook.Normal, string? ToolTip = null,
                              bool Muted = false);

/// <summary>路线：这台电脑 → Mac（→ Mac 的输出设备）。Output 为 null 时只画两个节点。</summary>
public sealed record PathView(NodeView Pc, LinkLook First, NodeView Mac, LinkLook Second, NodeView? Output);

public sealed record NoticeView(string Text, NoticeKind Kind, NoticeAction Action = NoticeAction.None,
                                string? ActionText = null, bool Closable = false);

/// <summary>Path 为 null：还没选 Mac，主卡片显示发现列表。</summary>
public sealed record StatusView(string Title, PathView? Path, NoticeView? Notice, TrayGlyph TrayGlyph, string TrayText)
{
    /// <summary>路线给屏幕阅读器的一句话（和 Mac 的 VoiceOver 文案一致）</summary>
    public string PathDescription { get; init; } = "";
}

/// <summary>把引擎状态翻译成界面：标题、路线、提示条、托盘。对照定稿里 Windows 主卡片的状态表，从上往下取第一条。</summary>
public static class StatusDescriber
{
    public const string DesktopGlyph = "";
    public const string LaptopGlyph = "";
    public const string MonitorGlyph = "";
    public const string HeadphonesGlyph = "";
    public const string SpeakersGlyph = "";

    public static string PcGlyph(string? kind) => kind == "laptop" ? LaptopGlyph : DesktopGlyph;

    /// <summary>Mac：台式机是显示器，笔记本或不知道是笔记本</summary>
    public static string MacGlyph(string? kind) => kind == "desktop" ? MonitorGlyph : LaptopGlyph;

    public static string OutputGlyph(string? transport) => transport switch
    {
        "bluetooth" or "headphones" => HeadphonesGlyph,
        "hdmi" => MonitorGlyph,
        _ => SpeakersGlyph,
    };

    /// <param name="pcName">这台电脑显示的名字；null 用 DNS 主机名（--demo 截图时换成通用的名字）</param>
    /// <param name="pcKind">这台电脑的类型（laptop / desktop）；null 用本机检测到的（--demo 截图时固定成台式机）</param>
    public static StatusView Describe(SenderSnapshot s, bool switchOn, MacTarget? target, bool postMuteDismissed,
                                      string? pcName = null, string? pcKind = null)
    {
        if (target is null)
            return new StatusView(Strings.ChooseMac, null, null, TrayGlyph.Idle, "EarPair");

        string mac = target.Name is { Length: > 0 } name ? name : target.Host;
        StatusMessage? remote = s.Remote;
        var pc = new NodeView(PcGlyph(pcKind ?? HostIdentity.Kind), pcName ?? HostIdentity.Name, ToolTip: s.DeviceName);
        var macNode = new NodeView(MacGlyph(remote?.Kind ?? target.Kind), mac, ToolTip: target.Host);
        NodeView? Output(bool muted = false) => remote?.Output is { Length: > 0 } output
            ? new NodeView(OutputGlyph(remote.Transport), output, Muted: muted)
            : null;
        PathView TwoNodes(LinkLook first, NodeView? pcNode = null, NodeView? macOverride = null) =>
            new(pcNode ?? pc, first, macOverride ?? macNode, LinkLook.Inactive, null);

        string title;
        PathView path;
        NoticeView? notice = null;
        TrayGlyph glyph;

        if (!switchOn || s.State == SenderState.Stopped)
        {
            title = Strings.StatusNotSending;
            path = TwoNodes(LinkLook.Waiting);
            glyph = TrayGlyph.Idle;
        }
        else
        {
            switch (s.State)
            {
                case SenderState.Failed:
                    title = Strings.StatusCantSend;
                    path = TwoNodes(LinkLook.Failed);
                    notice = new NoticeView(s.Error ?? Strings.SomethingWentWrong, NoticeKind.Error, NoticeAction.Retry,
                                            Strings.Retry);
                    glyph = TrayGlyph.Warn;
                    break;
                case SenderState.WaitingForDevice:
                    title = Strings.StatusNoSource;
                    path = TwoNodes(LinkLook.Inactive, pc with { Look = NodeLook.Dimmed });
                    glyph = TrayGlyph.Warn;
                    break;
                case SenderState.WaitingForMac when s.Health == RemoteHealth.Busy:
                    title = Strings.StatusMacBusy;
                    path = TwoNodes(LinkLook.Inactive);
                    notice = new NoticeView(Strings.BusyPlaying(remote?.BusyName), NoticeKind.Informational);
                    glyph = TrayGlyph.Idle;
                    break;
                case SenderState.WaitingForMac when s.Fresh:
                    title = Strings.StatusConnecting;
                    path = TwoNodes(LinkLook.Connecting);
                    glyph = TrayGlyph.On;
                    break;
                case SenderState.WaitingForMac:
                    title = Strings.StatusWaitingForMac;
                    path = TwoNodes(LinkLook.Waiting, macOverride: macNode with { Look = NodeLook.Placeholder });
                    notice = new NoticeView(Strings.ResumesWhenMacAvailable, NoticeKind.Informational, NoticeAction.SendAnyway,
                                            Strings.SendAnyway);
                    glyph = TrayGlyph.Idle;
                    break;
                case SenderState.Sending when s.Health == RemoteHealth.NoResponse:
                    title = Strings.StatusMacNotResponding;
                    path = TwoNodes(LinkLook.Warning);
                    notice = new NoticeView(s.PortUnreachable ? Strings.EarPairNotOpenOnMac : Strings.CantReachMac,
                                            NoticeKind.Warning);
                    glyph = TrayGlyph.Warn;
                    break;
                case SenderState.Sending when s.Standby:
                    // 电脑没有声音：只和 Mac 保持握手，不发音频（连线上没有光点）
                    title = Strings.StatusStandby;
                    path = new PathView(pc, LinkLook.Flowing, macNode, LinkLook.Flowing, Output(muted: remote?.Muted == true));
                    glyph = TrayGlyph.On;
                    break;
                case SenderState.Sending when remote is { IsPlaying: true, Muted: true }:
                    title = Strings.StatusMutedOnMac;
                    path = new PathView(pc, LinkLook.Flowing, macNode, LinkLook.Inactive, Output(muted: true));
                    glyph = TrayGlyph.On;
                    break;
                case SenderState.Sending when remote is { IsPlaying: true }:
                    title = Strings.StatusPlaying;
                    path = new PathView(pc, LinkLook.Flowing, macNode, LinkLook.Flowing, Output());
                    glyph = TrayGlyph.On;
                    break;
                case SenderState.Sending when s.Health == RemoteHealth.Ok:
                    // Mac 回了 STATUS，还在缓冲（或者还没开始收）
                    title = Strings.StatusConnecting;
                    path = new PathView(pc, LinkLook.Connecting, macNode, LinkLook.Inactive, Output());
                    glyph = TrayGlyph.On;
                    break;
                case SenderState.Sending when s.Fresh:
                    title = Strings.StatusConnecting;
                    path = TwoNodes(LinkLook.Connecting);
                    glyph = TrayGlyph.On;
                    break;
                case SenderState.Sending:
                    // Mac 是 0.1 版，不回传：只知道在发，不知道 Mac 在放什么
                    title = Strings.StatusSending;
                    path = TwoNodes(LinkLook.Flowing);
                    glyph = TrayGlyph.On;
                    break;
                default:
                    title = Strings.StatusNotSending;
                    path = TwoNodes(LinkLook.Waiting);
                    glyph = TrayGlyph.Idle;
                    break;
            }
        }

        if (notice is null && s.PostMuteFallback && !postMuteDismissed)
        {
            notice = new NoticeView(Strings.PostMuteNotice, NoticeKind.Informational,
                                    NoticeAction.DismissPostMute, Closable: true);
        }

        string description = path.Output is { } o
            ? Strings.PathDescriptionWithOutput(title, path.Pc.Name, path.Mac.Name, o.Name)
            : Strings.PathDescription(title, path.Pc.Name, path.Mac.Name);
        return new StatusView(title, path, notice, glyph, $"EarPair\n{title} · {mac}") { PathDescription = description };
    }
}
