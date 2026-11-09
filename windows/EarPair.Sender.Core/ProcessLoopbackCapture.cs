using System.Runtime.InteropServices;
using EarPair.Sender.Interop;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace EarPair.Sender;

/// <summary>
/// 进程 loopback：采集除 EarPair 自己（和它的子进程）以外所有程序的声音，统一转成立体声 16-bit 交错 PCM。
///
/// 和设备 loopback 不同，它在声音进输出设备之前就取走了：输出设备静音、调音量都不影响采到的声音。
/// 有的声卡（实测：带硬件音量 / 静音的 Realtek High Definition Audio）静音后设备 loopback 只剩静音，
/// “发送时本机静音”在那上面只能靠这种方式。代价是不再区分输出设备：放到哪个设备的声音都会采到。
///
/// 系统不支持（较老的 Windows 10）或者暂时激活不了时构造函数抛异常，引擎先退回设备 loopback，过一会儿再试。
/// 必须在 MTA 线程上创建（引擎线程就是）。
/// </summary>
public sealed class ProcessLoopbackCapture : ICapture
{
    private const int Rate = 48000;
    private const int AudclntBufferFlagsSilent = 0x2;
    // LOOPBACK | EVENTCALLBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY：格式由我们定，系统负责转换
    private const int StreamFlags = unchecked((int)(0x00020000 | 0x00040000 | 0x80000000 | 0x08000000));
    /// <summary>缓冲 100 ms（和设备 loopback 一样）：采集线程偶尔被系统卡住几十毫秒也不会丢数据</summary>
    private const long BufferDuration = 100 * 10_000;

    private readonly IAudioClient _client;
    private readonly IAudioCaptureClient _captureClient;
    private readonly WaveFormat _format = WaveFormat.CreateIeeeFloatWaveFormat(Rate, 2);
    private readonly PcmConverter _converter;
    private readonly EventWaitHandle _ready = new(false, EventResetMode.AutoReset);
    private readonly WasapiOut? _keepAlive;
    private readonly object _gate = new();
    private Thread? _thread;
    private volatile bool _stopping;
    private bool _stopped;
    private byte[] _raw = [];
    private short[] _stereo = [];

    public event Action<short[], int>? FramesCaptured;
    public event Action<Exception?>? Stopped;

    public int SampleRate => Rate;
    public int ChannelCount => 2;
    public string FormatDescription { get; }

    /// <param name="keepAliveDevice">在这个设备上一直放静音（和设备 loopback 一样：让声音系统保持运行），null 表示不放。
    /// 静音是 EarPair 自己放的，进程 loopback 排除了自己，所以采不到它。</param>
    public ProcessLoopbackCapture(MMDevice? keepAliveDevice)
    {
        _converter = new PcmConverter(_format);
        FormatDescription = CoreStrings.FormatDescription(Rate, 2, 32, isFloat: true);
        _client = ActivateExcludingThisProcess();
        try
        {
            IntPtr format = WaveFormat.MarshalToPtr(_format);
            try
            {
                Marshal.ThrowExceptionForHR(_client.Initialize(0, StreamFlags, BufferDuration, 0, format, IntPtr.Zero));
            }
            finally
            {
                Marshal.FreeHGlobal(format);
            }
            Marshal.ThrowExceptionForHR(_client.SetEventHandle(_ready.SafeWaitHandle.DangerousGetHandle()));
            Guid iid = typeof(IAudioCaptureClient).GUID;
            Marshal.ThrowExceptionForHR(_client.GetService(ref iid, out object service));
            _captureClient = (IAudioCaptureClient)service;

            if (keepAliveDevice is not null)
            {
                // MMDevice.AudioClient 每次都新建一个，只用来读格式，用完就放掉
                using AudioClient mixClient = keepAliveDevice.AudioClient;
                _keepAlive = new WasapiOut(keepAliveDevice, AudioClientShareMode.Shared, true, 100);
                _keepAlive.Init(new SilenceProvider(mixClient.MixFormat));
            }
        }
        catch
        {
            // 构造失败时调用方拿不到对象，Dispose 不会被调用：已经建好的都在这里放掉
            _keepAlive?.Dispose();
            if (_captureClient is not null) Marshal.ReleaseComObject(_captureClient);
            Marshal.ReleaseComObject(_client);
            _ready.Dispose();
            throw;
        }
    }

