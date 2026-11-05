namespace EarPair.Sender;

/// <summary>命令行参数。</summary>
internal sealed class Options
{
    public const int DefaultPort = 47800;

    public const string Usage = """
        用法：EarPair.Sender <Mac 的 IP> [选项]

          --port N          Mac 接收端的 UDP 端口（默认 47800）
          --device 名称     采集哪个输出设备（名称里包含这段文字即可；默认是系统默认输出设备）
          --list-devices    列出所有输出设备
          --frames N        每包帧数（默认 240，48 kHz 下是 5 ms；最多 360）
          --no-keepalive    不播放静音保活（Windows 没声音时会停止发包，Mac 端会显示断开）
          -h, --help        显示帮助

        示例：EarPair.Sender 192.168.1.20
        """;

    public string? Host { get; private set; }
    public int Port { get; private set; } = DefaultPort;
    public string? DeviceFilter { get; private set; }
    public int FramesPerPacket { get; private set; } = 240;
    public bool KeepAlive { get; private set; } = true;
    public bool ListDevices { get; private set; }
    public bool ShowHelp { get; private set; }

    /// <exception cref="ArgumentException">参数不对</exception>
    public static Options Parse(string[] args)
    {
        var options = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];

            string NextValue()
            {
                if (i + 1 >= args.Length) throw new ArgumentException($"{arg} 需要一个参数");
                return args[++i];
            }

            int NextInt(int min, int max)
            {
                string value = NextValue();
                if (!int.TryParse(value, out int number) || number < min || number > max)
                    throw new ArgumentException($"{arg} 必须是 {min}–{max} 之间的整数");
                return number;
            }

            switch (arg)
            {
                case "--host": options.Host = NextValue(); break;
                case "--port": options.Port = NextInt(1, 65535); break;
                case "--device": options.DeviceFilter = NextValue(); break;
                case "--frames": options.FramesPerPacket = NextInt(16, 360); break;
                case "--no-keepalive": options.KeepAlive = false; break;
                case "--list-devices": options.ListDevices = true; break;
                case "-h":
                case "--help": options.ShowHelp = true; break;
                default:
                    if (arg.StartsWith('-') || options.Host is not null)
                        throw new ArgumentException($"未知参数：{arg}");
                    options.Host = arg;
                    break;
            }
        }
        return options;
    }
}
