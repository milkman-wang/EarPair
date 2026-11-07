using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace EarPair.App.Services;

public enum UpdateState
{
    /// <summary>还没检查过，或者自动检查失败了（只记日志，界面不打扰）</summary>
    Idle,
    Checking,
    UpToDate,
    /// <summary>有新版本，而且有这台电脑能用的安装包</summary>
    Available,
    Downloading,
    /// <summary>安装程序已经启动，EarPair 马上退出</summary>
    Installing,
    /// <summary>手动检查失败</summary>
    CheckFailed,
    /// <summary>下载、校验或启动安装程序失败（Latest 还在，可以重试或去下载页）</summary>
    DownloadFailed,
}

/// <summary>
/// 自动更新：检查 GitHub 上的最新正式版，下载这台电脑架构的安装包，核对大小和 SHA-256（GitHub 给的 digest），
/// 再以静默模式运行安装程序（/SILENT /RELAUNCH=1：只显示进度，装完重新打开 EarPair）。
/// 不碰界面：状态变化时触发 Changed（任意线程），App 自己切回界面线程。
/// </summary>
public sealed class Updater : IDisposable
{
    public const string DefaultFeed = "https://api.github.com/repos/milkman-wang/EarPair/releases/latest";
    /// <summary>测试用：设了这个环境变量就从它指向的地址取发布信息（比如本机的测试服务器）</summary>
    public const string FeedVariable = "EARPAIR_UPDATE_FEED";
    public const string InstallerArguments = "/SILENT /SUPPRESSMSGBOXES /NORESTART /RELAUNCH=1";

    private static readonly TimeSpan CheckTimeout = TimeSpan.FromSeconds(30);
    /// <summary>下载时这么久一点数据都没收到就放弃</summary>
    private static readonly TimeSpan StallTimeout = TimeSpan.FromSeconds(30);

    private readonly HttpClient _http;
    private readonly string _feed;
    private readonly object _gate = new();

    public Version Current { get; }
    /// <summary>x64 或 arm64（安装包名里的写法）</summary>
    public string Architecture { get; }
    public UpdateState State { get; private set; }
    /// <summary>比当前新、能装的那个版本（Available / Downloading / Installing / DownloadFailed 时有）</summary>
    public ReleaseInfo? Latest { get; private set; }
    /// <summary>最近一次检查看到的最新版本号（“已是最新版本”时显示）</summary>
    public Version? LastSeen { get; private set; }
    public int Percent { get; private set; }
    public string? Error { get; private set; }
    /// <summary>最近一次检查是用户手动点的（界面只在手动检查时显示“正在检查”和“已是最新版本”）</summary>
    public bool Manual { get; private set; }

    public static string DownloadFolder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EarPair", "updates");

    /// <summary>状态、进度变了（在任意线程上）</summary>
    public event Action? Changed;

    /// <summary>值得写进日志的事</summary>
    public event Action<string>? Log;

    public Updater(Version current)
    {
        Current = current;
        Architecture = RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
        _feed = Environment.GetEnvironmentVariable(FeedVariable) is { Length: > 0 } feed ? feed : DefaultFeed;
        // 超时自己按步骤控制（检查 30 秒；下载按“多久没收到数据”算，大文件慢网也能下完）
        _http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"EarPair/{current.ToString(3)}");
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    /// <summary>检查有没有新版本。manual：用户点的“检查更新”，失败时界面要说；自动检查失败只记日志。</summary>
    public async Task CheckAsync(bool manual)
    {
        lock (_gate)
        {
            if (State is UpdateState.Checking or UpdateState.Downloading or UpdateState.Installing) return;
            // 自动检查时不打扰界面：已经提示过有新版本的，检查期间照样显示
            if (manual || State != UpdateState.Available) State = UpdateState.Checking;
            Manual = manual;
            Error = null;
        }
        Changed?.Invoke();
        DeleteDownloads(); // 上次更新留下的安装包（那时安装程序还在运行，删不掉）
        try
        {
            using var timeout = new CancellationTokenSource(CheckTimeout);
            string json = await _http.GetStringAsync(_feed, timeout.Token).ConfigureAwait(false);
            ReleaseInfo release = ReleaseInfo.Parse(json) ?? throw new InvalidDataException(Strings.UpdateErrorBadFeed);
            LastSeen = release.Version;
            if (release.Version <= Current)
            {
                if (Settle(UpdateState.UpToDate, null))
                    Log?.Invoke(Strings.LogUpToDate(Current.ToString(3), release.Version.ToString(3)));
            }
            else if (release.SetupFor(Architecture) is null)
            {
                // 发布了但还没有这个架构的安装包（比如还在上传）：当成没有新版本，下次再看
                if (Settle(UpdateState.UpToDate, null))
                    Log?.Invoke(Strings.LogUpdateNoInstaller(release.Version.ToString(3), Architecture));
            }
            else
            {
                bool news = Latest?.Version != release.Version;
                if (Settle(UpdateState.Available, release) && news)
                    Log?.Invoke(Strings.LogUpdateAvailable(Current.ToString(3), release.Version.ToString(3)));
            }
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidDataException or IOException)
        {
            string reason = Describe(ex);
            Log?.Invoke(Strings.LogUpdateCheckFailed(reason));
            // 自动检查失败：已经知道的新版本照样提示，否则什么都不显示
            Settle(manual ? UpdateState.CheckFailed : Latest is null ? UpdateState.Idle : UpdateState.Available, Latest, reason);
        }
    }

