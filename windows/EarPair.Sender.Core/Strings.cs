using System.Globalization;
using System.Resources;

namespace EarPair.Sender;

/// <summary>
/// 发送引擎的文字（错误、采集格式、日志），跟随界面语言（CurrentUICulture）：英文在 Strings.resx，中文在 Strings.zh-Hans.resx。
/// 资源名取自这个文件里第一个类的全名（和 .resx 同名的 .cs 约定），所以类名不叫 Strings 也能对上；
/// 命令行版和 App 各有自己的 Strings.resx，类名不同，自检里编进同一个程序集也不冲突。
/// </summary>
public static class CoreStrings
{
    private static readonly ResourceManager Resources = new(typeof(CoreStrings));

    public static string HostNotFound(string host) => Format(nameof(HostNotFound), host);
    public static string NetworkUnavailable => Get(nameof(NetworkUnavailable));
    public static string DeviceUnavailable => Get(nameof(DeviceUnavailable));
    public static string DeviceInExclusiveUse => Get(nameof(DeviceInExclusiveUse));
    public static string UnsupportedFormat(string format) => Format(nameof(UnsupportedFormat), format);
    public static string UnsupportedSampleRate(int sampleRate) => Format(nameof(UnsupportedSampleRate), sampleRate);
    public static string ControlPacketTooLong => Get(nameof(ControlPacketTooLong));

    /// <summary>采集格式，比如“48000 Hz, 2-channel, 32-bit float”</summary>
    public static string FormatDescription(int sampleRate, int channels, int bits, bool isFloat) =>
        Format(isFloat ? "FormatFloat" : "FormatInteger", sampleRate, channels, bits);

    public static string LogCaptureStarted(string device, string format, uint stream) =>
        Format(nameof(LogCaptureStarted), device, format, stream.ToString("x8", CultureInfo.InvariantCulture));
    public static string LogCaptureAllApps(string format, uint stream) =>
        Format(nameof(LogCaptureAllApps), format, stream.ToString("x8", CultureInfo.InvariantCulture));
    public static string LogProcessLoopbackUnavailable(string reason) => Format(nameof(LogProcessLoopbackUnavailable), reason);
    public static string LogProcessLoopbackRetry => Get(nameof(LogProcessLoopbackRetry));
    public static string LogMacResponded(string? name, string? app) => Format(nameof(LogMacResponded), name, app);
    public static string LogStandby => Get(nameof(LogStandby));
    public static string LogResumed => Get(nameof(LogResumed));
    public static string LogWakeForMac => Get(nameof(LogWakeForMac));
    public static string LogPausedNoResponse => Get(nameof(LogPausedNoResponse));
    public static string LogPausedBusy => Get(nameof(LogPausedBusy));
    // 发送时本机静音
    public static string LogMuteOff => Get(nameof(LogMuteOff));
    public static string LogMuteSkipped(string device) => Format(nameof(LogMuteSkipped), device);
    public static string LogMuteRememberedButProcessLoopback(string device) =>
        Format(nameof(LogMuteRememberedButProcessLoopback), device);
    public static string LogMuted(string device) => Format(nameof(LogMuted), device);
    public static string LogAlreadyMuted(string device) => Format(nameof(LogAlreadyMuted), device);
    public static string LogMuteFailed(string device) => Format(nameof(LogMuteFailed), device);
    public static string LogMuteVerified(string device) => Format(nameof(LogMuteVerified), device);
    public static string LogUserUnmuted(string device) => Format(nameof(LogUserUnmuted), device);
    public static string LogMuteSkippedUserUnmuted(string device) => Format(nameof(LogMuteSkippedUserUnmuted), device);
    /// <param name="othersPercent">其他程序在这个设备上的峰值（百分比）</param>
    public static string LogPostMuteSilent(string device, int othersPercent) =>
        Format(nameof(LogPostMuteSilent), device, othersPercent);
    public static string LogMuteRestored(string device) => Format(nameof(LogMuteRestored), device);
    public static string LogMuteRestoreDeferred(string device) => Format(nameof(LogMuteRestoreDeferred), device);
    public static string LogMuteRestoredLater => Get(nameof(LogMuteRestoredLater));

    /// <param name="state">状态名（SenderState 的英文标识，不翻译）</param>
    public static string LogState(string state) => Format(nameof(LogState), state);
    public static string LogStateWithError(string state, string error) => Format(nameof(LogStateWithError), state, error);

    /// <summary>缺了这个键时返回键名（界面上一眼能看出来，不会崩）</summary>
    private static string Get(string name) => Resources.GetString(name) ?? name;

    private static string Format(string name, params object?[] args) => string.Format(CultureInfo.CurrentCulture, Get(name), args);
}
