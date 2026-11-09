using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using EarPair.App.Interop;
using EarPair.App.Services;
using EarPair.App.ViewModels;
using EarPair.Sender;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics;

namespace EarPair.App;

/// <summary>发现列表里的一行：名字（只有两台 Mac 重名时才在后面加 IP）和图标</summary>
public sealed class MacListItem(DiscoveredMac mac, string title)
{
    public DiscoveredMac Mac { get; } = mac;
    public string Title { get; } = title;
    public string Glyph => StatusDescriber.MacGlyph(Mac.Kind);
}

/// <summary>主窗口：单页。上面是主卡片（状态、发送开关、路线、提示），下面四张设置卡。</summary>
public sealed partial class MainWindow : Window
{
    private readonly App _app = App.Current;
    private readonly DispatcherQueueTimer _meter;
    private bool _updating;
    private double _level = -120;
    private double _hold;
    private IReadOnlyList<AudioDeviceInfo> _devices = [];
    private RectInt32? _moreButtonRegion;
    private bool _closed;

    public MainWindow()
    {
        InitializeComponent();
        Title = "EarPair";
        if (MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop();
            Root.Background = new SolidColorBrush(Colors.Transparent);
        }
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "EarPair.ico"));
        double width = _app.Settings.WindowWidth >= 560 ? _app.Settings.WindowWidth : 680;
        double height = _app.Settings.WindowHeight >= 560 ? _app.Settings.WindowHeight : 700;
        WindowHelper.ResizeAndCenter(this, (int)width, (int)height);
        WindowHelper.SetMinimumSize(this, 560, 560);
        AppWindow.Changed += OnAppWindowChanged;
        AppTitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        MoreButton.LayoutUpdated += OnMoreButtonLayoutUpdated;

        // 只在有光点在走、窗口看得见时才取电平
        _meter = DispatcherQueue.CreateTimer();
        _meter.Interval = TimeSpan.FromMilliseconds(33);
        _meter.Tick += (_, _) => UpdateMeter();
        _app.StateChanged += Refresh;
        _app.DevicesChanged += RefreshDevices;
        Closed += (_, _) =>
        {
            // 窗口正在销毁：之后不再碰 AppWindow 和标题栏区域
            _closed = true;
            MoreButton.LayoutUpdated -= OnMoreButtonLayoutUpdated;
            AppWindow.Changed -= OnAppWindowChanged;
            _meter.Stop();
            _app.StateChanged -= Refresh;
            _app.DevicesChanged -= RefreshDevices;
        };

        RefreshDevices();
        Refresh();
    }

    public void ShowAndActivate()
    {
        AppWindow.Show();
        Activate();
        WindowHelper.BringToFront(this);
    }

    /// <summary>界面用指定的深浅色（--demo 截图用）</summary>
    public void SetTheme(ElementTheme theme)
    {
        if (Content is FrameworkElement root) root.RequestedTheme = theme;
    }

    /// <summary>
    /// 标题栏：右边给系统按钮留出位置（RightInset 是物理像素，要按缩放比例换算），
    /// “⋯”按钮那一块设成可点击区域，其余部分可以拖动窗口。
    /// </summary>
    private void OnMoreButtonLayoutUpdated(object? sender, object e) => UpdateTitleBarRegions();

    private void UpdateTitleBarRegions()
    {
        // 最小化时系统按钮的宽度（RightInset）是 0，照着设的话还原后“⋯”会躲到关闭按钮底下
        if (_closed || !IsShown || Content?.XamlRoot is not { } root || MoreButton.ActualWidth <= 0) return;
        double scale = root.RasterizationScale;
        double right = AppWindow.TitleBar.RightInset / scale;
        if (right > 0 && Math.Abs(AppTitleBar.Padding.Right - right) > 0.5) AppTitleBar.Padding = new Thickness(16, 0, right, 0);
        Rect bounds = MoreButton.TransformToVisual(null)
            .TransformBounds(new Rect(0, 0, MoreButton.ActualWidth, MoreButton.ActualHeight));
        var region = new RectInt32((int)Math.Round(bounds.X * scale), (int)Math.Round(bounds.Y * scale),
                                   (int)Math.Round(bounds.Width * scale), (int)Math.Round(bounds.Height * scale));
        if (_moreButtonRegion is { } previous && previous.Equals(region)) return;
        _moreButtonRegion = region;
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, [region]);
    }

    // MARK: - 刷新

    private void Refresh()
    {
        _updating = true;
        try
        {
            StatusView status = _app.Status;
            MacTarget? target = _app.Settings.Target;

            bool picking = status.Path is null;
            StatusRow.Visibility = picking ? Visibility.Collapsed : Visibility.Visible;
            Route.Visibility = picking ? Visibility.Collapsed : Visibility.Visible;
            Picker.Visibility = picking ? Visibility.Visible : Visibility.Collapsed;
            TargetRow.Visibility = picking ? Visibility.Collapsed : Visibility.Visible;

            StatusTitle.Text = status.Title;
            SendSwitch.IsOn = _app.SwitchOn;
            if (status.Path is { } path) Route.Apply(path, status.PathDescription);
            else RefreshPicker();
            ShowNotice(status.Notice);
            ShowUpdate();

            TargetButton.Content = target is null ? Strings.ChooseMac : App.MacTitle(target, _app.AvailableMacs());
            MuteSwitch.IsOn = _app.Settings.MuteLocal;
            SenderSnapshot snapshot = _app.Engine.Snapshot;
            string? device = snapshot.DeviceId ?? _app.Settings.DeviceId;
            // “静音后采不到”的名单是设备 loopback 时记下的；进程 loopback 不受静音影响，照样可以静音
            bool cannotMute = device is not null && !snapshot.ProcessLoopback && _app.Settings.PostMuteDevices.Contains(device);
            MuteSwitch.IsEnabled = !cannotMute;
            ToolTipService.SetToolTip(MuteSwitch, cannotMute ? Strings.CannotMuteDevice : null);
            StartupSwitch.IsOn = Autostart.IsEnabled;
            UpdateMeterTimer();
        }
        finally
        {
            _updating = false;
        }
    }

    private void ShowNotice(NoticeView? notice)
    {
        if (notice is null)
        {
            Notice.IsOpen = false;
            Notice.Visibility = Visibility.Collapsed;
            return;
        }
        Notice.Message = notice.Text;
        Notice.Severity = notice.Kind switch
        {
            NoticeKind.Warning => InfoBarSeverity.Warning,
            NoticeKind.Error => InfoBarSeverity.Error,
            _ => InfoBarSeverity.Informational,
        };
        Notice.IsClosable = notice.Closable;
        bool hasAction = notice.ActionText is not null;
        NoticeButton.Visibility = hasAction ? Visibility.Visible : Visibility.Collapsed;
        NoticeButton.Content = notice.ActionText;
        NoticeButton.Tag = notice.Action;
        Notice.Tag = notice.Action;
        Notice.Visibility = Visibility.Visible;
        Notice.IsOpen = true;
    }

    private void RefreshPicker()
    {
        IReadOnlyList<DiscoveredMac> macs = _app.Discovery.Macs;
        HashSet<string> repeated = macs.GroupBy(m => m.Name).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        MacList.ItemsSource = macs
            .Select(m => new MacListItem(m, repeated.Contains(m.Name) ? Strings.NameWithAddress(m.Name, m.Address)
                                                                      : m.Name))
            .ToList();
        bool done = _app.Discovery.EnumerationCompleted;
        PickerRing.Visibility = done ? Visibility.Collapsed : Visibility.Visible;
        PickerRing.IsActive = !done;
        RescanButton.Visibility = done ? Visibility.Visible : Visibility.Collapsed;
        MacList.Visibility = macs.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = done && macs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshDevices()
    {
        _updating = true;
        try
        {
            _devices = SenderEngine.ListDevices();
            AudioDeviceInfo? systemDefault = _devices.FirstOrDefault(d => d.IsDefault);
            var items = new List<string>
            {
                systemDefault is null ? Strings.SystemDefault : Strings.SystemDefaultDevice(systemDefault.Name),
            };
            items.AddRange(_devices.Select(d => d.Name));
            DeviceBox.ItemsSource = items;
            int index = _app.Settings.DeviceId is { } id ? _devices.ToList().FindIndex(d => d.Id == id) : -1;
            DeviceBox.SelectedIndex = index >= 0 ? index + 1 : 0;
        }
        finally
        {
            _updating = false;
        }
    }

    // MARK: - 电平

    /// <summary>窗口看得见：显示着并且没有最小化（最小化时 IsVisible 仍然是 true）</summary>
    private bool IsShown =>
        AppWindow.IsVisible && AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Minimized };

    private void UpdateMeterTimer()
    {
        if (_closed) return;
        if (Route.HasFlowing && IsShown)
        {
            _meter.Start();
            return;
        }
        _meter.Stop();
        _level = -120;
        Route.SetIntensity(0);
    }

    /// <summary>每 33 ms：取峰值，峰值保持 1 秒、每秒回落 24 dB（和 Mac 一致）；光点亮度 = (dB + 50) / 40</summary>
    private void UpdateMeter()
    {
        if (!IsShown)
        {
            UpdateMeterTimer(); // 最小化了：停掉定时器，光点熄灭（动画也跟着停）
            return;
        }
        float peak = _app.TakePeak();
        double db = peak > 0 ? 20 * Math.Log10(peak) : -120;
        const double dt = 0.033;
        if (db >= _level)
        {
            _level = db;
            _hold = 1.0;
        }
        else if (_hold > 0)
        {
            _hold -= dt;
        }
        else
        {
            _level = Math.Max(db, _level - 24 * dt);
        }
        Route.SetIntensity((float)Math.Clamp((_level + 50) / 40, 0, 1));
    }

    // MARK: - 操作

    private void OnSendToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        if (SendSwitch.IsOn) _app.StartSending();
        else _app.StopSending();
    }

    /// <summary>更新提示条：自动检查只在有新版本时出现；“正在检查”“已是最新”“检查失败”只回应手动检查</summary>
    private void ShowUpdate()
    {
        Updater updater = _app.Updater;
        string version = updater.Latest?.Version.ToString(3) ?? "";
        (string? title, string? message, InfoBarSeverity severity, string? action, bool closable) = updater.State switch
        {
            UpdateState.Available => (Strings.UpdateAvailableTitle(version), Strings.UpdateAvailableText,
                                      InfoBarSeverity.Informational, Strings.UpdateNow, true),
            UpdateState.Downloading => (null, Strings.UpdateDownloading(version, updater.Percent),
                                        InfoBarSeverity.Informational, null, false),
            UpdateState.Installing => (null, Strings.UpdateInstalling, InfoBarSeverity.Informational, null, false),
            UpdateState.DownloadFailed => (null, Strings.UpdateFailed(updater.Error ?? ""), InfoBarSeverity.Warning,
                                           Strings.Retry, true),
            UpdateState.Checking when updater.Manual => (null, Strings.CheckingForUpdates, InfoBarSeverity.Informational, null, false),
            UpdateState.UpToDate when updater.Manual => (null, Strings.UpToDate(App.Version), InfoBarSeverity.Success, null, true),
            UpdateState.CheckFailed => (null, Strings.UpdateCheckFailed(updater.Error ?? ""), InfoBarSeverity.Warning, null, true),
            _ => ((string?)null, (string?)null, InfoBarSeverity.Informational, (string?)null, false),
        };
        if (message is null || _app.UpdateBarDismissed)
        {
            UpdateBar.IsOpen = false;
            UpdateBar.Visibility = Visibility.Collapsed;
            return;
        }
        UpdateBar.Title = title ?? "";
        UpdateBar.Message = message;
        UpdateBar.Severity = severity;
        UpdateBar.IsClosable = closable;
        UpdateButton.Visibility = action is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateButton.Content = action;
        DownloadPageLink.Visibility = updater.State == UpdateState.DownloadFailed && updater.Latest is not null
            ? Visibility.Visible : Visibility.Collapsed;
        UpdateBar.Visibility = Visibility.Visible;
        UpdateBar.IsOpen = true;
    }

    private void OnUpdateAction(object sender, RoutedEventArgs e)
    {
        if (_app.Updater.State is UpdateState.Available or UpdateState.DownloadFailed) _app.InstallUpdate();
    }

    private void OnOpenDownloadPage(object sender, RoutedEventArgs e)
    {
        if (_app.Updater.Latest is not { PageUrl.Length: > 0 } release) return;
        try
        {
            // 经 explorer 打开：浏览器如果是 EarPair 直接启动的，就成了 EarPair 的子进程，
            // 进程 loopback 排除的是 EarPair 整个进程树，浏览器的声音就采不到了
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{release.PageUrl}\"") { UseShellExecute = false });
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            // 打不开浏览器就算了
        }
    }

    private void OnUpdateBarClosed(InfoBar sender, object args) => _app.DismissUpdateBar();

    private void OnCheckForUpdates(object sender, RoutedEventArgs e) => _app.CheckForUpdates(manual: true);

    private void OnNoticeAction(object sender, RoutedEventArgs e)
    {
        switch (NoticeButton.Tag)
        {
            case NoticeAction.SendAnyway:
                _app.StartSending(ignoreSilence: true);
                break;
            case NoticeAction.Retry:
                _app.StartSending();
                break;
        }
    }

    private void OnNoticeClosed(InfoBar sender, object args)
    {
        if (sender.Tag is NoticeAction.DismissPostMute) _app.DismissPostMuteNotice();
    }

    private void OnRescan(object sender, RoutedEventArgs e) => _app.Discovery.Restart();

    private void OnMacClicked(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is MacListItem item) _app.SelectDiscovered(item.Mac);
    }

    private async void OnEnterAddress(object sender, RoutedEventArgs e) => await ShowAddressDialogAsync();

    /// <summary>从通知区域菜单打开：窗口可能刚建好、内容还没加载（XamlRoot 还是 null），等加载完再弹</summary>
    public async void ShowAddressDialog()
    {
        if (Content is FrameworkElement { XamlRoot: null } root)
        {
            var loaded = new TaskCompletionSource();
            void OnLoaded(object sender, RoutedEventArgs e)
            {
                root.Loaded -= OnLoaded;
                loaded.TrySetResult();
            }
            root.Loaded += OnLoaded;
            await loaded.Task;
        }
        await ShowAddressDialogAsync();
    }

    private void OnOpenLogs(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(AppLog.Folder);
            Process.Start(new ProcessStartInfo { FileName = AppLog.Folder, UseShellExecute = true });
        }
        catch (Exception ex) when (ex is IOException or System.ComponentModel.Win32Exception)
        {
            // 打不开就算了
        }
    }

    private void OnQuit(object sender, RoutedEventArgs e) => _app.Quit();

    private void OnTargetMenuOpening(object? sender, object e)
    {
        TargetMenu.Items.Clear();
        IReadOnlyList<MacTarget> macs = _app.AvailableMacs();
        foreach (MacTarget mac in macs)
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = App.MacTitle(mac, macs),
                IsChecked = _app.Settings.Target?.Matches(mac) == true,
                GroupName = "mac",
            };
            item.Click += (_, _) => _app.SelectTarget(mac);
            TargetMenu.Items.Add(item);
        }
        if (TargetMenu.Items.Count > 0) TargetMenu.Items.Add(new MenuFlyoutSeparator());
        var enter = new MenuFlyoutItem { Text = Strings.EnterAddressMenu, Icon = new FontIcon { Glyph = "" } };
        enter.Click += async (_, _) => await ShowAddressDialogAsync();
        TargetMenu.Items.Add(enter);
    }

    /// <summary>菜单和按钮一样宽：默认按内容算宽度，比按钮窄，又是右对齐，左边会空出一截</summary>
    private void OnTargetButtonSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var style = new Style(typeof(MenuFlyoutPresenter));
        style.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, e.NewSize.Width));
        TargetMenu.MenuFlyoutPresenterStyle = style;
    }

    private void OnDeviceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updating || DeviceBox.SelectedIndex < 0) return;
        _app.Settings.DeviceId = DeviceBox.SelectedIndex == 0 ? null : _devices[DeviceBox.SelectedIndex - 1].Id;
        _app.ApplySettings();
    }

    private void OnMuteToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        _app.Settings.MuteLocal = MuteSwitch.IsOn;
        _app.ApplySettings();
    }

    private void OnStartupToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        Autostart.SetEnabled(StartupSwitch.IsOn);
    }

    private void OnAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        // 最小化、还原会改窗口位置和大小，不一定有 DidVisibilityChange
        if (args.DidVisibilityChange || args.DidSizeChange || args.DidPositionChange || args.DidPresenterChange)
            UpdateMeterTimer();
        if (args.DidSizeChange || args.DidPresenterChange)
        {
            UpdateTitleBarRegions();
            // 刚还原时系统按钮的宽度可能还没更新：排在这次布局之后再算一次
            DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, UpdateTitleBarRegions);
        }
        if (!args.DidSizeChange || !IsShown) return; // 最小化时的尺寸不记
        double scale = WindowHelper.Scale(this);
        _app.Settings.WindowWidth = Math.Round(sender.Size.Width / scale);
        _app.Settings.WindowHeight = Math.Round(sender.Size.Height / scale);
    }

    /// <summary>手动输入 Mac 的地址（IP 或主机名，xxx.local 也行），确认能解析再保存</summary>
    /// <summary>同一时间只能开一个 ContentDialog，再开会抛异常（没接住的话整个 App 就退出了）</summary>
    private bool _addressDialogOpen;

    private async Task ShowAddressDialogAsync()
    {
        if (_addressDialogOpen || Content?.XamlRoot is null) return;
        _addressDialogOpen = true;
        try
        {
            await RunAddressDialogAsync();
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException)
        {
            AppLog.Write(Strings.LogUnhandled(ex.HResult, ex));
        }
        finally
        {
            _addressDialogOpen = false;
        }
    }

    private async Task RunAddressDialogAsync()
    {
        var box = new TextBox { PlaceholderText = "192.168.1.20", Text = _app.Settings.Target?.Host ?? "" };
        // 用 XAML 建，颜色才能跟着主题走（文字在代码里设：译文里的引号会破坏 XAML）
        var error = (TextBlock)XamlReader.Load(
            "<TextBlock xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' " +
            "Visibility='Collapsed' Foreground='{ThemeResource SystemFillColorCriticalBrush}' />");
        error.Text = Strings.AddressNotFound;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = Strings.AddressDialogTitle,
            Content = new StackPanel { Spacing = 8, Children = { box, error } },
            PrimaryButtonText = Strings.Connect,
            CloseButtonText = Strings.Cancel,
            DefaultButton = ContentDialogButton.Primary,
            RequestedTheme = (Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            ContentDialogButtonClickDeferral deferral = args.GetDeferral();
            string host = box.Text.Trim();
            bool ok = host.Length > 0 && await Resolves(host);
            error.Visibility = ok ? Visibility.Collapsed : Visibility.Visible;
            args.Cancel = !ok;
            deferral.Complete();
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        string address = box.Text.Trim();
        MacTarget? known = _app.AvailableMacs()
            .FirstOrDefault(m => string.Equals(m.Host, address, StringComparison.OrdinalIgnoreCase));
        _app.SelectTarget(known ?? new MacTarget { Name = address, Host = address });
    }

    private static async Task<bool> Resolves(string host)
    {
        if (IPAddress.TryParse(host, out IPAddress? ip)) return ip.AddressFamily == AddressFamily.InterNetwork;
        try
        {
            IPAddress[] addresses = await Dns.GetHostAddressesAsync(host).WaitAsync(TimeSpan.FromSeconds(3));
            return addresses.Any(a => a.AddressFamily == AddressFamily.InterNetwork);
        }
        catch (Exception ex) when (ex is SocketException or TimeoutException or ArgumentException)
        {
            return false;
        }
    }
}
