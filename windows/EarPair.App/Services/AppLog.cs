namespace EarPair.App.Services;

/// <summary>
/// 日志：%LOCALAPPDATA%\EarPair\logs\earpair-yyyyMMdd.log，保留 7 天。
/// 记录启动参数、设备和格式、状态切换、错误；出问题时从窗口右上角“⋯ → 打开日志文件夹”找到它。
/// </summary>
public static class AppLog
{
    private static readonly object Gate = new();

    public static string Folder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EarPair", "logs");

    /// <summary>--demo 时不写</summary>
    public static bool Enabled { get; set; } = true;

    public static void Write(string message)
    {
        if (!Enabled) return;
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Folder);
                string file = Path.Combine(Folder, $"earpair-{DateTime.Now:yyyyMMdd}.log");
                File.AppendAllText(file, $"{DateTime.Now:HH:mm:ss.fff}  {message}{Environment.NewLine}");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 写不了日志不影响使用
        }
    }

    /// <summary>删掉 7 天前的日志</summary>
    public static void Prune()
    {
        try
        {
            if (!Directory.Exists(Folder)) return;
            DateTime cutoff = DateTime.Now.AddDays(-7);
            foreach (string file in Directory.GetFiles(Folder, "earpair-*.log"))
                if (File.GetLastWriteTime(file) < cutoff) File.Delete(file);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
