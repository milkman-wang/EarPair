// EarPair 发送端自检，不需要 Windows 和声卡：
//   dotnet run                              检查格式转换、打包、参数解析、界面文字（英文和简体中文）
//   dotnet run -- send <IP> [秒数] [端口]    用发送端的转换和打包代码发 440 Hz 测试音
//                                           （模拟 WASAPI：48 kHz 立体声浮点，每 10 ms 一块）
//   dotnet run -- hello <IP> [端口]          发 HELLO，等接收端回 STATUS（检查两端的控制包实现一致）
using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Resources;
using System.Text.RegularExpressions;
using EarPair.Sender;
using NAudio.Wave;

if (args.Length > 0 && args[0] == "send")
    return Send(args);
if (args.Length > 0 && args[0] == "hello")
    return Hello(args);

int failures = 0;
Console.WriteLine("EarPair 发送端自检");
TestPacketEncoder();
TestPcmConverter();
TestOptions();
TestControlPacket();
TestStrings();
Console.WriteLine(failures == 0 ? "全部通过" : $"{failures} 项没通过");
return failures == 0 ? 0 : 1;

void Check(bool ok, string name)
{
    Console.WriteLine($"  {(ok ? "✔" : "✘")} {name}");
    if (!ok) failures++;
}

void TestPacketEncoder()
{
    Console.WriteLine("打包：");
    var packets = new List<byte[]>();
    void Collect(byte[] buffer, int length) => packets.Add(buffer.AsSpan(0, length).ToArray());

    // 600 帧，分三块不规则地喂进去（WASAPI 每次给的帧数不固定）
    var frames = new short[600 * 2];
    for (int i = 0; i < 600; i++)
    {
        frames[2 * i] = (short)(i * 3);
        frames[2 * i + 1] = (short)(-i * 3);
    }
    var encoder = new PacketEncoder(48000, 240, 0x01020304);
    encoder.Append(frames.AsSpan(0, 200), Collect);
    encoder.Append(frames.AsSpan(200, 666), Collect);
    encoder.Append(frames.AsSpan(866, 334), Collect);

    Check(packets.Count == 2, "600 帧切出 2 个 240 帧的包，剩下 120 帧等下一批");
    if (packets.Count < 2) return;
    byte[] second = packets[1];
    Check(second.Length == 992, "包长 992 字节");

    // 按 protocol/audio-packet.md 手写的期望包头：streamId 0x01020304、序号 1、sampleTime 240、48000 Hz、240 帧
    byte[] expectedHeader =
    {
        0x45, 0x41, 0x52, 0x50, 0x01, 0x00, 0x01, 0x02,
        0x04, 0x03, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00,
        0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x80, 0xBB, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00,
    };
    Check(second.AsSpan(0, 32).SequenceEqual(expectedHeader), "第二个包的包头与协议文档逐字节一致");

    bool payloadMatches = true;
    for (int i = 0; i < 480; i++)
        if (BinaryPrimitives.ReadInt16LittleEndian(second.AsSpan(32 + i * 2)) != frames[480 + i]) payloadMatches = false;
    Check(payloadMatches, "第二个包的样本正好是输入的第 240–479 帧（跨块拼接正确）");
}

