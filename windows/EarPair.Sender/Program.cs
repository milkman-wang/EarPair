using System.Diagnostics;
using System.Globalization;
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
            Console.Error.WriteLine(CliStrings.Usage);
            return 2;
        }
        if (options.ShowHelp)
        {
            Console.WriteLine(CliStrings.Usage);
            return 0;
        }

        try
        {
            IReadOnlyList<AudioDeviceInfo> devices = SenderEngine.ListDevices();
            if (options.ListDevices)
            {
                Console.WriteLine(CliStrings.DeviceListHeader);
                foreach (AudioDeviceInfo device in devices)
                    Console.WriteLine($"  {(device.IsDefault ? "*" : " ")} {device.Name}");
                return 0;
            }
            if (options.Host is null)
            {
                Console.Error.WriteLine(CliStrings.HostMissing);
                Console.Error.WriteLine();
                Console.Error.WriteLine(CliStrings.Usage);
                return 2;
            }

            string? deviceId = null; // 不指定设备时跟随系统默认输出设备
            if (!string.IsNullOrWhiteSpace(options.DeviceFilter))
            {
                AudioDeviceInfo? match = devices.FirstOrDefault(
                    d => d.Name.Contains(options.DeviceFilter, StringComparison.OrdinalIgnoreCase));
                if (match is null)
                {
                    Console.Error.WriteLine(CliStrings.DeviceNotFound(options.DeviceFilter));
                    return 1;
                }
                deviceId = match.Id;
            }
            return Run(options, options.Host, deviceId);
        }
        catch (COMException ex)
        {
            Console.Error.WriteLine(CliStrings.Error(ex.Message));
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

        Console.WriteLine(CliStrings.Banner("0.2"));
        SenderSnapshot? shown = null;
        bool standbyShown = false;
        engine.Changed += () =>
        {
            SenderSnapshot s = engine.Snapshot;
            if (s.Standby != standbyShown)
            {
                standbyShown = s.Standby;
                if (s.Standby) Console.WriteLine("  " + CliStrings.Standby);
                else if (s.State == SenderState.Sending) Console.WriteLine("  " + CliStrings.Resumed);
            }
            if (shown is not null && shown.State == s.State && shown.DeviceName == s.DeviceName && shown.Error == s.Error)
                return;
            shown = s;
            switch (s.State)
            {
                case SenderState.Sending:
                    Console.WriteLine("  " + (deviceId is null ? CliStrings.CaptureDeviceDefault(s.DeviceName)
                                                               : CliStrings.CaptureDevice(s.DeviceName)));
                    Console.WriteLine("  " + CliStrings.CaptureFormat(s.FormatDescription));
                    Console.WriteLine("  " + CliStrings.SendingTo(s.SampleRate, host, options.Port, options.FramesPerPacket));
                    if (s.ChannelCount > 2)
                        Console.WriteLine("  " + CliStrings.MultichannelTip);
                    break;
                case SenderState.WaitingForDevice:
                    Console.WriteLine("  " + CliStrings.WaitingForDevice);
                    break;
                case SenderState.Failed:
                    Console.WriteLine("  " + CliStrings.FailedRetrying(s.Error));
                    break;
            }
        };

        engine.Start(new SenderSettings(host, options.Port, deviceId, options.KeepAlive, options.FramesPerPacket));
        if (!options.KeepAlive)
            Console.WriteLine("  " + CliStrings.NoKeepAliveTip);
        Console.WriteLine(CliStrings.PressCtrlC);

        var clock = Stopwatch.StartNew();
        long lastBytes = 0;
        while (!stopped.Wait(TimeSpan.FromSeconds(5)))
        {
            SenderSnapshot s = engine.Snapshot;
            double kbps = (s.BytesSent - lastBytes) * 8 / 5.0 / 1000;
            lastBytes = s.BytesSent;
            Console.WriteLine(CliStrings.Progress(clock.Elapsed.ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture),
                                                  s.PacketsSent, kbps.ToString("F0", CultureInfo.CurrentCulture), s.SendErrors));
        }
        engine.Stop();
        Console.WriteLine(CliStrings.Stopped);
        return 0;
    }
}
