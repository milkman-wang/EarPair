using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace EarPair.App.Interop;

internal static class WindowHelper
{
    /// <summary>窗口所在显示器的缩放比例（100% = 1.0）。AppWindow 的尺寸单位是物理像素，要乘上它。</summary>
    public static double Scale(Window window)
    {
        IntPtr hwnd = WindowNative.GetWindowHandle(window);
        uint dpi = GetDpiForWindow(hwnd);
        return dpi == 0 ? 1 : dpi / 96.0;
    }

    /// <summary>按逻辑尺寸（DIP）设置窗口大小，并居中到当前显示器的工作区。</summary>
    public static void ResizeAndCenter(Window window, int width, int height)
    {
        double scale = Scale(window);
        AppWindow appWindow = window.AppWindow;
        var size = new Windows.Graphics.SizeInt32((int)(width * scale), (int)(height * scale));
        DisplayArea area = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary);
        Windows.Graphics.RectInt32 work = area.WorkArea;
        appWindow.MoveAndResize(new Windows.Graphics.RectInt32(
            work.X + (work.Width - size.Width) / 2, work.Y + (work.Height - size.Height) / 2, size.Width, size.Height));
    }

    /// <summary>最小窗口尺寸（DIP）。</summary>
    public static void SetMinimumSize(Window window, int width, int height)
    {
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            double scale = Scale(window);
            presenter.PreferredMinimumWidth = (int)(width * scale);
            presenter.PreferredMinimumHeight = (int)(height * scale);
        }
    }

    /// <summary>把窗口带到前台（从通知区域打开时用）。</summary>
    public static void BringToFront(Window window)
    {
        IntPtr hwnd = WindowNative.GetWindowHandle(window);
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
    }

    private const int SW_RESTORE = 9;

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);
}
