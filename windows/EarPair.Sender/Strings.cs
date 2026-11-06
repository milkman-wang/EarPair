using System.Globalization;
using System.Resources;

namespace EarPair.Sender;

/// <summary>
/// 命令行版的文字，跟随系统语言：英文在 Strings.resx，中文在 Strings.zh-Hans.resx。
/// 资源名取自这个文件里第一个类的全名（和 .resx 同名的 .cs 约定）；引擎自己的文字在 CoreStrings。
/// </summary>
internal static class CliStrings
{
    private static readonly ResourceManager Resources = new(typeof(CliStrings));

    public static string Usage => Get(nameof(Usage));

    public static string NeedsValue(string option) => Format(nameof(NeedsValue), option);
    public static string MustBeInteger(string option, int min, int max) => Format(nameof(MustBeInteger), option, min, max);
    public static string UnknownArgument(string argument) => Format(nameof(UnknownArgument), argument);

    public static string DeviceListHeader => Get(nameof(DeviceListHeader));
    public static string HostMissing => Get(nameof(HostMissing));
    public static string DeviceNotFound(string filter) => Format(nameof(DeviceNotFound), filter);
    public static string Error(string message) => Format(nameof(Error), message);
    public static string Banner(string version) => Format(nameof(Banner), version);
    public static string Standby => Get(nameof(Standby));
    public static string Resumed => Get(nameof(Resumed));
    public static string CaptureDevice(string? device) => Format(nameof(CaptureDevice), device);
    public static string CaptureDeviceDefault(string? device) => Format(nameof(CaptureDeviceDefault), device);
    public static string CaptureFormat(string? format) => Format(nameof(CaptureFormat), format);
    public static string SendingTo(int sampleRate, string host, int port, int frames) =>
        Format(nameof(SendingTo), sampleRate, host, port, frames);
    public static string MultichannelTip => Get(nameof(MultichannelTip));
    public static string WaitingForDevice => Get(nameof(WaitingForDevice));
    public static string FailedRetrying(string? error) => Format(nameof(FailedRetrying), error);
    public static string NoKeepAliveTip => Get(nameof(NoKeepAliveTip));
    public static string PressCtrlC => Get(nameof(PressCtrlC));
    public static string Progress(string elapsed, long packets, string kbps, long errors) =>
        Format(nameof(Progress), elapsed, packets, kbps, errors);
    public static string Stopped => Get(nameof(Stopped));

    /// <summary>缺了这个键时返回键名（一眼能看出来，不会崩）</summary>
    private static string Get(string name) => Resources.GetString(name) ?? name;

    private static string Format(string name, params object?[] args) => string.Format(CultureInfo.CurrentCulture, Get(name), args);
}