void TestPcmConverter()
{
    Console.WriteLine("格式转换：");
    // WASAPI 共享模式的混音格式通常是 WAVE_FORMAT_EXTENSIBLE + 32-bit 浮点
    var wasapiFormat = new WaveFormatExtensible(48000, 32, 2);
    Check(PcmConverter.IsFloat(wasapiFormat), "认出 Extensible 浮点格式（WASAPI 最常见的格式）");
    Check(PcmConverter.IsFloat(WaveFormat.CreateIeeeFloatWaveFormat(44100, 2)), "认出普通浮点格式");

    short[] floatResult = Convert(wasapiFormat, FloatBytes(0f, 0f, 0.5f, -0.5f, 1f, -1f, 1.5f, -2f, float.NaN, 0.25f));
    Check(floatResult.SequenceEqual(new short[] { 0, 0, 16384, -16384, 32767, -32768, 32767, -32768, 0, 8192 }),
          "浮点 → 16-bit：缩放、超出范围削顶、NaN 变 0");

    // 5.1：FL FR FC LFE BL BR → 立体声
    short[] surround = Convert(new WaveFormatExtensible(48000, 32, 6), FloatBytes(0.1f, 0.2f, 0.3f, 0.9f, 0.05f, 0.04f));
    double expectedLeft = (0.1 + 0.3 * 0.7071 + 0.05 * 0.7071) * 32768;
    double expectedRight = (0.2 + 0.3 * 0.7071 + 0.04 * 0.7071) * 32768;
    Check(surround.Length == 2 && Math.Abs(surround[0] - expectedLeft) <= 1 && Math.Abs(surround[1] - expectedRight) <= 1,
          "5.1 混成立体声（中置和环绕按 0.707 混入，丢掉低音声道）");

    short[] pcm16 = { 1234, -1234, 32767, -32768 };
    var pcm16Bytes = new byte[pcm16.Length * 2];
    for (int i = 0; i < pcm16.Length; i++) BinaryPrimitives.WriteInt16LittleEndian(pcm16Bytes.AsSpan(i * 2), pcm16[i]);
    Check(Convert(new WaveFormat(44100, 16, 2), pcm16Bytes).SequenceEqual(pcm16), "16-bit 立体声原样通过");

    // 24-bit：0x400000 = 半幅正值，0xC00000 = 半幅负值
    byte[] pcm24 = { 0x00, 0x00, 0x40, 0x00, 0x00, 0xC0 };
    Check(Convert(new WaveFormat(48000, 24, 2), pcm24).SequenceEqual(new short[] { 16384, -16384 }), "24-bit 整数");

    Check(Convert(new WaveFormat(48000, 16, 1), new byte[] { 0x10, 0x27 }).SequenceEqual(new short[] { 10000, 10000 }),
          "单声道复制到左右");

    bool rejected;
    try
    {
        _ = new PcmConverter(new WaveFormat(48000, 8, 2));
        rejected = false;
    }
    catch (NotSupportedException)
    {
        rejected = true;
    }
    Check(rejected, "不支持的格式（8-bit）会明确报错");
}

void TestOptions()
{
    Console.WriteLine("命令行参数：");
    var options = Options.Parse(new[] { "192.168.1.20", "--port", "5000", "--frames", "120" });
    Check(options.Host == "192.168.1.20" && options.Port == 5000 && options.FramesPerPacket == 120 && options.KeepAlive,
          "IP 直接写在后面 + --port + --frames");
    Check(Options.Parse(new[] { "--host", "10.0.0.5", "--no-keepalive" }) is { Host: "10.0.0.5", KeepAlive: false },
          "--host 和 --no-keepalive");
    Check(Options.Parse(new[] { "--list-devices" }).ListDevices, "--list-devices");
    Check(Throws(() => Options.Parse(new[] { "--frames", "999" })), "--frames 超出 16–360 时报错");
    Check(Throws(() => Options.Parse(new[] { "--port" })), "--port 缺参数时报错");
    Check(Throws(() => Options.Parse(new[] { "--bogus" })), "未知参数报错");
}

