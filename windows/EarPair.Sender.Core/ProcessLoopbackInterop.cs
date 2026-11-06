using System.ComponentModel;
using System.Runtime.InteropServices;

// 进程 loopback 用到的 Core Audio 接口。NAudio 2.2 没有进程 loopback，这里自己声明。
// 回调对象要给系统（COM）调用，所以接口和类都是 public、ComVisible。
namespace EarPair.Sender.Interop;

[EditorBrowsable(EditorBrowsableState.Never)]
internal static class NativeMethods
{
    /// <summary>VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK</summary>
    public const string VirtualAudioDeviceProcessLoopback = "VAD\\Process_Loopback";

    [DllImport("Mmdevapi.dll", ExactSpelling = true)]
    public static extern int ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        IntPtr activationParams,
        IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);
}

/// <summary>AUDIOCLIENT_ACTIVATION_PARAMS（类型 + AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS）</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct AudioClientActivationParams
{
    public const int ProcessLoopback = 1;
    public const int IncludeTargetProcessTree = 0;
    public const int ExcludeTargetProcessTree = 1;

    public int ActivationType;
    public uint TargetProcessId;
    public int ProcessLoopbackMode;
}

/// <summary>只放 VT_BLOB 的 PROPVARIANT</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct BlobPropVariant
{
    public const ushort VtBlob = 65;

    public ushort Type;
    public ushort Reserved1;
    public ushort Reserved2;
    public ushort Reserved3;
    public uint Size;
    public IntPtr Data;
}

[ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
[EditorBrowsable(EditorBrowsableState.Never)]
public interface IActivateAudioInterfaceAsyncOperation
{
    [PreserveSig]
    int GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object? activatedInterface);
}

[ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
[EditorBrowsable(EditorBrowsableState.Never)]
public interface IActivateAudioInterfaceCompletionHandler
{
    void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
}

/// <summary>标记接口：这个对象可以在任何线程上被调用（激活完成的回调来自系统的线程池）</summary>
[ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
[EditorBrowsable(EditorBrowsableState.Never)]
public interface IAgileObject
{
}

[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
[EditorBrowsable(EditorBrowsableState.Never)]
public sealed class ActivationCompletionHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
{
    public ManualResetEventSlim Done { get; } = new();
    public int Result { get; private set; }
    public object? Client { get; private set; }

    public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation)
    {
        int hr = activateOperation.GetActivateResult(out int activateResult, out object? client);
        Result = hr < 0 ? hr : activateResult;
        Client = client;
        Done.Set();
    }
}

[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioClient
{
    [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr audioSessionGuid);
    [PreserveSig] int GetBufferSize(out int frames);
    [PreserveSig] int GetStreamLatency(out long latency);
    [PreserveSig] int GetCurrentPadding(out int frames);
    [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
    [PreserveSig] int GetMixFormat(out IntPtr format);
    [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
    [PreserveSig] int Start();
    [PreserveSig] int Stop();
    [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr eventHandle);
    [PreserveSig] int GetService(ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioCaptureClient
{
    [PreserveSig] int GetBuffer(out IntPtr data, out int frames, out int flags, out long devicePosition, out long qpcPosition);
    [PreserveSig] int ReleaseBuffer(int frames);
    [PreserveSig] int GetNextPacketSize(out int frames);
}
