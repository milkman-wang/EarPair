using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using NAudio.CoreAudioApi;

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
            var enumerator = new MMDeviceEnumerator();
            if (options.ListDevices)
            {
                ListDevices(enumerator);
                return 0;
            }
            if (options.Host is null)
            {
                Console.Error.WriteLine("请提供 Mac 的局域网 IP（在 Mac 菜单栏的 EarPair 里能看到）。");
                Console.Error.WriteLine();
                Console.Error.WriteLine(Options.Usage);
                return 2;
            }

            MMDevice? device = FindDevice(enumerator, options.DeviceFilter);
            if (device is null)
            {
                Console.Error.WriteLine($"找不到名称包含“{options.DeviceFilter}”的输出设备，用 --list-devices 查看。");
                return 1;
            }
            return Run(options, options.Host, device);
        }
        catch (Exception ex) when (ex is SocketException or NotSupportedException or COMException)
        {
            Console.Error.WriteLine($"出错了：{ex.Message}");
            return 1;
        }
    }

    private static int Run(Options options, string host, MMDevice device)
    {
        using var sender = new UdpSender(host, options.Port);
        using var capture = new AudioCapture(device, options.KeepAlive);
        uint streamId = (uint)Random.Shared.NextInt64(1, uint.MaxValue);
        var encoder = new PacketEncoder(capture.SampleRate, options.FramesPerPacket, streamId);

        using var stopped = new ManualResetEventSlim(false);
        Exception? failure = null;
        capture.FramesCaptured += (samples, frames) => encoder.Append(samples.AsSpan(0, frames * 2), sender.Send);
        capture.Stopped += ex =>
        {
            failure = ex;
            stopped.Set();
        };
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            stopped.Set();
        };

        Console.WriteLine("EarPair 发送端 0.1");
        Console.WriteLine($"  采集设备：{device.FriendlyName}");
        Console.WriteLine($"  采集格式：{capture.FormatDescription}");
        Console.WriteLine($"  发送：{capture.SampleRate} Hz 立体声 16-bit → {host}:{options.Port}，每包 {options.FramesPerPacket} 帧");
        if (capture.ChannelCount > 2)
            Console.WriteLine("  提示：这个输出设备是多声道，已混成立体声。在 Windows 声音设置里把它改成立体声效果更好。");
        if (!options.KeepAlive)
            Console.WriteLine("  提示：没有静音保活，Windows 没声音时会停止发包，Mac 端会显示断开。");
        Console.WriteLine("按 Ctrl+C 停止。");

        capture.Start();
        var clock = Stopwatch.StartNew();
        long lastBytes = 0;
        while (!stopped.Wait(TimeSpan.FromSeconds(5)))
        {
            long bytes = sender.BytesSent;
            double kbps = (bytes - lastBytes) * 8 / 5.0 / 1000;
            lastBytes = bytes;
            Console.WriteLine($"[{clock.Elapsed:hh\\:mm\\:ss}] 已发送 {sender.PacketsSent} 包，{kbps:F0} kbps，发送失败 {sender.SendErrors} 次");
        }
        capture.Stop();

        if (failure is not null)
        {
            Console.Error.WriteLine($"采集中断：{failure.Message}（输出设备可能被拔掉或停用了）");
            return 1;
        }
        Console.WriteLine("已停止。");
        return 0;
    }

    private static void ListDevices(MMDeviceEnumerator enumerator)
    {
        string? defaultId = null;
        try
        {
            defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
        }
        catch (COMException)
        {
            // 没有默认设备
        }
        Console.WriteLine("输出设备（* 为当前默认设备）：");
        foreach (MMDevice device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            Console.WriteLine($"  {(device.ID == defaultId ? "*" : " ")} {device.FriendlyName}");
    }

    private static MMDevice? FindDevice(MMDeviceEnumerator enumerator, string? filter)
    {
        if (string.IsNullOrWhiteSpace(filter))
            return enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        return enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
            .FirstOrDefault(d => d.FriendlyName.Contains(filter, StringComparison.OrdinalIgnoreCase));
    }
}
