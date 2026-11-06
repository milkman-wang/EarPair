using System.Reflection;
using System.Runtime.InteropServices;
using EarPair.App.Interop;
using EarPair.App.Services;
using EarPair.App.ViewModels;
using EarPair.Sender;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace EarPair.App;

/// <summary>
/// App：持有发送引擎、设置、Mac 发现和通知区域图标。通知区域图标是常驻入口；
/// 主窗口按需创建，关掉就销毁，EarPair 留在通知区域继续发送。
/// </summary>
public partial class App : Application
{
    public static readonly string Version =
        Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.2.0";

    private readonly bool _startInBackground;
    private DispatcherQueue? _dispatcher;
    private MainWindow? _window;
    private TrayIcon? _tray;
    private bool _refreshQueued;
    private bool _postMuteDismissed;
#if DEBUG
    private readonly Demo.Scene? _demo;
    private readonly ElementTheme _demoTheme;
#endif

    public SenderEngine Engine { get; } = new();
    public AppSettings Settings { get; }
    public MacDiscovery Discovery { get; } = new();

    /// <summary>界面上的发送开关</summary>
    public bool SwitchOn { get; private set; }

    /// <summary>引擎状态、设置或发现列表变了（在界面线程上）</summary>
    public event Action? StateChanged;

    /// <summary>系统的输出设备有增减（在界面线程上）</summary>
    public event Action? DevicesChanged;

    public static new App Current => (App)Application.Current;

    public App(bool startInBackground, string? demo = null, string? theme = null)
    {
        _startInBackground = startInBackground;
        Settings = AppSettings.Load();
#if DEBUG
        if (demo is not null && Demo.Create(demo) is { } scene)
        {
            _demo = scene;
            _demoTheme = theme == "dark" ? ElementTheme.Dark : theme == "light" ? ElementTheme.Light : ElementTheme.Default;
            Settings = new AppSettings { ReadOnly = true, Target = scene.Target, SenderId = "demo" };
            SwitchOn = scene.SwitchOn;
            AppLog.Enabled = false;
        }
#endif
        InitializeComponent();
        // 关掉窗口不退出：EarPair 留在通知区域，只有“退出”才真正结束
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        // 没接住的异常记进日志（含 HRESULT 和调用栈），方便事后排查
        UnhandledException += (_, e) => AppLog.Write(Strings.LogUnhandled(e.Exception.HResult, e.Exception));
        AppDomain.CurrentDomain.UnhandledException += (_, e) => AppLog.Write(Strings.LogUnhandledBackground(e.ExceptionObject));
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread();
#if DEBUG
        if (_demo is not null)
        {
            Discovery.ShowDemo(Demo.Macs);
            ShowMainWindow();
            _window?.SetTheme(_demoTheme);
            return;
        }
#endif
        AppLog.Prune();
        string architecture = RuntimeInformation.ProcessArchitecture.ToString(), os = Environment.OSVersion.VersionString;
        AppLog.Write(_startInBackground ? Strings.LogStartingAtLogin(Version, architecture, os)
                                        : Strings.LogStarting(Version, architecture, os));

        // 上次异常退出时留下的本机静音：恢复
        if (Settings.MutedByUs is { } leftover)
        {
            SenderEngine.RestoreLeftoverMute(leftover);
            Settings.MutedByUs = null;
            Settings.Save();
            AppLog.Write(Strings.LogRestoredMute);
        }
        Autostart.FixPath();

        _tray = new TrayIcon(Path.Combine(AppContext.BaseDirectory, "Assets")) { MenuProvider = TrayMenu };
        _tray.Activated += ShowMainWindow;
        _tray.SessionEnding += OnSessionEnding;

        Engine.Log += AppLog.Write;
        Engine.Changed += QueueRefresh;
        Engine.DevicesChanged += () => _dispatcher.TryEnqueue(() => DevicesChanged?.Invoke());
        Engine.MutedDeviceChanged += id => _dispatcher.TryEnqueue(() =>
        {
            Settings.MutedByUs = id;
            Settings.Save();
        });
        Engine.PostMuteDetected += id => _dispatcher.TryEnqueue(() =>
        {
            if (!Settings.PostMuteDevices.Contains(id)) Settings.PostMuteDevices.Add(id);
            _postMuteDismissed = false;
            Settings.Save();
            AppLog.Write(Strings.LogPostMuteDevice(id));
        });
        Engine.RemoteSeen += status => _dispatcher.TryEnqueue(() => OnRemoteSeen(status));
        Discovery.Changed += () => _dispatcher.TryEnqueue(OnDiscoveryChanged);
        Discovery.Start();

        // 上次退出时开关是开着的（比如开机自启）：继续发送
        if (Settings.Sending && Settings.Target is not null) StartSending();
        UpdateTray();

        if (!_startInBackground) ShowMainWindow();
    }

