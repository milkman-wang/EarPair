#if DEBUG
using EarPair.App.Services;
using EarPair.Sender;

namespace EarPair.App;

/// <summary>
/// --demo &lt;状态&gt; [--theme light|dark]：不创建引擎线程以外的任何东西（不采集、不托盘、不扫描、不写设置），
/// 用假数据把主窗口的各种状态画出来，在虚拟机里截图检查（相当于 Mac 的 earpair-snapshot）。只在 Debug 构建里有。
/// </summary>
internal static class Demo
{
    public sealed record Scene(SenderSnapshot Snapshot, bool SwitchOn, MacTarget? Target, float Peak);

    /// <summary>截图里用通用的名字，不带真实的电脑名；画成台式机，和 Mac 端 README 截图里的同一台电脑一致</summary>
    public const string PcName = "DESKTOP-PC";
    public const string PcKind = "desktop";

    public static readonly string[] Names =
        ["pick", "off", "connecting", "playing", "standby", "muted", "legacy", "noresponse", "waiting", "busy", "nosource", "failed", "postmute"];

    public static IEnumerable<DiscoveredMac> Macs =>
    [
        new("a", "MacBook Air", "192.168.1.199", 47800, "5f0e3c2a", "laptop"),
        new("b", "Mac mini", "192.168.1.42", 47800, "9b7d4e1f", "desktop"),
    ];

    public static Scene? Create(string name)
    {
        var mac = new MacTarget
        {
            Id = "5f0e3c2a", Name = "MacBook Air", Host = "192.168.1.199", Kind = "laptop", KnownToReply = true,
        };
        var settings = new SenderSettings(mac.Host);
        var playing = new StatusMessage
        {
            Name = mac.Name, Kind = "laptop", State = "playing", Output = "AirPods Pro", Transport = "bluetooth",
        };
        const float loud = 0.25f; // −12 dBFS

        SenderSnapshot Snapshot(SenderState state, RemoteHealth health = RemoteHealth.Unknown, StatusMessage? remote = null,
                                string? error = null, bool fresh = false, bool unreachable = false, bool postMute = false,
                                bool standby = false) =>
            new(state, error, "demo", "扬声器 (Realtek(R) Audio)", "48000 Hz，2 声道，32-bit 浮点", 48000, 2, 0, 0, 0, settings)
            {
                Health = health, Remote = remote, Fresh = fresh, PortUnreachable = unreachable, PostMuteFallback = postMute,
                Standby = standby,
            };

        return name switch
        {
            "pick" => new Scene(Snapshot(SenderState.Stopped), false, null, 0),
            "off" => new Scene(Snapshot(SenderState.Stopped), false, mac, 0),
            "connecting" => new Scene(Snapshot(SenderState.Sending, RemoteHealth.Ok, playing with { State = "buffering" }),
                                      true, mac, 0),
            "playing" => new Scene(Snapshot(SenderState.Sending, RemoteHealth.Ok, playing), true, mac, loud),
            "standby" => new Scene(Snapshot(SenderState.Sending, RemoteHealth.Ok, playing with { State = "standby" },
                                            standby: true), true, mac, 0),
            "muted" => new Scene(Snapshot(SenderState.Sending, RemoteHealth.Ok, playing with { Muted = true }), true, mac, loud),
            "legacy" => new Scene(Snapshot(SenderState.Sending), true,
                                  new MacTarget { Name = "MacBook-Pro.local", Host = "192.168.1.30" }, loud),
            "noresponse" => new Scene(Snapshot(SenderState.Sending, RemoteHealth.NoResponse, unreachable: true), true, mac, loud),
            "waiting" => new Scene(Snapshot(SenderState.WaitingForMac), true, mac, 0),
            "busy" => new Scene(Snapshot(SenderState.WaitingForMac, RemoteHealth.Busy,
                                         playing with { State = "busy", BusyName = "LAPTOP-Q8" }), true, mac, 0),
            "nosource" => new Scene(Snapshot(SenderState.WaitingForDevice), true, mac, 0),
            "failed" => new Scene(Snapshot(SenderState.Failed, error: "找不到 macbook-air.local"), true, mac, 0),
            "postmute" => new Scene(Snapshot(SenderState.Sending, RemoteHealth.Ok, playing, postMute: true), true, mac, loud),
            _ => null,
        };
    }
}
#endif
