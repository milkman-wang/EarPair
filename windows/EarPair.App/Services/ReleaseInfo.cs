using System.Diagnostics.CodeAnalysis;
using System.Text.Json;

namespace EarPair.App.Services;

/// <summary>发布里的一个文件（GitHub release asset）。Sha256 来自 GitHub 的 digest 字段，旧的发布可能没有。</summary>
public sealed record ReleaseAsset(string Name, long Size, string DownloadUrl, string? Sha256);

/// <summary>
/// GitHub 上的一个正式发布（/releases/latest 的回答）。不依赖界面，自检里也编译这个文件。
/// 安装包按发布流程（.github/workflows/release.yml）的规则命名：EarPair-版本-win-x64-setup.exe / win-arm64。
/// </summary>
public sealed record ReleaseInfo(Version Version, string Tag, string PageUrl, IReadOnlyList<ReleaseAsset> Assets)
{
    /// <summary>解析 /releases/latest 的 JSON；不是正式版（草稿、预发布）或者格式不对时返回 null。</summary>
    public static ReleaseInfo? Parse(string json)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (Bool(root, "draft") || Bool(root, "prerelease")) return null;
            string? tag = Text(root, "tag_name");
            if (tag is null || VersionText.Parse(tag) is not { } version) return null;
            var assets = new List<ReleaseAsset>();
            if (root.TryGetProperty("assets", out JsonElement list) && list.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement asset in list.EnumerateArray())
                {
                    string? name = Text(asset, "name"), url = Text(asset, "browser_download_url");
                    if (name is null || !IsWebUrl(url)) continue;
                    long size = asset.TryGetProperty("size", out JsonElement s) && s.TryGetInt64(out long n) ? n : 0;
                    string? digest = Text(asset, "digest");
                    string? sha256 = digest is not null && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)
                        ? digest["sha256:".Length..].ToLowerInvariant()
                        : null;
                    assets.Add(new ReleaseAsset(name, size, url, sha256));
                }
            }
            string? page = Text(root, "html_url");
            return new ReleaseInfo(version, tag, IsWebUrl(page) ? page : "", assets);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>这台电脑用的安装包；architecture 是 x64 或 arm64</summary>
    public ReleaseAsset? SetupFor(string architecture)
    {
        string expected = $"EarPair-{Version.ToString(3)}-win-{architecture}-setup.exe";
        return Assets.FirstOrDefault(a => string.Equals(a.Name, expected, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>只认 https 地址（下载页会交给系统打开）；http 只给本机的测试服务器用</summary>
    public static bool IsWebUrl([NotNullWhen(true)] string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out Uri? uri) &&
        (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback);

    private static string? Text(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool Bool(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.True;
}

public static class VersionText
{
    /// <summary>“v0.2.1”、“0.2.1”、“0.2.1+e12bcfa…”、“0.2.1-beta” → 0.2.1（只看主、次、修订号）</summary>
    public static Version? Parse(string text)
    {
        string core = text.Trim().TrimStart('v', 'V');
        int cut = core.IndexOfAny(['+', '-', ' ']);
        if (cut >= 0) core = core[..cut];
        string[] parts = core.Split('.');
        if (parts.Length is < 2 or > 4) return null;
        var numbers = new int[3];
        for (int i = 0; i < parts.Length && i < 3; i++)
            if (!int.TryParse(parts[i], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out numbers[i]))
                return null;
        return new Version(numbers[0], numbers[1], numbers[2]);
    }
}
