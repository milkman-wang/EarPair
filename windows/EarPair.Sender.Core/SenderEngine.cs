using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace EarPair.Sender;

public enum SenderState
{
    /// <summary>没在发送</summary>
    Stopped,
    /// <summary>正在采集并发送</summary>
    Sending,
    /// <summary>
    /// 等 Mac：开始前先探测（确认过会回传的 Mac），或者发送中 Mac 10 秒没回应、正在放别的电脑的声音。
    /// 这时不采集、不静音本机，Mac 回来后自动开始
    /// </summary>
    WaitingForMac,
    /// <summary>采集设备不在（被拔掉、被停用，或者系统没有输出设备），设备回来后自动继续</summary>
    WaitingForDevice,
    /// <summary>出错了（见 Error），稍后自动重试</summary>
    Failed,
}

/// <summary>发送设置。DeviceId 为 null 表示跟随系统默认输出设备。</summary>
public sealed record SenderSettings(string Host, int Port = SenderEngine.DefaultPort, string? DeviceId = null,
                                    bool KeepAlive = true, int FramesPerPacket = 240)
{
    /// <summary>发送时把本机输出设备静音</summary>
    public bool MuteLocal { get; init; }
    /// <summary>这些设备静音后 loopback 也没声音，不静音它们</summary>
    public IReadOnlySet<string> PostMuteDevices { get; init; } = new HashSet<string>();
    /// <summary>发送端 id、名字和类型（控制包 HELLO 里用）</summary>
    public string SenderId { get; init; } = "";
    public string SenderName { get; init; } = HostIdentity.Name;
    public string SenderKind { get; init; } = HostIdentity.Kind;
    public string App { get; init; } = "0.2.1";
    /// <summary>以前确认过这台 Mac 会回 STATUS（Mac 0.2）：一开始就按“有回传”处理</summary>
    public bool KnownToReply { get; init; }
    /// <summary>不管 Mac 有没有回应都一直发（用户点了“仍然发送”）</summary>
    public bool IgnoreSilence { get; init; }
}

/// <summary>Mac 那边的情况（来自 STATUS）。</summary>
public enum RemoteHealth
{
    /// <summary>Mac 不回 STATUS（0.1 版），或者还没回过</summary>
    Unknown,
    /// <summary>最近 3 秒内收到过 STATUS</summary>
    Ok,
    /// <summary>3–10 秒没有 STATUS</summary>
    NoResponse,
    /// <summary>Mac 正在放别的电脑的声音</summary>
    Busy,
}

/// <summary>某一时刻的发送状态（不可变，可以直接交给界面线程）。</summary>
public sealed record SenderSnapshot(
    SenderState State,
    string? Error,
    string? DeviceId,
    string? DeviceName,
    string? FormatDescription,
    int SampleRate,
    int ChannelCount,
    long PacketsSent,
    long BytesSent,
    long SendErrors,
    SenderSettings? Settings)
{
    public RemoteHealth Health { get; init; }
    /// <summary>最近一次 STATUS（6 秒内没收到是 null）</summary>
    public StatusMessage? Remote { get; init; }
    /// <summary>Mac 开着但 EarPair 没在监听（最近 5 秒收到过“端口不可达”）</summary>
    public bool PortUnreachable { get; init; }
    /// <summary>本机输出设备现在是被我们静音的</summary>
    public bool LocalMuted { get; init; }
    /// <summary>这个设备静音后采集不到声音，已经恢复本机声音</summary>
    public bool PostMuteFallback { get; init; }
    /// <summary>刚开始或刚恢复（3 秒内）：界面显示“正在连接”，不急着下结论</summary>
    public bool Fresh { get; init; }
    /// <summary>待机：电脑没有声音，暂停发音频包，只和 Mac 保持握手（Sending 的一种情况）</summary>
    public bool Standby { get; init; }
    /// <summary>正在用进程 loopback 采集（不受输出设备静音影响，“静音后采不到”的名单不适用）</summary>
    public bool ProcessLoopback { get; init; }
}

public sealed record AudioDeviceInfo(string Id, string Name, bool IsDefault);