void TestControlPacket()
{
    Console.WriteLine("控制包：");
    byte[] bye = ControlPacket.Encode(new ByeMessage(16909060));
    byte[] expected = System.Convert.FromHexString("4541524301051300" + "7b2273747265616d223a31363930393036307d");
    Check(bye.AsSpan().SequenceEqual(expected), "BYE 和协议文档里的测试向量逐字节一致");
    byte[] byeWithReason = ControlPacket.Encode(new ByeMessage(7, ByeReason.Network));
    Check(ControlPacket.TryParse(byeWithReason, out _, out ReadOnlySpan<byte> byeBody) &&
          System.Text.Encoding.UTF8.GetString(byeBody) == """{"stream":7,"reason":"network"}""",
          "BYE 带上 reason（network：联系不上 Mac 自己暂停）");

    byte[] probe = ControlPacket.Encode(new HelloMessage(null, null, null, null, 1));
    Check(probe.AsSpan().SequenceEqual(System.Convert.FromHexString("4541524301030c00" + "7b2273747265616d223a317d")),
          "HELLO {\"stream\":1} 和协议文档里的测试向量逐字节一致");

    byte[] hello = ControlPacket.Encode(new HelloMessage("abc", "DESKTOP-7Q2", "desktop", "0.2.0", 7));
    Check(ControlPacket.TryParse(hello, out ControlPacket.Kind kind, out ReadOnlySpan<byte> helloBody) &&
          kind == ControlPacket.Kind.Hello &&
          System.Text.Encoding.UTF8.GetString(helloBody).Contains("\"kind\":\"desktop\""),
          "HELLO 带上 kind，能解析回来");

    byte[] standby = ControlPacket.Encode(new HelloMessage(null, null, null, null, 7) { Standby = true, Seq = 42 });
    Check(ControlPacket.TryParse(standby, out _, out ReadOnlySpan<byte> standbyBody) &&
          System.Text.Encoding.UTF8.GetString(standbyBody) == """{"stream":7,"standby":true,"seq":42}""",
          "待机的 HELLO 带上 standby 和恢复后第一个包的序号");

    byte[] status = ControlPacket.Encode(ControlPacket.Kind.Status, System.Text.Encoding.UTF8.GetBytes(
        """{"id":"5f0e","name":"MacBook Air","kind":"laptop","stream":7,"state":"playing","lost":2,"output":"耳机","transport":"headphones","new":[1]}"""));
    StatusMessage? parsed = ControlPacket.ParseStatus(status);
    Check(parsed is { Name: "MacBook Air", Kind: "laptop", Stream: 7, IsPlaying: true, Lost: 2, Output: "耳机",
                      Transport: "headphones" },
          "STATUS 能解析（kind、headphones），不认识的字段忽略");

    Check(parsed is { SupportsStandby: false }, "没有 features 的 STATUS（旧版 Mac）不认得待机");
    StatusMessage? standbyStatus = ControlPacket.ParseStatus(ControlPacket.Encode(ControlPacket.Kind.Status,
        System.Text.Encoding.UTF8.GetBytes("""{"stream":7,"state":"standby","features":["standby","later"]}""")));
    Check(standbyStatus is { IsStandby: true, SupportsStandby: true, IsPlaying: false },
          "STATUS 的 features 里有 standby：Mac 认得待机");

    byte[] wrongLength = status.Concat(new byte[] { 0x20 }).ToArray();
    Check(ControlPacket.ParseStatus(wrongLength) is null, "长度不符的包丢掉");
    byte[] wrongVersion = (byte[])status.Clone();
    wrongVersion[4] = 2;
    Check(ControlPacket.ParseStatus(wrongVersion) is null, "版本不对的包丢掉");
    Check(ControlPacket.ParseStatus(hello) is null, "HELLO 不会被当成 STATUS");
}

