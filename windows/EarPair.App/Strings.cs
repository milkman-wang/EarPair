using System.Globalization;
using System.Resources;

namespace EarPair.App;

/// <summary>
/// 界面文字，跟随 Windows 的显示语言（CurrentUICulture；隐藏参数 --lang 可以指定）：
/// 英文在 Strings.resx，中文在 Strings.zh-Hans.resx，其他语言都用英文。
/// XAML 里用 {x:Bind local:Strings.Xxx} 取；带参数的是方法。引擎的错误和日志在 EarPair.Sender.CoreStrings。
/// </summary>
public static class Strings
{
    private static readonly ResourceManager Resources = new(typeof(Strings));

    /// <summary>WinUI 控件自带的文字（右键菜单等）用的语言，和界面文字一致</summary>
    public static string ControlLanguage => Get(nameof(ControlLanguage));

    // 主窗口
    public static string More => Get(nameof(More));
    public static string OpenLogFolder => Get(nameof(OpenLogFolder));
    public static string ExitEarPair => Get(nameof(ExitEarPair));
    public static string Send => Get(nameof(Send));
    public static string ChooseMac => Get(nameof(ChooseMac));
    public static string SearchAgain => Get(nameof(SearchAgain));
    public static string NoMacsFound => Get(nameof(NoMacsFound));
    public static string EnterAddress => Get(nameof(EnterAddress));
    public static string EnterAddressMenu => Get(nameof(EnterAddressMenu));
    public static string SendTo => Get(nameof(SendTo));
    public static string SoundSource => Get(nameof(SoundSource));
    public static string MuteWhileSending => Get(nameof(MuteWhileSending));
    public static string StartAtLogin => Get(nameof(StartAtLogin));
    public static string CannotMuteDevice => Get(nameof(CannotMuteDevice));
    public static string NameWithAddress(string name, string address) => Format(nameof(NameWithAddress), name, address);
    public static string SystemDefault => Get(nameof(SystemDefault));
    public static string SystemDefaultDevice(string device) => Format(nameof(SystemDefaultDevice), device);

    // 输入地址对话框
    public static string AddressDialogTitle => Get(nameof(AddressDialogTitle));
    public static string AddressNotFound => Get(nameof(AddressNotFound));
    public static string Connect => Get(nameof(Connect));
    public static string Cancel => Get(nameof(Cancel));

    // 主卡片的状态和提示条
    public static string StatusNotSending => Get(nameof(StatusNotSending));
    public static string StatusCantSend => Get(nameof(StatusCantSend));
    public static string SomethingWentWrong => Get(nameof(SomethingWentWrong));
    public static string Retry => Get(nameof(Retry));
    public static string StatusNoSource => Get(nameof(StatusNoSource));
    public static string StatusMacBusy => Get(nameof(StatusMacBusy));
    /// <param name="pc">正在给 Mac 发声音的电脑；null（Mac 没报名字）时用整句“正在播放另一台电脑的声音”</param>
    public static string BusyPlaying(string? pc) => pc is null ? Get("BusyPlayingUnknown") : Format(nameof(BusyPlaying), pc);
    public static string StatusConnecting => Get(nameof(StatusConnecting));
    public static string StatusWaitingForMac => Get(nameof(StatusWaitingForMac));
    public static string ResumesWhenMacAvailable => Get(nameof(ResumesWhenMacAvailable));
    public static string SendAnyway => Get(nameof(SendAnyway));
    public static string StatusMacNotResponding => Get(nameof(StatusMacNotResponding));
    public static string EarPairNotOpenOnMac => Get(nameof(EarPairNotOpenOnMac));
    public static string CantReachMac => Get(nameof(CantReachMac));
    public static string StatusStandby => Get(nameof(StatusStandby));
    public static string StatusMutedOnMac => Get(nameof(StatusMutedOnMac));
    public static string StatusPlaying => Get(nameof(StatusPlaying));
    public static string StatusSending => Get(nameof(StatusSending));
    public static string PostMuteNotice => Get(nameof(PostMuteNotice));
    public static string PathDescription(string status, string pc, string mac) => Format(nameof(PathDescription), status, pc, mac);
    public static string PathDescriptionWithOutput(string status, string pc, string mac, string output) =>
        Format(nameof(PathDescriptionWithOutput), status, pc, mac, output);

    // 通知区域
    public static string TrayNoMac => Get(nameof(TrayNoMac));
    public static string StartSending => Get(nameof(StartSending));
    public static string StopSending => Get(nameof(StopSending));
    public static string OpenEarPair => Get(nameof(OpenEarPair));
    public static string Exit => Get(nameof(Exit));
    public static string BackgroundTitle => Get(nameof(BackgroundTitle));
    public static string BackgroundText => Get(nameof(BackgroundText));

    // 日志
    public static string LogStarting(string version, string architecture, string os) =>
        Format(nameof(LogStarting), version, architecture, os);
    public static string LogStartingAtLogin(string version, string architecture, string os) =>
        Format(nameof(LogStartingAtLogin), version, architecture, os);
    public static string LogRestoredMute => Get(nameof(LogRestoredMute));
    public static string LogPostMuteDevice(string deviceId) => Format(nameof(LogPostMuteDevice), deviceId);
    public static string LogStartSending(string mac, string host, int port) => Format(nameof(LogStartSending), mac, host, port);
    public static string LogStartSendingAnyway(string mac, string host, int port) =>
        Format(nameof(LogStartSendingAnyway), mac, host, port);
    public static string LogStopSending => Get(nameof(LogStopSending));
    public static string LogAddressChanged(string mac, string from, string to) => Format(nameof(LogAddressChanged), mac, from, to);
    public static string LogSessionEnding => Get(nameof(LogSessionEnding));
    public static string LogExit => Get(nameof(LogExit));
    public static string LogUnhandled(int hresult, object exception) =>
        Format(nameof(LogUnhandled), hresult.ToString("x8", CultureInfo.InvariantCulture), exception);
    public static string LogUnhandledBackground(object exception) => Format(nameof(LogUnhandledBackground), exception);

    /// <summary>缺了这个键时返回键名（界面上一眼能看出来，不会崩）</summary>
    private static string Get(string name) => Resources.GetString(name) ?? name;

    private static string Format(string name, params object?[] args) => string.Format(CultureInfo.CurrentCulture, Get(name), args);
}