    // MARK: - 发送

    public void StartSending(bool ignoreSilence = false)
    {
        if (Settings.Target is not { } target) return;
        SwitchOn = true;
        Settings.Sending = true;
        Settings.Save();
        AppLog.Write(ignoreSilence ? Strings.LogStartSendingAnyway(target.Name, target.Host, target.Port)
                                   : Strings.LogStartSending(target.Name, target.Host, target.Port));
        Engine.Start(new SenderSettings(target.Host, target.Port, Settings.DeviceId)
        {
            MuteLocal = Settings.MuteLocal,
            PostMuteDevices = Settings.PostMuteDevices.ToHashSet(),
            SenderId = Settings.SenderId,
            SenderName = HostIdentity.Name,
            SenderKind = HostIdentity.Kind,
            App = Version,
            KnownToReply = target.KnownToReply,
            IgnoreSilence = ignoreSilence,
        });
        QueueRefresh();
    }

    public void StopSending()
    {
        SwitchOn = false;
        Settings.Sending = false;
        Settings.Save();
        AppLog.Write(Strings.LogStopSending);
        Engine.Stop();
        QueueRefresh();
    }

    /// <summary>选了一台 Mac：记住它，并开始发送</summary>
    public void SelectTarget(MacTarget target)
    {
        MacTarget? known = Settings.KnownMacs.FirstOrDefault(m => m.Matches(target));
        target.KnownToReply |= known?.KnownToReply == true;
        target.Kind ??= known?.Kind;
        Settings.Target = target;
        Settings.Remember(target);
        StartSending();
    }

    public void SelectDiscovered(DiscoveredMac mac) =>
        SelectTarget(new MacTarget { Id = mac.MacId, Name = mac.Name, Host = mac.Address, Port = mac.Port, Kind = mac.Kind });

    /// <summary>设置变了（设备、本机静音）：正在发送就按新设置重新开始</summary>
    public void ApplySettings()
    {
        Settings.Save();
        if (SwitchOn) StartSending();
        QueueRefresh();
    }

    public void DismissPostMuteNotice()
    {
        _postMuteDismissed = true;
        QueueRefresh();
    }

    public StatusView Status
    {
        get
        {
#if DEBUG
            if (_demo is { } scene)
                return StatusDescriber.Describe(scene.Snapshot, scene.SwitchOn, scene.Target, false, Demo.PcName, Demo.PcKind);
#endif
            return StatusDescriber.Describe(Engine.Snapshot, SwitchOn, Settings.Target, _postMuteDismissed);
        }
    }

    /// <summary>上次取过之后的峰值（0…1），界面用来算连线上光点的亮度</summary>
    public float TakePeak()
    {
#if DEBUG
        if (_demo is { } scene) return scene.Peak;
#endif
        (float left, float right) = Engine.TakePeaks();
        return Math.Max(left, right);
    }

    /// <summary>列表：记住的 Mac ∪ 正在看到的 Mac（看到的优先，用最新的地址）</summary>
    public IReadOnlyList<MacTarget> AvailableMacs()
    {
        var list = Discovery.Macs
            .Select(m => new MacTarget { Id = m.MacId, Name = m.Name, Host = m.Address, Port = m.Port, Kind = m.Kind })
            .ToList();
        foreach (MacTarget known in Settings.KnownMacs)
            if (!list.Any(m => m.Matches(known))) list.Add(known);
        if (Settings.Target is { } target && !list.Any(m => m.Matches(target))) list.Insert(0, target);
        return list;
    }

    /// <summary>菜单和按钮上 Mac 的名字：只写名字；两台重名时才在后面加 IP</summary>
    public static string MacTitle(MacTarget mac, IEnumerable<MacTarget> all)
    {
        static string NameOf(MacTarget m) => m.Name.Length > 0 ? m.Name : m.Host;
        string name = NameOf(mac);
        bool repeated = all.Any(m => NameOf(m) == name && !m.Matches(mac));
        return repeated ? Strings.NameWithAddress(name, mac.Host) : name;
    }

    private void OnRemoteSeen(StatusMessage status)
    {
        if (Settings.Target is not { } target) return;
        target.KnownToReply = true;
        if (string.IsNullOrEmpty(target.Id) && status.Id is { Length: > 0 }) target.Id = status.Id;
        if (status.Name is { Length: > 0 } name) target.Name = name;
        if (status.Kind is "laptop" or "desktop") target.Kind = status.Kind;
        Settings.Remember(target);
        Settings.Save();
        QueueRefresh();
    }

