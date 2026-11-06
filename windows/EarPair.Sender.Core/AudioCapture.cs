using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace EarPair.Sender;

/// <summary>
/// 设备 loopback：用 WASAPI loopback 采集一个输出设备正在播放的声音，统一转成立体声 16-bit 交错 PCM。
/// 有的声卡把这个设备的静音和音量算在 loopback 之前（见 ProcessLoopbackCapture）。
/// </summary>
public sealed class AudioCapture : ICapture
{
    private readonly WasapiCapture _capture;
    private readonly WasapiOut? _keepAlive;
    private readonly PcmConverter _converter;
    private readonly object _gate = new();
    private short[] _stereo = Array.Empty<short>();
    private bool _stopped;

    /// <summary>每次采到数据时触发（在采集线程上）：交错立体声样本缓冲、本次的帧数。</summary>
    public event Action<short[], int>? FramesCaptured;

    /// <summary>采集停止时触发；异常停止时带上异常。</summary>
    public event Action<Exception?>? Stopped;

    public int SampleRate { get; }
    public int ChannelCount { get; }
    public string FormatDescription { get; }

    public AudioCapture(MMDevice device, bool keepAlive)
    {
        _capture = CreateLoopbackCapture(device);
        WaveFormat format = _capture.WaveFormat;
        _converter = new PcmConverter(format);
        SampleRate = format.SampleRate;
        ChannelCount = format.Channels;
        FormatDescription = CoreStrings.FormatDescription(format.SampleRate, format.Channels, format.BitsPerSample,
                                                          PcmConverter.IsFloat(format));

        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += (_, e) => Stopped?.Invoke(e.Exception);

        if (keepAlive)
        {
            // Windows 完全没有声音时，loopback 采集不产生数据，Mac 端会判为断开。
            // 在同一个设备上一直播放静音，让采集流保持连续。副作用：运行期间 Windows 不会自动睡眠。
            _keepAlive = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
            _keepAlive.Init(new SilenceProvider(format));
        }
    }

    /// <summary>
    /// NAudio 自带的 WasapiLoopbackCapture 是轮询：每 50 ms 读一次（Windows 默认计时精度下实际约 62 ms），
    /// 一次拿到 60 ms 左右的数据，发出去就是一批十几个包，Mac 端 60 ms 的缓冲几乎没有余量。
    /// 改成事件触发后，音频引擎每 10 ms 通知一次，每次 2 个包，节奏均匀。
    /// Windows 10 1703 以前不支持事件触发的 loopback，退回轮询。
    /// </summary>
    private static WasapiCapture CreateLoopbackCapture(MMDevice device) =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 15063)
            ? new EventDrivenLoopbackCapture(device)
            : new WasapiLoopbackCapture(device);

    public void Start()
    {
        _keepAlive?.Play();
        _capture.StartRecording();
    }

    /// <summary>
    /// 停止采集。返回之后不会再触发 FramesCaptured（NAudio 的 StopRecording 是异步的，采集线程还可能再交一批数据）：
    /// 引擎停采集之后才发 BYE，BYE 后面不会再跟着音频包。
    /// </summary>
    public void Stop()
    {
        lock (_gate) _stopped = true;
        _capture.StopRecording();
        _keepAlive?.Stop();
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        lock (_gate)
        {
            if (_stopped) return;
            int frames = _converter.FrameCount(e.BytesRecorded);
            if (frames == 0) return;
            if (_stereo.Length < frames * 2) _stereo = new short[frames * 2];
            _converter.ConvertToStereo16(e.Buffer.AsSpan(0, e.BytesRecorded), _stereo);
            FramesCaptured?.Invoke(_stereo, frames);
        }
    }

    public void Dispose()
    {
        _capture.Dispose();
        _keepAlive?.Dispose();
    }

    /// <summary>事件触发的 loopback 采集。缓冲仍是 100 ms：采集线程偶尔被系统卡住几十毫秒也不会丢数据。</summary>
    private sealed class EventDrivenLoopbackCapture : WasapiCapture
    {
        // 参数：设备、事件触发、缓冲时长（毫秒）
        public EventDrivenLoopbackCapture(MMDevice device) : base(device, true, 100) { }

        protected override AudioClientStreamFlags GetAudioClientStreamFlags() =>
            AudioClientStreamFlags.Loopback | base.GetAudioClientStreamFlags();
    }
}
