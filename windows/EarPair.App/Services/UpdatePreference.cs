using Microsoft.Win32;

namespace EarPair.App.Services;

/// <summary>
/// 要不要自动检查更新：当前用户注册表 Software\EarPair 的 AutoCheckUpdates（1 / 0），没有这个值就算打开。
/// 安装程序第一次安装时按“自动检查更新”那一项写入（以后升级不覆盖），之后由主窗口的开关修改。
/// 关掉后不再自动访问 GitHub；手动“检查更新”照常可用。
/// </summary>
public static class UpdatePreference
{
    private const string Key = @"Software\EarPair";
    private const string ValueName = "AutoCheckUpdates";

    public static bool AutoCheck
    {
        get
        {
            try
            {
                using RegistryKey? key = Registry.CurrentUser.OpenSubKey(Key);
                return key?.GetValue(ValueName) is not int value || value != 0;
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
            {
                return true;
            }
        }
        set
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(Key);
            key.SetValue(ValueName, value ? 1 : 0, RegistryValueKind.DWord);
        }
    }
}