/// <summary>
/// 发送引擎：采集声音（跟随系统默认设备时采集除 EarPair 外所有程序的声音，指定了设备时只采那个设备），
/// 打包后用 UDP 发给 Mac，并和 Mac 交换控制包（名字、接收状态）。
/// 所有 WASAPI 对象都在引擎自己的一个 MTA 线程上创建和使用（WinUI 的界面线程是 STA，直接用会出 COM 套间问题），
/// 公开方法可以在任何线程调用。状态变化时触发 Changed（在引擎线程上），界面自己切回界面线程。
/// </summary>
public sealed class SenderEngine : IDisposable
{
    public const int DefaultPort = 47800;
    private static readonly TimeSpan TickInterval = TimeSpan.FromMilliseconds(250);
    private static readonly double[] RetryDelays = [1, 2, 5, 10];
    /// <summary>连续这么久没有声音就待机（秒）</summary>
    private const double StandbyAfter = 3;
    /// <summary>16-bit 峰值超过这个才算有声音（约 −80 dBFS）。没有程序在放声音时，loopback 采到的是全 0</summary>
    private const int SoundThreshold = 3;

    private readonly BlockingCollection<Action> _work = new();
    private readonly Thread _thread;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly Timer _ticker;
    private MMDeviceEnumerator? _enumerator;
    private DeviceNotifications? _notifications;

    // ---- 以下字段只在引擎线程上读写 ----
    private SenderSettings? _settings;
    private ICapture? _capture;
    /// <summary>当前这路采集是进程 loopback（跟随系统默认设备时用），否则是设备 loopback</summary>
    private bool _usingProcessLoopback;
    /// <summary>进程 loopback 激活失败过（系统太老等）：之后都用设备 loopback，不再每次重试</summary>
    private bool _processLoopbackUnavailable;
    private UdpSender? _udp;
    private (string Host, int Port)? _udpTarget;
    private PacketEncoder? _encoder;
    private LocalMute? _mute;
    private SenderState _state = SenderState.Stopped;
    private string? _error;
    private string? _deviceId;
    private string? _deviceName;
    private uint _streamId;
    private double _retryAt = double.PositiveInfinity;
    private int _retryCount;
    private double _nextHelloAt;
    private bool _replies;          // 这台 Mac 会回 STATUS
    private StatusMessage? _remote;
    private double _remoteAt = double.NegativeInfinity;
    private double _sendingSince;
    private double _unreachableAt = double.NegativeInfinity;
    private double _silentSince = double.NaN;
    private bool _postMuteFallback;
    private double _freshUntil = double.NegativeInfinity;
    /// <summary>刚开始等 Mac、或者刚联系不上 Mac 的这段时间里每秒探测一次，网络恢复后能马上接上</summary>
    private double _fastProbeUntil = double.NegativeInfinity;
    private double _mutedAt;
    private double _othersCheckedAt = double.NegativeInfinity;
    /// <summary>静音之后还采到过声音：这台设备静音不影响采集，不用再查</summary>
    private bool _muteVerified;
    /// <summary>进入待机时下一个包的序号（HELLO 里告诉 Mac）</summary>
    private uint _standbySeq;
    /// <summary>这个时间之前不待机：Mac 丢了这一路流，先照常发一会儿让它接上</summary>
    private double _activeUntil = double.NegativeInfinity;
    /// <summary>最近一次从待机恢复的时间</summary>
    private double _resumedAt = double.NegativeInfinity;

    // 待机：电脑没有声音时不发音频包、只发 HELLO。引擎线程决定进入待机，采集线程一有声音就自己恢复，
    // 两边在 _sendGate 里交接：进入待机前在锁里再确认一次没有声音，免得刚有声音就被停掉
    private readonly object _sendGate = new();
    private volatile bool _standby;
    /// <summary>最近一次采到声音的时间（Stopwatch 时间戳，采集线程写）</summary>
    private long _lastSoundAt;
    /// <summary>最近一次采到数据的时间（不管有没有声音）</summary>
    private long _lastCaptureAt;

    // 采集线程写、任意线程读
    private float _peakLeft;
    private float _peakRight;
    private float _peakForMuteCheck;
    private volatile SenderSnapshot _snapshot = new(SenderState.Stopped, null, null, null, null, 0, 0, 0, 0, 0, null);

    /// <summary>状态、设备、错误或 Mac 回传变化时触发（在引擎线程上）。</summary>
    public event Action? Changed;

    /// <summary>系统的输出设备有增减、默认设备变了（在引擎线程上）。界面据此刷新设备列表。</summary>
    public event Action? DevicesChanged;

    /// <summary>被我们静音的设备变了（null = 没有）。App 记下来，异常退出后下次启动能恢复。</summary>
    public event Action<string?>? MutedDeviceChanged;

    /// <summary>发现某个设备静音后采集不到声音。App 记下来，以后不再静音它。</summary>
    public event Action<string>? PostMuteDetected;

    /// <summary>第一次收到这台 Mac 的 STATUS（App 记下“这台 Mac 会回传”）。</summary>
    public event Action<StatusMessage>? RemoteSeen;

    /// <summary>值得写进日志的事：状态切换、设备和格式、错误（在引擎线程上）。</summary>
    public event Action<string>? Log;