    /// <summary>
    /// 记下检查的结果。自动检查时界面上的“更新”按钮一直在，检查期间用户可能已经点了：
    /// 正在下载或安装时不动状态（不然按钮又出来，能再下一份）。
    /// </summary>
    private bool Settle(UpdateState state, ReleaseInfo? latest, string? error = null)
    {
        lock (_gate)
        {
            if (State is UpdateState.Downloading or UpdateState.Installing) return false;
            State = state;
            Latest = latest;
            Error = error;
        }
        Changed?.Invoke();
        return true;
    }

    /// <summary>
    /// 下载、校验、启动安装程序。返回 true 表示安装程序已经启动，调用方应当马上退出 EarPair
    /// （安装程序也会自己关掉它）；失败时状态变成 DownloadFailed，Error 里是原因。
    /// </summary>
    public async Task<bool> DownloadAndInstallAsync()
    {
        ReleaseInfo? release;
        ReleaseAsset? asset;
        lock (_gate)
        {
            release = Latest;
            asset = release?.SetupFor(Architecture);
            if (release is null || asset is null || State is UpdateState.Downloading or UpdateState.Installing) return false;
            State = UpdateState.Downloading;
            Percent = 0;
            Error = null;
        }
        Changed?.Invoke();

        string path = Path.Combine(DownloadFolder, asset.Name), part = path + ".part";
        try
        {
            DeleteDownloads();
            Directory.CreateDirectory(DownloadFolder);

            long received;
            string sha256;
            using (HttpResponseMessage response = await _http.GetAsync(asset.DownloadUrl, HttpCompletionOption.ResponseHeadersRead)
                                                             .ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();
                long total = response.Content.Headers.ContentLength ?? asset.Size;
                await using Stream source = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
                await using FileStream target = File.Create(part);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                byte[] buffer = new byte[128 * 1024];
                received = 0;
                while (true)
                {
                    using var stall = new CancellationTokenSource(StallTimeout);
                    int count = await source.ReadAsync(buffer, stall.Token).ConfigureAwait(false);
                    if (count == 0) break;
                    await target.WriteAsync(buffer.AsMemory(0, count)).ConfigureAwait(false);
                    hash.AppendData(buffer, 0, count);
                    received += count;
                    int percent = total > 0 ? (int)Math.Min(100, received * 100 / total) : 0;
                    if (percent != Percent)
                    {
                        Percent = percent;
                        Changed?.Invoke();
                    }
                }
                sha256 = Convert.ToHexStringLower(hash.GetHashAndReset());
            }
            if (asset.Size > 0 && received != asset.Size || asset.Sha256 is not null && sha256 != asset.Sha256)
                throw new InvalidDataException(Strings.UpdateErrorChecksum);
            File.Move(part, path, overwrite: true);
            Log?.Invoke(Strings.LogUpdateDownloaded(asset.Name, received, asset.Sha256 is null ? Strings.NotChecked : sha256));

            Set(UpdateState.Installing);
            Log?.Invoke(Strings.LogUpdateInstalling(release.Version.ToString(3)));
            Process.Start(new ProcessStartInfo(path, InstallerArguments) { UseShellExecute = true, WorkingDirectory = DownloadFolder });
            return true;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException or
                                       InvalidDataException or IOException or UnauthorizedAccessException or
                                       System.ComponentModel.Win32Exception)
        {
            TryDelete(part);
            if (ex is InvalidDataException) TryDelete(path);
            string reason = Describe(ex);
            Log?.Invoke(Strings.LogUpdateFailed(reason));
            Error = reason;
            Set(UpdateState.DownloadFailed);
            return false;
        }
    }

    private void Set(UpdateState state)
    {
        lock (_gate) State = state;
        Changed?.Invoke();
    }

    private static string Describe(Exception ex) => ex switch
    {
        TaskCanceledException or OperationCanceledException => Strings.UpdateErrorTimeout,
        HttpRequestException { StatusCode: { } code } => $"HTTP {(int)code}",
        _ => ex.Message,
    };

    private static void DeleteDownloads()
    {
        try
        {
            if (!Directory.Exists(DownloadFolder)) return;
            foreach (string file in Directory.GetFiles(DownloadFolder)) TryDelete(file);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 下次再删
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 正在用（比如安装程序还在跑），下次再删
        }
    }

    public void Dispose() => _http.Dispose();
}
