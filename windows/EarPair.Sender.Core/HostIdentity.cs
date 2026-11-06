using System.Net;
using System.Runtime.InteropServices;

namespace EarPair.Sender;

/// <summary>这台电脑的名字和类型：写进 HELLO，Mac 的路线上显示同样的名字和图标。</summary>
public static class HostIdentity
{
    /// <summary>
    /// DNS 主机名，保留大小写（和“设置 › 系统 › 系统信息”里的设备名一致）。
    /// 不用 Environment.MachineName：它是全大写、最多 15 个字符的 NetBIOS 名。
    /// </summary>
    public static string Name { get; } = GetName();

    /// <summary>laptop（有系统电池）或 desktop</summary>
    public static string Kind { get; } = GetKind();

    private static string GetName()
    {
        try
        {
            string name = Dns.GetHostName();
            if (!string.IsNullOrWhiteSpace(name)) return name;
        }
        catch (System.Net.Sockets.SocketException)
        {
        }
        return Environment.MachineName;
    }

    private static string GetKind()
    {
        // BatteryFlag：128 表示没有系统电池，255 表示不知道，这两种都按台式机算
        if (GetSystemPowerStatus(out SystemPowerStatus status) && status.BatteryFlag is not (128 or 255))
            return "laptop";
        return "desktop";
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);
}
