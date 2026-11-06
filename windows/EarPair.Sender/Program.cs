using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace EarPair.Sender;

internal static class Program
{
    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;

        Options options;
        try
        {
            options = Options.Parse(args);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine(ex.Message);
            Console.Error.WriteLine();
            Console.Error.WriteLine(Options.Usage);
            return 2;
        }
        if (options.ShowHelp)
        {
            Console.WriteLine(Options.Usage);
            return 0;
        }

        try
        {
            IReadOnlyList<AudioDeviceInfo> devices = SenderEngine.ListDevices();
            if (options.ListDevices)
            {
                Console.WriteLine("输出设备（* 为当前默认设备）：");
                foreach (AudioDeviceInfo device in devices)
                    Console.WriteLine($"  {(device.IsDefault ? "*" : " ")} {device.Name}");
                return 0;
            }
            if (options.Host is null)
            {
                Console.Error.WriteLine("请提供 Mac 的局域网 IP（在 Mac 菜单栏的 EarPair 里能看到）。");
                Console.Error.WriteLine();
                Console.Error.WriteLine(Options.Usage);
                return 2;
            }

            string? deviceId = null; // 不指定设备时跟随系统默认输出设备
            if (!string.IsNullOrWhiteSpace(options.DeviceFilter))
            {
                AudioDeviceInfo? match = devices.FirstOrDefault(
                    d => d.Name.Contains(options.DeviceFilter, StringComparison.OrdinalIgnoreCase));
                if (match is null)
                {
                    Console.Error.WriteLine($"找不到名称包含“{options.DeviceFilter}”的输出设备，用 --list-devices 查看。");
                    return 1;
                }
                deviceId = match.Id;
            }
            return Run(options, options.Host, deviceId);
        }
        catch (COMException ex)
        {
            Console.Error.WriteLine($"出错了：{ex.Message}");
            return 1;
        }
    }

    private static int Run(Options options, string host, string? deviceId)
    {
        using var engine = new SenderEngine();
        using var stopped = new ManualResetEventSlim(false);
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            stopped.Set();
        };

        Console.WriteLine("EarPair 发送端 0.2");
        SenderSnapshot? shown = null;
        engine.Changed += () =>
        {
            SenderSnapshot s = engine.Snapshot;
            if (shown is not null && shown.State == s.State && shown.DeviceName == s.DeviceName && shown.Error == s.Error)
                return;
            shown = s;
            switch (s.State)
            {
                case SenderState.Sending:
                    Console.WriteLine($"  采集设备：{s.DeviceName}{(deviceId is null ? "（跟随系统默认设备）" : "")}");
                    Console.WriteLine($"  采集格式：{s.FormatDescription}");
                    Console.WriteLine($"  发送：{s.SampleRate} Hz 立体声 16-bit → {host}:{options.Port}，每包 {options.FramesPerPacket} 帧");
                    if (s.ChannelCount > 2)
                        Console.WriteLine("  提示：这个输出设备是多声道，已混成立体声。在 Windows 声音设置里把它改成立体声效果更好。");
                    break;
                case SenderState.WaitingForDevice:
                    Console.WriteLine("  等待输出设备……（设备回来后自动继续）");
                    break;
                case SenderState.Failed:
                    Console.WriteLine($"  出错了：{s.Error}（稍后自动重试）");
                    break;
            }
        };

        engine.Start(new SenderSettings(host, options.Port, deviceId, options.KeepAlive, options.FramesPerPacket));
        if (!options.KeepAlive)
            Console.WriteLine("  提示：没有静音保活，Windows 没声音时会停止发包，Mac 端会显示断开。");
        Console.WriteLine("按 Ctrl+C 停止。");

        var clock = Stopwatch.StartNew();
        long lastBytes = 0;
        while (!stopped.Wait(TimeSpan.FromSeconds(5)))
        {
            SenderSnapshot s = engine.Snapshot;
            double kbps = (s.BytesSent - lastBytes) * 8 / 5.0 / 1000;
            lastBytes = s.BytesSent;
            Console.WriteLine($"[{clock.Elapsed:hh\\:mm\\:ss}] 已发送 {s.PacketsSent} 包，{kbps:F0} kbps，发送失败 {s.SendErrors} 次");
        }
        engine.Stop();
        Console.WriteLine("已停止。");
        return 0;
    }
}
