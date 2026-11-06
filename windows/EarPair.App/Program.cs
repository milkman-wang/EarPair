using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.Windows.AppLifecycle;

namespace EarPair.App;

/// <summary>入口：只允许运行一个 EarPair；再次打开时把已经运行的那个叫到前台。</summary>
public static partial class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        SetLanguage(ArgumentAfter(args, "--lang"));
        string? demo = null, theme = null;
#if DEBUG
        demo = ArgumentAfter(args, "--demo");
        theme = ArgumentAfter(args, "--theme");
#endif
        AppInstance? current = null;
        if (demo is null)
        {
            current = AppInstance.FindOrRegisterForKey("EarPair");
            if (!current.IsCurrent)
            {
                RedirectTo(current);
                return 0;
            }
        }

        // 控件自带的文字（右键菜单等）和界面文字用同一种语言
        try
        {
            Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = Strings.ControlLanguage;
        }
        catch (Exception)
        {
            // 取不到就用系统语言
        }

        Microsoft.UI.Xaml.Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            var app = new App(args.Contains(Services.Autostart.BackgroundArgument), demo, theme);
            if (current is not null) current.Activated += (_, _) => app.ShowMainWindowFromAnyThread();
        });
        return 0;
    }

    /// <summary>
    /// 已经有一个在运行：把这次激活转给它，自己退出。按官方示例在后台线程上等转发完成，
    /// 界面线程（STA）用 CoWaitForMultipleObjects 等，不直接 .Wait() 卡住。
    /// </summary>
    private static void RedirectTo(AppInstance primary)
    {
        AllowSetForegroundWindow((int)primary.ProcessId); // 让它能把自己的窗口提到前台
        AppActivationArguments activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        using var done = new ManualResetEvent(false);
        Task.Run(() =>
        {
            try
            {
                primary.RedirectActivationToAsync(activation).AsTask().Wait();
            }
            catch (Exception)
            {
                // 转不过去也照样退出
            }
            finally
            {
                done.Set();
            }
        });
        CoWaitForMultipleObjects(0, 0xFFFFFFFF, 1, [done.SafeWaitHandle.DangerousGetHandle()], out _);
    }

    /// <summary>
    /// 界面语言默认跟随 Windows 的显示语言（简体中文，其他语言都用英文）。
    /// 隐藏参数 --lang &lt;语言&gt;（比如 en、zh-Hans）可以指定：在中文系统里检查英文界面、截图用。
    /// 要在创建任何界面和文字之前设好，引擎线程也跟着用。
    /// </summary>
    private static void SetLanguage(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return;
        try
        {
            CultureInfo culture = CultureInfo.GetCultureInfo(name);
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            CultureInfo.CurrentUICulture = culture;
        }
        catch (CultureNotFoundException)
        {
            // 不认识的语言：照常跟随系统
        }
    }

    private static string? ArgumentAfter(string[] args, string name)
    {
        int index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    [DllImport("ole32.dll")]
    private static extern uint CoWaitForMultipleObjects(uint dwFlags, uint dwMilliseconds, ulong nHandles,
                                                        IntPtr[] pHandles, out uint dwIndex);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllowSetForegroundWindow(int dwProcessId);
}