void TestStrings()
{
    Console.WriteLine("界面文字：");
    CultureInfo en = CultureInfo.GetCultureInfo("en"), zh = CultureInfo.GetCultureInfo("zh-Hans");
    Check(In(en, () => EarPair.App.Strings.StatusPlaying) == "Playing" &&
          In(zh, () => EarPair.App.Strings.StatusPlaying) == "正在播放",
          "en 和 zh-Hans 都取得到界面文字（正在播放 / Playing）");
    Check(In(CultureInfo.GetCultureInfo("ja"), () => EarPair.App.Strings.StatusPlaying) == "Playing" &&
          In(CultureInfo.InvariantCulture, () => EarPair.App.Strings.StatusPlaying) == "Playing",
          "其他语言和不变区域用英文");
    Check(In(en, () => CoreStrings.HostNotFound("mac.local")) == "Can't find mac.local" &&
          In(zh, () => CoreStrings.HostNotFound("mac.local")) == "找不到 mac.local",
          "引擎的错误带参数（找不到 mac.local）");
    Check(In(en, () => CoreStrings.FormatDescription(48000, 2, 32, isFloat: true)) == "48000 Hz, 2-channel, 32-bit float" &&
          In(zh, () => CoreStrings.FormatDescription(44100, 6, 24, isFloat: false)) == "44100 Hz，6 声道，24-bit 整数",
          "采集格式（浮点、整数）");
    Check(In(en, () => EarPair.App.Strings.BusyPlaying(null)) == "Playing sound from another PC" &&
          In(zh, () => EarPair.App.Strings.BusyPlaying("LAPTOP-Q8")) == "正在播放 LAPTOP-Q8 的声音",
          "Mac 正忙的提示（不知道是哪台电脑时说“另一台电脑”）");
    Check(In(en, () => CliStrings.Usage).StartsWith("Usage: EarPair.Sender <Mac IP address>", StringComparison.Ordinal) &&
          In(zh, () => CliStrings.Usage).StartsWith("用法：EarPair.Sender <Mac 的 IP>", StringComparison.Ordinal),
          "命令行帮助");
    Check(In(en, () => EarPair.App.Strings.ControlLanguage) == "en-US" &&
          In(zh, () => EarPair.App.Strings.ControlLanguage) == "zh-CN",
          "WinUI 控件自带的文字和界面用同一种语言");

    // 每种语言的 .resx 和英文的键一一对应、占位符一致。查的是编译出来的资源（卫星程序集），新加的语言也会查到
    string[] cultures = Directory.GetDirectories(AppContext.BaseDirectory)
        .Where(dir => File.Exists(Path.Combine(dir, "EarPair.Sender.SelfTest.resources.dll")))
        .Select(dir => Path.GetFileName(dir)!)
        .Order(StringComparer.Ordinal)
        .ToArray();
    Check(cultures.Contains("zh-Hans"), $"有简体中文的卫星程序集（{string.Join("、", cultures)}）");
    foreach (Type type in new[] { typeof(CoreStrings), typeof(CliStrings), typeof(EarPair.App.Strings) })
    {
        var resources = new ResourceManager(type);
        Dictionary<string, string> neutral = Entries(resources, CultureInfo.InvariantCulture)!;
        foreach (string culture in cultures)
        {
            Dictionary<string, string>? translated = Entries(resources, CultureInfo.GetCultureInfo(culture));
            var problems = new List<string>();
            if (translated is null)
            {
                problems.Add("没有这种语言的 .resx");
            }
            else
            {
                problems.AddRange(neutral.Keys.Except(translated.Keys).Select(key => $"缺 {key}"));
                problems.AddRange(translated.Keys.Except(neutral.Keys).Select(key => $"多了 {key}"));
                problems.AddRange(neutral.Keys.Intersect(translated.Keys)
                    .Where(key => !Placeholders(neutral[key]).SetEquals(Placeholders(translated[key])))
                    .Select(key => $"{key} 的占位符不一致"));
            }
            Check(problems.Count == 0, $"{type.Name}：{culture} 和英文的键一一对应，占位符一致" +
                                       (problems.Count > 0 ? $"（{string.Join("，", problems)}）" : ""));
        }

        // 访问类里的每一项在两种语言里都取得到，而且不一样：键名写错时两边取到的都是键名，格式不对时会抛异常
        var broken = new List<string>();
        foreach (MemberInfo member in type.GetMembers(BindingFlags.Public | BindingFlags.Static))
        {
            // 方法用样例参数调用；有 bool 参数的两种取值都试（比如采集格式的浮点和整数）
            Func<string>[] calls = member switch
            {
                PropertyInfo property => [() => (string)property.GetValue(null)!],
                MethodInfo { IsSpecialName: false } method when method.ReturnType == typeof(string) =>
                    (method.GetParameters().Any(p => p.ParameterType == typeof(bool)) ? [true, false] : new[] { true })
                    .Select(flag => (Func<string>)(() => (string)method.Invoke(
                        null, method.GetParameters().Select(p => Sample(p.ParameterType, flag)).ToArray())!))
                    .ToArray(),
                _ => [],
            };
            foreach (Func<string> call in calls)
            {
                try
                {
                    if (In(en, call) == In(zh, call)) broken.Add(member.Name);
                }
                catch (TargetInvocationException ex)
                {
                    broken.Add($"{member.Name}（{ex.InnerException?.GetType().Name}）");
                }
            }
        }
        Check(broken.Count == 0, $"{type.Name} 的每一项都有英文和中文" +
                                 (broken.Count > 0 ? $"（{string.Join("，", broken.Distinct())}）" : ""));
    }
}

static string In(CultureInfo culture, Func<string> text)
{
    CultureInfo saved = CultureInfo.CurrentUICulture;
    CultureInfo.CurrentUICulture = culture;
    try
    {
        return text();
    }
    finally
    {
        CultureInfo.CurrentUICulture = saved;
    }
}

/// <summary>只取这种语言自己的 .resx 里的条目（不回退到上一级语言）；没有这种语言时返回 null</summary>
static Dictionary<string, string>? Entries(ResourceManager resources, CultureInfo culture) =>
    resources.GetResourceSet(culture, createIfNotExists: true, tryParents: false)?
        .Cast<System.Collections.DictionaryEntry>()
        .ToDictionary(entry => (string)entry.Key, entry => entry.Value as string ?? "");

static HashSet<string> Placeholders(string text) =>
    Regex.Matches(text, @"\{\d+(,[^}:]*)?(:[^}]*)?\}").Select(match => match.Value).ToHashSet();