    public void Start()
    {
        _keepAlive?.Play();
        Marshal.ThrowExceptionForHR(_client.Start());
        _thread = new Thread(Run) { IsBackground = true, Name = "EarPair 进程 loopback", Priority = ThreadPriority.AboveNormal };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
    }

    public void Stop()
    {
        lock (_gate) _stopped = true;
        _stopping = true;
        _ready.Set();
        if (_thread is not null && _thread != Thread.CurrentThread) _thread.Join(TimeSpan.FromSeconds(2));
        _client.Stop();
        _keepAlive?.Stop();
    }

    private void Run()
    {
        Exception? error = null;
        try
        {
            while (!_stopping)
            {
                // 没有程序出声时可能一直没有事件：定时醒来看看要不要退出
                _ready.WaitOne(200);
                if (_stopping) break;
                Drain();
            }
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException)
        {
            error = ex;
        }
        Stopped?.Invoke(error);
    }

    /// <summary>把缓冲里已有的数据读完、转换、交出去</summary>
    private void Drain()
    {
        Marshal.ThrowExceptionForHR(_captureClient.GetNextPacketSize(out int packet));
        while (packet > 0)
        {
            Marshal.ThrowExceptionForHR(_captureClient.GetBuffer(out IntPtr data, out int frames, out int flags, out _, out _));
            try
            {
                lock (_gate)
                {
                    if (!_stopped && frames > 0)
                    {
                        int bytes = frames * _format.BlockAlign;
                        if (_stereo.Length < frames * 2) _stereo = new short[frames * 2];
                        if ((flags & AudclntBufferFlagsSilent) != 0)
                        {
                            Array.Clear(_stereo, 0, frames * 2);
                        }
                        else
                        {
                            if (_raw.Length < bytes) _raw = new byte[bytes];
                            Marshal.Copy(data, _raw, 0, bytes);
                            _converter.ConvertToStereo16(_raw.AsSpan(0, bytes), _stereo);
                        }
                        FramesCaptured?.Invoke(_stereo, frames);
                    }
                }
            }
            finally
            {
                Marshal.ThrowExceptionForHR(_captureClient.ReleaseBuffer(frames));
            }
            Marshal.ThrowExceptionForHR(_captureClient.GetNextPacketSize(out packet));
        }
    }

    public void Dispose()
    {
        if (!_stopping) Stop();
        Marshal.ReleaseComObject(_captureClient);
        Marshal.ReleaseComObject(_client);
        _ready.Dispose();
        _keepAlive?.Dispose();
    }

    /// <summary>用 ActivateAudioInterfaceAsync 激活“除本进程树以外所有程序”的进程 loopback</summary>
    private static IAudioClient ActivateExcludingThisProcess()
    {
        var parameters = new AudioClientActivationParams
        {
            ActivationType = AudioClientActivationParams.ProcessLoopback,
            TargetProcessId = (uint)Environment.ProcessId,
            ProcessLoopbackMode = AudioClientActivationParams.ExcludeTargetProcessTree,
        };
        int size = Marshal.SizeOf<AudioClientActivationParams>();
        IntPtr parametersPtr = Marshal.AllocHGlobal(size);
        IntPtr variantPtr = Marshal.AllocHGlobal(Marshal.SizeOf<BlobPropVariant>());
        try
        {
            Marshal.StructureToPtr(parameters, parametersPtr, false);
            Marshal.StructureToPtr(new BlobPropVariant { Type = BlobPropVariant.VtBlob, Size = (uint)size, Data = parametersPtr }, variantPtr, false);
            var handler = new ActivationCompletionHandler();
            Marshal.ThrowExceptionForHR(NativeMethods.ActivateAudioInterfaceAsync(
                NativeMethods.VirtualAudioDeviceProcessLoopback, typeof(IAudioClient).GUID, variantPtr, handler,
                out IActivateAudioInterfaceAsyncOperation operation));
            if (!handler.Done.Wait(TimeSpan.FromSeconds(5)))
                throw new TimeoutException("ActivateAudioInterfaceAsync (process loopback) timed out");
            GC.KeepAlive(operation);
            Marshal.ThrowExceptionForHR(handler.Result);
            return (IAudioClient)handler.Client!;
        }
        finally
        {
            Marshal.FreeHGlobal(variantPtr);
            Marshal.FreeHGlobal(parametersPtr);
        }
    }
}
