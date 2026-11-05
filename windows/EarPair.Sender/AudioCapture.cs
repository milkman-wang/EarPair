using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace EarPair.Sender;

/// <summary>
/// 用 WASAPI loopback 采集一个输出设备正在播放的声音，统一转成立体声 16-bit 交错 PCM。
/// </summary>
internal sealed class AudioCapture : IDisposable
{
    private readonly WasapiLoopbackCapture _capture;
    private readonly WasapiOut? _keepAlive;
    private readonly PcmConverter _converter;
    private short[] _stereo = Array.Empty<short>();

    /// <summary>每次采到数据时触发（在采集线程上）：交错立体声样本缓冲、本次的帧数。</summary>
    public event Action<short[], int>? FramesCaptured;

    /// <summary>采集停止时触发；异常停止时带上异常。</summary>
    public event Action<Exception?>? Stopped;

    public int SampleRate { get; }
    public int ChannelCount { get; }
    public string FormatDescription { get; }

    public AudioCapture(MMDevice device, bool keepAlive)
    {
        _capture = new WasapiLoopbackCapture(device);
        WaveFormat format = _capture.WaveFormat;
        _converter = new PcmConverter(format);
        SampleRate = format.SampleRate;
        ChannelCount = format.Channels;
        string kind = PcmConverter.IsFloat(format) ? "浮点" : "整数";
        FormatDescription = $"{format.SampleRate} Hz，{format.Channels} 声道，{format.BitsPerSample}-bit {kind}";

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

    public void Start()
    {
        _keepAlive?.Play();
        _capture.StartRecording();
    }

    public void Stop()
    {
        _capture.StopRecording();
        _keepAlive?.Stop();
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        int frames = _converter.FrameCount(e.BytesRecorded);
        if (frames == 0) return;
        if (_stereo.Length < frames * 2) _stereo = new short[frames * 2];
        _converter.ConvertToStereo16(e.Buffer.AsSpan(0, e.BytesRecorded), _stereo);
        FramesCaptured?.Invoke(_stereo, frames);
    }

    public void Dispose()
    {
        _capture.Dispose();
        _keepAlive?.Dispose();
    }
}