    /// <summary>Bonjour 报告了目标 Mac 的新地址（DHCP 换了 IP）：原地址没有回应时跟着换</summary>
    private void OnDiscoveryChanged()
    {
        if (Settings.Target is { Id: { Length: > 0 } id } target)
        {
            DiscoveredMac? seen = Discovery.Macs.FirstOrDefault(m => m.MacId == id);
            if (seen is not null && (seen.Address != target.Host || seen.Port != target.Port))
            {
                bool waiting = Engine.Snapshot.State is SenderState.WaitingForMac or SenderState.Failed ||
                               Engine.Snapshot.Health == RemoteHealth.NoResponse;
                if (waiting || !SwitchOn)
                {
                    AppLog.Write(Strings.LogAddressChanged(target.Name, target.Host, seen.Address));
                    target.Host = seen.Address;
                    target.Port = seen.Port;
                    target.Kind = seen.Kind ?? target.Kind;
                    Settings.Remember(target);
                    Settings.Save();
                    if (SwitchOn) StartSending();
                }
            }
        }
        QueueRefresh();
    }

    /// <summary>关机或注销：同步停止发送、恢复本机声音（下次开机电脑不会一直没声音）</summary>
    private void OnSessionEnding()
    {
        AppLog.Write(Strings.LogSessionEnding);
        Engine.StopAndWait(TimeSpan.FromSeconds(2));
        Settings.MutedByUs = null;
        Settings.Save();
    }

    // MARK: - 窗口

    public void ShowMainWindow()
    {
        if (_window is null)
        {
            _window = new MainWindow();
            _window.Closed += (_, _) => OnWindowClosed();
        }
        _window.ShowAndActivate();
    }

    /// <summary>第二次启动 EarPair 时（在其他线程上回调）把窗口叫出来。</summary>
    public void ShowMainWindowFromAnyThread() => _dispatcher?.TryEnqueue(ShowMainWindow);

    private void OnWindowClosed()
    {
        _window = null;
#if DEBUG
        if (_demo is not null)
        {
            Exit();
            return;
        }
#endif
        Settings.Save(); // 窗口大小
        if (!Settings.TrayHintShown)
        {
            Settings.TrayHintShown = true;
            Settings.Save();
            _tray?.ShowBalloon(Strings.BackgroundTitle, Strings.BackgroundText);
        }
    }

    public void Quit()
    {
        AppLog.Write(Strings.LogExit);
        Settings.Save();
        Discovery.Dispose();
        Engine.Dispose(); // 先停采集、恢复本机静音，再发 BYE
        Settings.MutedByUs = null;
        Settings.Save();
        _tray?.Dispose();
        _window?.Close();
        Exit();
    }

    // MARK: - 刷新

    /// <summary>合并刷新：引擎事件可能很密，界面线程上只排一次</summary>
    private void QueueRefresh()
    {
        if (_dispatcher is null) return;
        lock (this)
        {
            if (_refreshQueued) return;
            _refreshQueued = true;
        }
        _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            lock (this) _refreshQueued = false;
            UpdateTray();
            StateChanged?.Invoke();
        });
    }

    private void UpdateTray()
    {
        StatusView status = Status;
        _tray?.Update(status.TrayGlyph, status.TrayText);
    }

    private IReadOnlyList<TrayIcon.MenuItem?> TrayMenu()
    {
        StatusView status = Status;
        IReadOnlyList<MacTarget> macs = AvailableMacs();
        var targets = new List<TrayIcon.MenuItem?>();
        foreach (MacTarget mac in macs)
        {
            bool current = Settings.Target?.Matches(mac) == true;
            targets.Add(new TrayIcon.MenuItem(MacTitle(mac, macs), () => SelectTarget(mac), IsChecked: current));
        }
        if (targets.Count > 0) targets.Add(null);
        targets.Add(new TrayIcon.MenuItem(Strings.EnterAddressMenu, () =>
        {
            ShowMainWindow();
            _window?.ShowAddressDialog();
        }));

        return
        [
            new TrayIcon.MenuItem(Settings.Target is null ? Strings.TrayNoMac : status.TrayText.Split('\n').Last(),
                                  IsEnabled: false),
            null,
            SwitchOn
                ? new TrayIcon.MenuItem(Strings.StopSending, StopSending)
                : new TrayIcon.MenuItem(Strings.StartSending, () => StartSending(), IsEnabled: Settings.Target is not null),
            new TrayIcon.MenuItem(Strings.SendTo, Children: targets),
            new TrayIcon.MenuItem(Strings.MuteWhileSending, () =>
            {
                Settings.MuteLocal = !Settings.MuteLocal;
                ApplySettings();
            }, IsChecked: Settings.MuteLocal),
            null,
            new TrayIcon.MenuItem(Strings.OpenEarPair, ShowMainWindow, IsDefault: true),
            new TrayIcon.MenuItem(Strings.Exit, Quit),
        ];
    }
}
