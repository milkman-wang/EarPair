using System.Globalization;

namespace EarPair.Sender;

/// <summary>命令行参数。</summary>
internal sealed class Options
{
    public const int DefaultPort = 47800;

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
                if (i + 1 >= args.Length) throw new ArgumentException(CliStrings.NeedsValue(arg));
                return args[++i];
            }

            int NextInt(int min, int max)
            {
                string value = NextValue();
                if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int number) ||
                    number < min || number > max)
                    throw new ArgumentException(CliStrings.MustBeInteger(arg, min, max));
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
                        throw new ArgumentException(CliStrings.UnknownArgument(arg));
                    options.Host = arg;
                    break;
            }
        }
        return options;
    }
}