static object Sample(Type type, bool flag) =>
    type == typeof(string) || type == typeof(object) ? "x" :
    type == typeof(int) ? 1 :
    type == typeof(uint) ? 1u :
    type == typeof(long) ? 1L :
    type == typeof(bool) ? flag :
    throw new NotSupportedException(type.Name);

static short[] Convert(WaveFormat format, byte[] bytes)
{
    var converter = new PcmConverter(format);
    var output = new short[converter.FrameCount(bytes.Length) * 2];
    converter.ConvertToStereo16(bytes, output);
    return output;
}

static byte[] FloatBytes(params float[] values)
{
    var bytes = new byte[values.Length * 4];
    for (int i = 0; i < values.Length; i++) BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(i * 4), values[i]);
    return bytes;
}

static bool Throws(Action action)
{
    try
    {
        action();
        return false;
    }
    catch (ArgumentException)
    {
        return true;
    }
}

static int Hello(string[] args)
{
    string host = args.Length > 1 ? args[1] : "127.0.0.1";
    int port = args.Length > 2 ? int.Parse(args[2], CultureInfo.InvariantCulture) : Options.DefaultPort;
    using var link = new UdpSender(host, port, receive: true);
    using var received = new ManualResetEventSlim(false);
    StatusMessage? status = null;
    link.ControlReceived += packet =>
    {
        status = ControlPacket.ParseStatus(packet);
        if (status is not null) received.Set();
    };
    link.SendControl(ControlPacket.Encode(new HelloMessage("selftest", "自检", "desktop", "0.2.0", 0)));
    if (!received.Wait(TimeSpan.FromSeconds(3)))
    {
        Console.WriteLine($"3 秒内没有收到 {host}:{port} 的 STATUS");
        return 1;
    }
    Console.WriteLine($"收到 STATUS：{status!.Name}，状态 {status.State}，输出 {status.Output ?? "（无）"}");
    return status.State == "idle" && !string.IsNullOrEmpty(status.Name) ? 0 : 1;
}

static int Send(string[] args)
{
    string host = args.Length > 1 ? args[1] : "127.0.0.1";
    double seconds = args.Length > 2 ? double.Parse(args[2], CultureInfo.InvariantCulture) : 20;
    int port = args.Length > 3 ? int.Parse(args[3], CultureInfo.InvariantCulture) : Options.DefaultPort;

    // 和 AudioCapture 一样的流程：WASAPI 格式的原始字节 → PcmConverter → PacketEncoder → UdpSender
    var format = new WaveFormatExtensible(48000, 32, 2);
    var converter = new PcmConverter(format);
    var encoder = new PacketEncoder(48000, 240, (uint)Random.Shared.NextInt64(1, uint.MaxValue));
    using var sender = new UdpSender(host, port);

    const int chunkFrames = 480;
    var raw = new byte[chunkFrames * 2 * 4];
    var stereo = new short[chunkFrames * 2];
    double phase = 0;
    double step = 2 * Math.PI * 440 / 48000;
    long chunks = (long)(seconds * 100);
    Console.WriteLine($"发送 440 Hz 测试音到 {host}:{port}，{seconds} 秒");

    var clock = Stopwatch.StartNew();
    for (long k = 0; k < chunks; k++)
    {
        for (int i = 0; i < chunkFrames; i++)
        {
            float value = (float)(0.25 * Math.Sin(phase));
            phase += step;
            if (phase > 2 * Math.PI) phase -= 2 * Math.PI;
            BinaryPrimitives.WriteSingleLittleEndian(raw.AsSpan(i * 8), value);
            BinaryPrimitives.WriteSingleLittleEndian(raw.AsSpan(i * 8 + 4), value);
        }
        int frames = converter.ConvertToStereo16(raw, stereo);
        encoder.Append(stereo.AsSpan(0, frames * 2), sender.Send);

        // 按真实时间的节奏：第 k+1 块应在 (k+1) × 10 ms 时发完
        double wait = (k + 1) * 0.010 - clock.Elapsed.TotalSeconds;
        if (wait > 0) Thread.Sleep(TimeSpan.FromSeconds(wait));
    }
    Console.WriteLine($"已发送 {sender.PacketsSent} 包，失败 {sender.SendErrors} 次");
    return sender.SendErrors == 0 ? 0 : 1;
}