    public SenderEngine()
    {
        _thread = new Thread(RunLoop) { IsBackground = true, Name = "EarPair 发送引擎" };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
        Post(() =>
        {
            _enumerator = new MMDeviceEnumerator();
            _notifications = new DeviceNotifications(this);
            _enumerator.RegisterEndpointNotificationCallback(_notifications);
        });
        // 只在开关打开时走（Start 里打开、StopNow 里关掉）
        _ticker = new Timer(_ => Post(OnTick), null, Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>当前状态；计数器部分实时读取。</summary>
    public SenderSnapshot Snapshot
    {
        get
        {
            SenderSnapshot s = _snapshot;
            UdpSender? udp = _udp;
            return udp is null ? s : s with { PacketsSent = udp.PacketsSent, BytesSent = udp.BytesSent, SendErrors = udp.SendErrors };
        }
    }

    /// <summary>取出上次调用以来左右声道的峰值（0…1），并清零。界面定时调用来画电平表。</summary>
    public (float Left, float Right) TakePeaks() =>
        (Interlocked.Exchange(ref _peakLeft, 0), Interlocked.Exchange(ref _peakRight, 0));

    /// <summary>
    /// 开始发送；已经在发送时按新设置重新开始。
    /// 确认过会回传的 Mac 先探测：Mac 回了 STATUS 才开始采集、静音本机（开机自启时 Mac 不在，本机不会白白被静音）。
    /// </summary>
    public void Start(SenderSettings settings) => Post(() =>
    {
        SetTicking(true);
        bool targetChanged = _settings is null || _settings.Host != settings.Host || _settings.Port != settings.Port;
        if (targetChanged)
        {
            // 先停采集，再跟旧的 Mac 告别
            TearDown();
            SendBye(ByeReason.User);
        }
        _settings = settings;
        if (targetChanged)
        {
            _replies = settings.KnownToReply;
            _remote = null;
            _remoteAt = double.NegativeInfinity;
        }
        _retryCount = 0;
        _freshUntil = Now + 3;
        bool heardRecently = Now - _remoteAt < 3 && _remote is { IsBusy: false };
        if (_replies && !settings.IgnoreSilence && !heardRecently) Probe(settings);
        else Restart();
    });

    public void Stop() => Post(StopNow);

    /// <summary>
    /// 停止并等它做完（最多 timeout）：关机或注销时用，本机静音要在进程被结束之前恢复。
    /// </summary>
    public bool StopAndWait(TimeSpan timeout)
    {
        var done = new ManualResetEventSlim();
        Post(() =>
        {
            StopNow();
            done.Set();
        });
        return done.Wait(timeout);
    }

    /// <summary>列出当前可用的输出设备（在调用线程上枚举，任何线程都可以）。</summary>
    public static IReadOnlyList<AudioDeviceInfo> ListDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        try
        {
            defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
        }
        catch (COMException)
        {
            // 系统没有输出设备
        }
        return enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
            .Select(d => new AudioDeviceInfo(d.ID, d.FriendlyName, d.ID == defaultId))
            .ToList();
    }

    /// <summary>上次异常退出时留下的本机静音：恢复它。</summary>
    public static void RestoreLeftoverMute(string deviceId) => LocalMute.RestoreLeftover(deviceId);

    // MARK: - 引擎线程

    private double Now => _clock.Elapsed.TotalSeconds;

    private void SetTicking(bool on)
    {
        try
        {
            TimeSpan period = on ? TickInterval : Timeout.InfiniteTimeSpan;
            _ticker.Change(period, period);
        }
        catch (ObjectDisposedException)
        {
            // 正在退出
        }
    }

    private void StopNow()
    {
        SetTicking(false);
        TearDown();
        SendBye(ByeReason.User);
        _settings = null;
        ReleaseSocket();
        SetState(SenderState.Stopped, null);
    }

    /// <summary>先探测：只发 HELLO(stream=0)，不采集、不静音，等 Mac 回 STATUS。</summary>
    private void Probe(SenderSettings settings)
    {
        TearDown();
        SendBye(ByeReason.Network);
        _fastProbeUntil = Now + 30;
        try
        {
            EnsureSocket(settings);
        }
        catch (Exception ex) when (ex is System.Net.Sockets.SocketException or ArgumentException)
        {
            SetState(SenderState.Failed, CoreStrings.HostNotFound(settings.Host));
            ScheduleRetry();
            return;
        }
        _nextHelloAt = 0;
        SetState(SenderState.WaitingForMac, null);
        OnTick();
    }

    private void Post(Action action)
    {
        try
        {
            _work.Add(action);
        }
        catch (InvalidOperationException)
        {
            // 引擎已经关闭
        }
    }

    private void RunLoop()
    {
        foreach (Action action in _work.GetConsumingEnumerable())
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                TearDown();
                ReleaseSocket();
                SetState(SenderState.Failed, ex.Message);
                ScheduleRetry();
            }
        }
    }

    /// <summary>按当前设置（重新）开始采集。</summary>
    private void Restart()
    {
        TearDown();
        if (_settings is not { } settings || _enumerator is null) return;

        try
        {
            EnsureSocket(settings);
        }
        catch (Exception ex) when (ex is System.Net.Sockets.SocketException or ArgumentException)
        {
            SetState(SenderState.Failed, CoreStrings.HostNotFound(settings.Host));
            ScheduleRetry();
            return;
        }

        MMDevice? device = FindDevice(settings.DeviceId);
        if (device is null)
        {
            SetState(SenderState.WaitingForDevice, null);
            return;
        }

        try
        {
            _capture = CreateCapture(device, settings);
            _streamId = (uint)Random.Shared.NextInt64(1, uint.MaxValue);
            _encoder = new PacketEncoder(_capture.SampleRate, settings.FramesPerPacket, _streamId);
            ICapture capture = _capture;
            PacketEncoder encoder = _encoder;
            UdpSender udp = _udp!;
            lock (_sendGate) _standby = false;
            Volatile.Write(ref _lastSoundAt, Stopwatch.GetTimestamp()); // 开始后至少发 StandbyAfter 秒
            _activeUntil = double.NegativeInfinity;
            capture.FramesCaptured += (samples, frames) =>
            {
                bool sound = UpdatePeak(samples, frames) > SoundThreshold;
                bool resumed = false;
                lock (_sendGate)
                {
                    long now = Stopwatch.GetTimestamp();
                    Volatile.Write(ref _lastCaptureAt, now);
                    if (sound)
                    {
                        Volatile.Write(ref _lastSoundAt, now);
                        resumed = _standby;
                        _standby = false;
                    }
                    // 待机时没声音就不发（Mac 知道，不当成断开）；有声音了这一批接着发，不等引擎线程
                    if (!_standby) encoder.Append(samples.AsSpan(0, frames * 2), udp.Send);
                }
                if (resumed) Post(() => OnResumed(encoder));
            };
            capture.Stopped += ex => Post(() => OnCaptureStopped(capture, ex));
            _deviceId = device.ID;
            _deviceName = device.FriendlyName;
            Log?.Invoke(_usingProcessLoopback
                ? CoreStrings.LogCaptureAllApps(capture.FormatDescription, _streamId)
                : CoreStrings.LogCaptureStarted(device.FriendlyName, capture.FormatDescription, _streamId));
            capture.Start();
            _retryCount = 0;
            _sendingSince = Now;
            _nextHelloAt = 0; // 立即发 HELLO
            ApplyLocalMute(device, settings);
            SetState(SenderState.Sending, null);
            OnTick();
        }
        catch (Exception ex) when (ex is COMException or NotSupportedException or InvalidOperationException)
        {
            TearDown();
            SetState(SenderState.Failed, Describe(ex));
            ScheduleRetry();
        }
    }

    private void EnsureSocket(SenderSettings settings)
    {
        if (_udp is not null && _udpTarget == (settings.Host, settings.Port)) return;
        ReleaseSocket();
        var udp = new UdpSender(settings.Host, settings.Port, receive: true);
        // 换了 Mac 以后，旧套接字上还在路上的包不算新 Mac 的
        udp.ControlReceived += packet => Post(() =>
        {
            if (ReferenceEquals(udp, _udp)) OnControl(packet);
        });
        udp.PortUnreachable += () => Post(() =>
        {
            if (!ReferenceEquals(udp, _udp)) return;
            _unreachableAt = Now;
            Publish();
        });
        _udp = udp;
        _udpTarget = (settings.Host, settings.Port);
    }

    /// <summary>
    /// 跟随系统默认设备时用进程 loopback（采集除 EarPair 外所有程序的声音，不受输出设备静音和音量影响）；
    /// 用户指定了某个设备时只采那个设备（设备 loopback），和以前一样。进程 loopback 用不了就退回设备 loopback。
    /// </summary>
    private ICapture CreateCapture(MMDevice device, SenderSettings settings)
    {
        _usingProcessLoopback = false;
        if (settings.DeviceId is null && !_processLoopbackUnavailable)
        {
            try
            {
                var capture = new ProcessLoopbackCapture(settings.KeepAlive ? device : null);
                _usingProcessLoopback = true;
                return capture;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                _processLoopbackUnavailable = true;
                Log?.Invoke(CoreStrings.LogProcessLoopbackUnavailable(Describe(ex)));
            }
        }
        return new AudioCapture(device, settings.KeepAlive);
    }

    private MMDevice? FindDevice(string? id)
    {
        try
        {
            if (id is null) return _enumerator!.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            MMDevice device = _enumerator!.GetDevice(id);
            return device.State == DeviceState.Active ? device : null;
        }
        catch (COMException)
        {
            return null; // 没有默认设备，或者指定的设备已经不存在
        }
    }

    /// <summary>采集意外停止（设备被拔掉、被停用、格式被改）：换到新的默认设备，或者等设备回来。</summary>
    private void OnCaptureStopped(ICapture capture, Exception? ex)
    {
        if (capture != _capture || _settings is null) return; // 是我们自己停的
        TearDown();
        SendBye(ByeReason.Device); // Mac 显示“已停止”并说明是设备断开，不当成网络问题
        _retryAt = Now + (ex is null ? 1.0 : 0.5);
        SetState(SenderState.WaitingForDevice, null);
    }

    private void ScheduleRetry()
    {
        _retryAt = Now + RetryDelays[Math.Min(_retryCount, RetryDelays.Length - 1)];
        _retryCount++;
    }

    private void OnDevicesChanged(string? defaultDeviceId)
    {
        DevicesChanged?.Invoke();
        if (_settings is not { } settings) return;
        bool follow = settings.DeviceId is null;
        if (_state == SenderState.Sending && follow && defaultDeviceId is not null && defaultDeviceId != _deviceId)
            Restart(); // 跟随默认设备：系统换了默认输出设备
        else if (_state is SenderState.WaitingForDevice or SenderState.Failed)
            Restart(); // 等的设备可能回来了
    }

    // MARK: - 控制包

    private void OnControl(byte[] packet)
    {
        StatusMessage? status = ControlPacket.ParseStatus(packet);
        if (status is null || _settings is null) return;
        bool first = !_replies;
        _replies = true;
        _remote = status;
        _remoteAt = Now;
        if (first) RemoteSeen?.Invoke(status);

        if (first) Log?.Invoke(CoreStrings.LogMacResponded(status.Name, status.App));

        if (_standby && _state == SenderState.Sending && !status.IsBusy)
        {
            if (!status.SupportsStandby || status.IsIdle) WakeForMac();
            else if (status.Stream == _streamId && (status.IsPlaying || status.IsBuffering))
                _nextHelloAt = 0; // Mac 还没收到待机的 HELLO（丢了）：下一次 tick 马上补发
        }

        if (status.IsBusy)
        {
            if (_state == SenderState.Sending) Pause(ByeReason.Busy);
        }
        else if (_state == SenderState.WaitingForMac)
        {
            _freshUntil = Now + 3;
            Restart(); // Mac 回来了，或者不忙了
            return;
        }
        Publish();
    }

    /// <summary>每 250 ms：发 HELLO、检查 Mac 的回应、重试、本机静音检查。</summary>
    private void OnTick()
    {
        if (_settings is not { } settings) return;
        double now = Now;

        if (_state is SenderState.Failed or SenderState.WaitingForDevice && now >= _retryAt)
        {
            _retryAt = double.PositiveInfinity;
            Restart();
            return;
        }

        if (_state is SenderState.Sending or SenderState.WaitingForMac && now >= _nextHelloAt && _udp is not null)
        {
            SendHello(settings);
            // 待机时没有音频包，Mac 只能靠 HELLO 知道我们还在：每秒一次，丢几个也不会被当成断开
            _nextHelloAt = now + (_state == SenderState.Sending ? (_standby ? 1 : 2) : now < _fastProbeUntil ? 1 : 3);
        }

        if (_state == SenderState.Sending && _replies && !settings.IgnoreSilence)
        {
            // 开始发送后先给 Mac 几秒钟回应
            double silence = now - Math.Max(_remoteAt, _sendingSince);
            if (silence > 10) Pause(ByeReason.Network);
        }

        if (_state == SenderState.Sending)
        {
            CheckPostMuteCapture(now);
            EnterStandbyIfSilent(now, settings);
        }
        Publish();
    }

    /// <summary>HELLO：我是谁、在发哪个流；待机时带上 standby 和恢复后第一个包的序号</summary>
    private void SendHello(SenderSettings settings)
    {
        if (_udp is null) return;
        bool sending = _state == SenderState.Sending;
        var hello = new HelloMessage(settings.SenderId, settings.SenderName, settings.SenderKind, settings.App,
                                     sending ? _streamId : 0);
        if (sending && _standby) hello = hello with { Standby = true, Seq = _standbySeq };
        _udp.SendControl(ControlPacket.Encode(hello));
    }

    // MARK: - 待机

    /// <summary>
    /// 连续 StandbyAfter 秒没有声音、Mac 也认得待机：停发音频包，只发 HELLO（带 standby）。
    /// 省电省流量：没声音时不再每秒发 200 个全是 0 的包。有声音时采集线程自己恢复（见 Restart 里的回调）。
    /// </summary>
    private void EnterStandbyIfSilent(double now, SenderSettings settings)
    {
        if (_standby || now < _activeUntil || _encoder is not { } encoder) return;
        // Mac 刚回过 STATUS（3 秒内）、认得待机、而且确实在收这一路流，才待机。
        // 旧版 Mac、刚换的 Mac 还没回过、或者 Mac 收不了我们的流时一直发，不来回切换
        if (_remote is not { SupportsStandby: true } remote || now - _remoteAt > 3 || remote.Stream != _streamId ||
            !(remote.IsPlaying || remote.IsBuffering || remote.IsStandby)) return;
        lock (_sendGate)
        {
            if (_standby || Stopwatch.GetElapsedTime(Volatile.Read(ref _lastSoundAt)).TotalSeconds < StandbyAfter) return;
            _standby = true;
            _standbySeq = encoder.NextSequence;
        }
        // 先告诉 Mac（它只剩 60 ms 缓冲），再写日志；下一个 tick 再发一份，丢一个也不要紧
        SendHello(settings);
        _nextHelloAt = now + 0.25;
        Log?.Invoke(CoreStrings.LogStandby);
        Publish();
    }

    /// <summary>待机中又有声音了（采集线程已经接着发包）：马上发 HELLO，界面也跟着变</summary>
    private void OnResumed(PacketEncoder encoder)
    {
        if (encoder != _encoder || _settings is null || _state != SenderState.Sending) return;
        _resumedAt = Now;
        // 下一个 tick 再发 HELLO：那时 Mac 已经攒够 60 ms 缓冲，回的是“正在播放”而不是“缓冲中”
        _nextHelloAt = Now + 0.25;
        Log?.Invoke(CoreStrings.LogResumed);
        Publish();
    }

    /// <summary>
    /// 待机中 Mac 说它没有这一路流（比如 Mac 上的 EarPair 重新打开过），或者不再认得待机：
    /// 退出待机，先照常发 1 秒（静音也发），Mac 接上之后再待机。采集没有数据（没有静音保活）时发了也没用，不折腾
    /// </summary>
    private void WakeForMac()
    {
        if (Stopwatch.GetElapsedTime(Volatile.Read(ref _lastCaptureAt)).TotalSeconds > 0.5) return;
        lock (_sendGate) _standby = false;
        _activeUntil = Now + 1;
        Log?.Invoke(CoreStrings.LogWakeForMac);
        Publish();
    }

    /// <summary>
    /// 暂停等 Mac：先停采集（本机恢复出声，电脑可以睡眠），再发 BYE，之后继续发 HELLO 探测。
    /// 因为联系不上 Mac 而暂停时，头 30 秒每秒探测一次，网络恢复后很快就能接上。
    /// </summary>
    private void Pause(string reason)
    {
        TearDown();
        SendBye(reason);
        bool network = reason == ByeReason.Network;
        if (network) _fastProbeUntil = Now + 30;
        _nextHelloAt = Now + (network ? 1 : 3);
        Log?.Invoke(network ? CoreStrings.LogPausedNoResponse : CoreStrings.LogPausedBusy);
        SetState(SenderState.WaitingForMac, null);
    }

    /// <summary>告诉 Mac 这一路流结束了，以及为什么。只在 Sending 时发；调用前先 TearDown（TearDown 不改 _state）。</summary>
    private void SendBye(string reason)
    {
        if (_udp is null || _state != SenderState.Sending) return;
        byte[] bye = ControlPacket.Encode(new ByeMessage(_streamId, reason));
        _udp.SendControl(bye);
        _udp.SendControl(bye);
    }

    // MARK: - 本机静音

    private void ApplyLocalMute(MMDevice device, SenderSettings settings)
    {
        _postMuteFallback = false;
        _silentSince = double.NaN;
        _muteVerified = false;
        string name = device.FriendlyName;
        if (!settings.MuteLocal)
        {
            Log?.Invoke(CoreStrings.LogMuteOff);
            return;
        }
        if (settings.PostMuteDevices.Contains(device.ID))
        {
            // 这份名单是设备 loopback 时记下的（静音后设备 loopback 只剩静音）；进程 loopback 不受静音影响，照样静音
            if (!_usingProcessLoopback)
            {
                Log?.Invoke(CoreStrings.LogMuteSkipped(name));
                return;
            }
            Log?.Invoke(CoreStrings.LogMuteRememberedButProcessLoopback(name));
        }
        _mute = new LocalMute(device);
        _mute.UserUnmuted += () => Post(() => Log?.Invoke(CoreStrings.LogUserUnmuted(name)));
        _mutedAt = Now;
        switch (_mute.Mute())
        {
            case MuteResult.Muted:
                Log?.Invoke(CoreStrings.LogMuted(name));
                MutedDeviceChanged?.Invoke(device.ID);
                break;
            case MuteResult.AlreadyMuted:
                Log?.Invoke(CoreStrings.LogAlreadyMuted(name));
                break;
            case MuteResult.Failed:
                Log?.Invoke(CoreStrings.LogMuteFailed(name));
                break;
        }
    }

    /// <summary>
    /// 有的声卡在静音之后才取 loopback：静音后别的程序明明在放声音，我们却只采到静音。
    /// 连续 2 秒这样，就取消静音、记住这个设备，以后不再静音它。
    /// </summary>
    private void CheckPostMuteCapture(double now)
    {
        float ours = Interlocked.Exchange(ref _peakForMuteCheck, 0);
        if (_mute is not { MutedByUs: true } mute || _muteVerified) return;
        if (ours > 1e-5f)
        {
            // 静音之后还采得到声音：这台设备没问题，之后不用再查
            if (now - _mutedAt > 1)
            {
                _muteVerified = true;
                Log?.Invoke(CoreStrings.LogMuteVerified(mute.DeviceName));
            }
            _silentSince = double.NaN;
            return;
        }
        // 枚举所有音频会话要走 COM，每秒查一次就够了（判定要连续 2 秒）
        if (now - _othersCheckedAt < 1) return;
        _othersCheckedAt = now;
        float others = mute.OthersPeak();
        if (others <= 0.01f)
        {
            _silentSince = double.NaN;
            return;
        }
        if (double.IsNaN(_silentSince)) _silentSince = now;
        if (now - _silentSince < 2) return;

        Log?.Invoke(CoreStrings.LogPostMuteSilent(mute.DeviceName, (int)Math.Round(others * 100)));
        mute.Restore();
        MutedDeviceChanged?.Invoke(null);
        PostMuteDetected?.Invoke(mute.DeviceId);
        _postMuteFallback = true;
        _silentSince = double.NaN;
    }

    // MARK: - 收尾

    private void TearDown()
    {
        _retryAt = double.PositiveInfinity;
        lock (_sendGate) _standby = false;
        ICapture? capture = _capture;
        _capture = null;
        if (capture is not null)
        {
            try
            {
                capture.Stop();
            }
            catch (COMException)
            {
                // 设备已经没了
            }
            capture.Dispose();
        }
        if (_mute is not null)
        {
            bool wasMuted = _mute.MutedByUs;
            string name = _mute.DeviceName;
            _mute.Dispose();
            _mute = null;
            if (wasMuted)
            {
                Log?.Invoke(CoreStrings.LogMuteRestored(name));
                MutedDeviceChanged?.Invoke(null);
            }
        }
        _encoder = null;
        _deviceId = null;
        _deviceName = null;
        Volatile.Write(ref _peakLeft, 0);
        Volatile.Write(ref _peakRight, 0);
    }

    private void ReleaseSocket()
    {
        _udp?.Dispose();
        _udp = null;
        _udpTarget = null;
    }

    private void SetState(SenderState state, string? error)
    {
        if (state != _state || error != _error)
            Log?.Invoke(error is null ? CoreStrings.LogState(state.ToString())
                                      : CoreStrings.LogStateWithError(state.ToString(), error));
        _state = state;
        _error = error;
        Publish();
    }

    private void Publish()
    {
        double now = Now;
        ICapture? capture = _capture;
        RemoteHealth health = RemoteHealth.Unknown;
        if (_remote is { IsBusy: true } && now - _remoteAt < 6) health = RemoteHealth.Busy;
        else if (_replies && _state == SenderState.Sending)
        {
            double silence = now - Math.Max(_remoteAt, _sendingSince);
            health = silence <= 3 ? RemoteHealth.Ok : RemoteHealth.NoResponse;
        }
        else if (_replies && now - _remoteAt <= 3) health = RemoteHealth.Ok;

        StatusMessage? remote = now - _remoteAt < 6 ? _remote : null;
        // 刚从待机恢复的 1.5 秒里，Mac 还在攒缓冲（或者还没收到恢复的包）：照样算正在播放，界面不闪“正在连接”
        if (!_standby && now - _resumedAt < 1.5 && remote is { IsBuffering: true } or { IsStandby: true })
            remote = remote with { State = "playing" };
        var next = new SenderSnapshot(_state, _error, _deviceId, _deviceName, capture?.FormatDescription,
                                      capture?.SampleRate ?? 0, capture?.ChannelCount ?? 0, 0, 0, 0, _settings)
        {
            Health = health,
            Remote = remote,
            PortUnreachable = now - _unreachableAt < 5,
            LocalMuted = _mute?.MutedByUs == true,
            PostMuteFallback = _postMuteFallback,
            Fresh = now < _freshUntil,
            Standby = _standby && _state == SenderState.Sending,
            ProcessLoopback = capture is not null && _usingProcessLoopback,
        };
        SenderSnapshot previous = _snapshot;
        _snapshot = next;
        if (!SameView(previous, next)) Changed?.Invoke();
    }

    /// <summary>界面关心的部分没变就不通知（计数器另外实时读）</summary>
    private static bool SameView(SenderSnapshot a, SenderSnapshot b) =>
        a.State == b.State && a.Error == b.Error && a.DeviceName == b.DeviceName && a.Health == b.Health &&
        a.PortUnreachable == b.PortUnreachable && a.LocalMuted == b.LocalMuted &&
        a.PostMuteFallback == b.PostMuteFallback && a.Fresh == b.Fresh && a.Standby == b.Standby &&
        a.ProcessLoopback == b.ProcessLoopback && a.Settings == b.Settings &&
        SameRemote(a.Remote, b.Remote);

    /// <summary>
    /// 只比界面用到的字段。STATUS 里的计数和缓冲水位每次都不一样，整个比的话 Mac 每回一次 STATUS
    /// 托盘和窗口就要刷新一次（快照本身照样每次更新）
    /// </summary>
    private static bool SameRemote(StatusMessage? x, StatusMessage? y) =>
        ReferenceEquals(x, y) || x is not null && y is not null && x.State == y.State && x.BusyName == y.BusyName &&
        x.Name == y.Name && x.Kind == y.Kind && x.Output == y.Output && x.Transport == y.Transport && x.Muted == y.Muted;

    /// <summary>更新电平表和静音检查用的峰值；返回这一批的峰值（16-bit）</summary>
    private int UpdatePeak(short[] samples, int frames)
    {
        int left = 0, right = 0;
        for (int i = 0; i < frames * 2; i += 2)
        {
            int l = Math.Abs((int)samples[i]);
            int r = Math.Abs((int)samples[i + 1]);
            if (l > left) left = l;
            if (r > right) right = r;
        }
        RaiseTo(ref _peakLeft, left / 32768f);
        RaiseTo(ref _peakRight, right / 32768f);
        RaiseTo(ref _peakForMuteCheck, Math.Max(left, right) / 32768f);
        return Math.Max(left, right);
    }

    private static void RaiseTo(ref float target, float level)
    {
        float current = Volatile.Read(ref target);
        while (level > current)
        {
            float seen = Interlocked.CompareExchange(ref target, level, current);
            if (seen == current) break;
            current = seen;
        }
    }

    private static string Describe(Exception ex) => ex switch
    {
        COMException com when (uint)com.HResult == 0x88890004 => CoreStrings.DeviceUnavailable,
        COMException com when (uint)com.HResult == 0x8889000A => CoreStrings.DeviceInExclusiveUse,
        _ => ex.Message,
    };

    public void Dispose()
    {
        _ticker.Dispose();
        Post(() =>
        {
            TearDown();
            SendBye(ByeReason.User);
            _settings = null;
            ReleaseSocket();
            if (_notifications is not null) _enumerator?.UnregisterEndpointNotificationCallback(_notifications);
            _enumerator?.Dispose();
        });
        _work.CompleteAdding();
        _thread.Join(TimeSpan.FromSeconds(3));
    }

    /// <summary>设备变化通知（在系统的线程上回调），转到引擎线程处理。</summary>
    private sealed class DeviceNotifications(SenderEngine engine) : IMMNotificationClient
    {
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
            if (flow == DataFlow.Render && role == Role.Multimedia)
                engine.Post(() => engine.OnDevicesChanged(defaultDeviceId));
        }

        public void OnDeviceStateChanged(string deviceId, DeviceState newState) => engine.Post(() => engine.OnDevicesChanged(null));
        public void OnDeviceAdded(string pwstrDeviceId) => engine.Post(() => engine.OnDevicesChanged(null));
        public void OnDeviceRemoved(string deviceId) => engine.Post(() => engine.OnDevicesChanged(null));
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }
}
