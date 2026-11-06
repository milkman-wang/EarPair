using System.Text.Json;
using System.Text.Json.Serialization;

namespace EarPair.App.Services;

/// <summary>一台 Mac（发送目标）。Id 来自 Mac 的 Bonjour TXT 记录；手动输入的地址没有 Id。</summary>
public sealed class MacTarget
{
    public string? Id { get; set; }
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 47800;
    /// <summary>laptop / desktop（Bonjour TXT 或 STATUS 里报的）；不知道是 null</summary>
    public string? Kind { get; set; }
    /// <summary>收到过它的 STATUS（Mac 0.2 及以上）</summary>
    public bool KnownToReply { get; set; }

    public bool Matches(MacTarget other) =>
        Id is not null && other.Id is not null ? Id == other.Id : string.Equals(Host, other.Host, StringComparison.OrdinalIgnoreCase);
}

/// <summary>保存在 %LOCALAPPDATA%\EarPair\settings.json 的设置。</summary>
public sealed class AppSettings
{
    public int Version { get; set; } = 1;
    /// <summary>这台电脑的 id（控制包 HELLO 里用），第一次运行时生成</summary>
    public string SenderId { get; set; } = "";
    public MacTarget? Target { get; set; }
    /// <summary>用过的 Mac，最多 8 台</summary>
    public List<MacTarget> KnownMacs { get; set; } = [];
    /// <summary>采集的输出设备；null 表示跟随系统默认设备</summary>
    public string? DeviceId { get; set; }
    /// <summary>发送时把本机输出设备静音</summary>
    public bool MuteLocal { get; set; } = true;
    /// <summary>上次退出时开关是开着的：下次启动自动继续</summary>
    public bool Sending { get; set; }
    /// <summary>静音后 loopback 也没声音的设备：不再静音它们</summary>
    public List<string> PostMuteDevices { get; set; } = [];
    /// <summary>被我们静音、还没恢复的设备（异常退出后下次启动恢复）</summary>
    public string? MutedByUs { get; set; }
    /// <summary>已经提示过“EarPair 在后台运行”</summary>
    public bool TrayHintShown { get; set; }
    public double WindowWidth { get; set; }
    public double WindowHeight { get; set; }

    /// <summary>只在内存里用，不写回文件（--demo）</summary>
    [JsonIgnore]
    public bool ReadOnly { get; set; }

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EarPair", "settings.json");

    public static AppSettings Load()
    {
        AppSettings settings = new();
        try
        {
            if (File.Exists(FilePath))
                settings = JsonSerializer.Deserialize(File.ReadAllText(FilePath), SettingsJson.Default.AppSettings) ?? new();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            // 文件坏了：留一份底，用默认设置
            try { File.Move(FilePath, FilePath + ".bad", overwrite: true); } catch (IOException) { }
        }
        if (settings.SenderId.Length != 32)
        {
            settings.SenderId = Guid.NewGuid().ToString("N");
            settings.Save();
        }
        return settings;
    }

    /// <summary>记住一台用过的 Mac（同一台更新信息，最新的放最前面）</summary>
    public void Remember(MacTarget mac)
    {
        KnownMacs.RemoveAll(m => m.Matches(mac));
        KnownMacs.Insert(0, mac);
        if (KnownMacs.Count > 8) KnownMacs.RemoveRange(8, KnownMacs.Count - 8);
    }

    public void Save()
    {
        if (ReadOnly) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            string temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, SettingsJson.Default.AppSettings));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 保存失败不影响使用
        }
    }
}

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(AppSettings))]
internal sealed partial class SettingsJson : JsonSerializerContext;
