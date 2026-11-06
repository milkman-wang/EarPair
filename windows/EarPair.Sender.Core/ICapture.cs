namespace EarPair.Sender;

/// <summary>
/// 一路采集：设备 loopback（AudioCapture）或进程 loopback（ProcessLoopbackCapture）。
/// 都统一转成立体声 16-bit 交错 PCM。
/// </summary>
public interface ICapture : IDisposable
{
    /// <summary>每次采到数据时触发（在采集线程上）：交错立体声样本缓冲、本次的帧数。</summary>
    event Action<short[], int>? FramesCaptured;

    /// <summary>采集停止时触发；异常停止时带上异常。</summary>
    event Action<Exception?>? Stopped;

    int SampleRate { get; }
    int ChannelCount { get; }
    string FormatDescription { get; }

    void Start();

    /// <summary>停止采集。返回之后不会再触发 FramesCaptured。</summary>
    void Stop();
}
