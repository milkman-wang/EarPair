using Microsoft.Win32;

namespace EarPair.App.Services;

/// <summary>
/// 开机自启：写当前用户的 Run 注册表项（不需要管理员权限），启动时带 --background，只在通知区域显示。
/// 还要看 StartupApproved：用户在“设置 › 应用 › 启动”或任务管理器里关掉了，就当作没开。
/// </summary>
public static class Autostart
{
    public const string BackgroundArgument = "--background";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "EarPair";

    private static string Command => $"\"{Environment.ProcessPath}\" {BackgroundArgument}";

    public static bool IsEnabled
    {
        get
        {
            using RegistryKey? run = Registry.CurrentUser.OpenSubKey(RunKey);
            if (run?.GetValue(ValueName) is not string) return false;
            using RegistryKey? approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
            // 第一个字节是奇数表示被用户在系统设置里关掉了
            return approved?.GetValue(ValueName) is not byte[] { Length: > 0 } flags || flags[0] % 2 == 0;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using RegistryKey run = Registry.CurrentUser.OpenSubKey(RunKey, writable: true)
                                ?? Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled)
        {
            run.SetValue(ValueName, Command);
            using RegistryKey? approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
            approved?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        else
        {
            run.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    /// <summary>zip 解压到了别的位置：把 Run 值里的路径改成现在的 exe</summary>
    public static void FixPath()
    {
        try
        {
            using RegistryKey? run = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (run?.GetValue(ValueName) is string value && value != Command) run.SetValue(ValueName, Command);
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
