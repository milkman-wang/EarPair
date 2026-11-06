using System.Runtime.InteropServices;
using EarPair.App.ViewModels;
using Microsoft.Win32;

namespace EarPair.App.Interop;

/// <summary>
/// 通知区域（托盘）图标：用 Win32 Shell_NotifyIcon 实现，不依赖第三方库。
/// 左键单击触发 Activated，右键弹出原生菜单（Windows 11 上是圆角新样式，尽量跟随深色模式）。
/// 必须在界面线程上创建和使用。
/// </summary>
internal sealed partial class TrayIcon : IDisposable
{
    public sealed record MenuItem(string Title, Action? Action = null, bool IsChecked = false, bool IsEnabled = true,
                                  bool IsDefault = false, IReadOnlyList<MenuItem?>? Children = null);

    private const int CallbackMessage = 0x8000 + 1; // WM_APP + 1
    private const uint IconId = 1;

    private readonly WndProc _wndProc; // 保持委托存活，避免被回收
    private readonly IntPtr _window;
    private readonly uint _taskbarCreatedMessage;
    private readonly string _assets;
    private TrayGlyph _glyph = TrayGlyph.Idle;
    private IntPtr _icon;
    private string _tooltip = "EarPair";
    private bool _added;

    /// <summary>左键单击图标。</summary>
    public event Action? Activated;

    /// <summary>关机或注销（WM_ENDSESSION）：在界面线程上同步触发，处理完才会被结束，要在这里恢复本机声音。</summary>
    public event Action? SessionEnding;

    /// <summary>右键时调用，返回要显示的菜单项；null 表示分隔线。</summary>
    public Func<IReadOnlyList<MenuItem?>>? MenuProvider { get; set; }

    public TrayIcon(string assetsFolder)
    {
        _assets = assetsFolder;
        _wndProc = WindowProc;
        IntPtr instance = GetModuleHandleW(IntPtr.Zero);
        const string className = "EarPairTrayWindow";
        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
            hInstance = instance,
            lpszClassName = className,
        };
        RegisterClassExW(ref windowClass);
        // 普通的隐藏顶层窗口（不是 HWND_MESSAGE），这样才能收到 TaskbarCreated 和主题变化的广播
        _window = CreateWindowExW(0, className, "EarPair", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        _taskbarCreatedMessage = RegisterWindowMessageW("TaskbarCreated");
        DarkMenus.TryEnable();
        _icon = LoadIcon(_glyph);
        Add();
    }

    public void Update(TrayGlyph glyph, string tooltip)
    {
        // 图标和提示都没变就不打扰资源管理器（每次 NIM_MODIFY 它都要重画通知区域）
        bool iconChanged = glyph != _glyph || _icon == IntPtr.Zero;
        if (!iconChanged && tooltip == _tooltip) return;
        if (iconChanged)
        {
            _glyph = glyph;
            IntPtr old = _icon;
            _icon = LoadIcon(glyph);
            if (old != IntPtr.Zero) DestroyIcon(old);
        }
        _tooltip = tooltip;
        var data = CreateData(NIF_TIP | NIF_SHOWTIP | (iconChanged ? NIF_ICON : 0));
        Shell_NotifyIconW(NIM_MODIFY, ref data);
    }

    /// <summary>通知区域的气泡提示（遵守“请勿打扰”）。</summary>
    public void ShowBalloon(string title, string text)
    {
        var data = CreateData(NIF_INFO);
        data.szInfoTitle = title;
        data.szInfo = text;
        data.dwInfoFlags = NIIF_NONE | NIIF_RESPECT_QUIET_TIME;
        Shell_NotifyIconW(NIM_MODIFY, ref data);
    }

    private void Add()
    {
        var data = CreateData(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        _added = Shell_NotifyIconW(NIM_ADD, ref data);
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, ref data);
    }

    private NOTIFYICONDATAW CreateData(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
        hWnd = _window,
        uID = IconId,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = _tooltip.Length > 127 ? _tooltip[..127] : _tooltip,
        szInfo = "",
        szInfoTitle = "",
    };

    /// <summary>按任务栏深浅色挑图标：浅色任务栏用黑色图标，深色用白色</summary>
    private IntPtr LoadIcon(TrayGlyph glyph)
    {
        string name = glyph switch { TrayGlyph.On => "on", TrayGlyph.Warn => "warn", _ => "idle" };
        string theme = TaskbarIsLight() ? "light" : "dark";
        int size = GetSystemMetrics(SM_CXSMICON);
        return LoadImageW(IntPtr.Zero, Path.Combine(_assets, "Tray", $"{name}-{theme}.ico"), IMAGE_ICON, size, size,
                          LR_LOADFROMFILE);
    }

    private static bool TaskbarIsLight()
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int value && value != 0;
    }

    private IntPtr WindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == CallbackMessage)
        {
            // NOTIFYICON_VERSION_4：事件在 lParam 的低 16 位，坐标在 wParam
            switch ((uint)(lParam.ToInt64() & 0xFFFF))
            {
                case NIN_SELECT:
                case NIN_KEYSELECT:
                    Activated?.Invoke();
                    break;
                case WM_CONTEXTMENU:
                    ShowMenu((short)(wParam.ToInt64() & 0xFFFF), (short)((wParam.ToInt64() >> 16) & 0xFFFF));
                    break;
            }
            return IntPtr.Zero;
        }
        if (message == _taskbarCreatedMessage && _taskbarCreatedMessage != 0)
        {
            Add(); // 资源管理器重启后重新加图标
            return IntPtr.Zero;
        }
        if (message == WM_QUERYENDSESSION) return 1; // 同意关机
        if (message == WM_ENDSESSION)
        {
            if (wParam != IntPtr.Zero) SessionEnding?.Invoke();
            return IntPtr.Zero;
        }
        if (message == WM_SETTINGCHANGE && lParam != IntPtr.Zero &&
            Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet")
        {
            // 任务栏深浅色变了：换一套图标
            IntPtr old = _icon;
            _icon = LoadIcon(_glyph);
            if (old != IntPtr.Zero) DestroyIcon(old);
            var data = CreateData(NIF_ICON);
            Shell_NotifyIconW(NIM_MODIFY, ref data);
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private void ShowMenu(int x, int y)
    {
        IReadOnlyList<MenuItem?> items = MenuProvider?.Invoke() ?? [];
        if (items.Count == 0) return;
        var actions = new List<Action?>();
        IntPtr menu = BuildMenu(items, actions);
        try
        {
            // 菜单弹出前窗口必须在前台，否则点菜单外面不会自动关闭
            SetForegroundWindow(_window);
            uint chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, x, y, _window, IntPtr.Zero);
            PostMessageW(_window, WM_NULL, IntPtr.Zero, IntPtr.Zero);
            if (chosen >= 1 && chosen <= actions.Count) actions[(int)chosen - 1]?.Invoke();
        }
        finally
        {
            DestroyMenu(menu); // 子菜单跟着一起销毁
        }
    }

    private static IntPtr BuildMenu(IReadOnlyList<MenuItem?> items, List<Action?> actions)
    {
        IntPtr menu = CreatePopupMenu();
        foreach (MenuItem? item in items)
        {
            if (item is null)
            {
                AppendMenuW(menu, MF_SEPARATOR, UIntPtr.Zero, null);
                continue;
            }
            uint flags = MF_STRING | (item.IsChecked ? MF_CHECKED : 0) | (item.IsEnabled ? 0 : MF_GRAYED);
            if (item.Children is { Count: > 0 } children)
            {
                IntPtr submenu = BuildMenu(children, actions);
                AppendMenuW(menu, flags | MF_POPUP, (UIntPtr)(ulong)submenu, item.Title);
                continue;
            }
            actions.Add(item.Action);
            AppendMenuW(menu, flags, (UIntPtr)(uint)actions.Count, item.Title);
            if (item.IsDefault) SetMenuDefaultItem(menu, (uint)actions.Count, 0);
        }
        return menu;
    }

    public void Dispose()
    {
        if (_added)
        {
            var data = CreateData(0);
            Shell_NotifyIconW(NIM_DELETE, ref data);
            _added = false;
        }
        if (_icon != IntPtr.Zero) DestroyIcon(_icon);
        if (_window != IntPtr.Zero) DestroyWindow(_window);
    }

    /// <summary>让右键菜单跟随系统深色模式（uxtheme 里没有公开名字的两个函数，调用失败就保持浅色）</summary>
    private static class DarkMenus
    {
        private delegate int SetPreferredAppMode(int mode);
        private delegate void FlushMenuThemes();

        public static void TryEnable()
        {
            try
            {
                IntPtr uxtheme = LoadLibraryW("uxtheme.dll");
                if (uxtheme == IntPtr.Zero) return;
                IntPtr setMode = GetProcAddress(uxtheme, 135);
                IntPtr flush = GetProcAddress(uxtheme, 136);
                if (setMode == IntPtr.Zero || flush == IntPtr.Zero) return;
                Marshal.GetDelegateForFunctionPointer<SetPreferredAppMode>(setMode)(1); // AllowDark
                Marshal.GetDelegateForFunctionPointer<FlushMenuThemes>(flush)();
            }
            catch (Exception)
            {
                // 老系统没有这两个函数
            }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadLibraryW(string name);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetProcAddress(IntPtr module, IntPtr ordinal);
    }

    // MARK: - Win32

    private delegate IntPtr WndProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    private const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    private const uint NIF_MESSAGE = 0x1, NIF_ICON = 0x2, NIF_TIP = 0x4, NIF_INFO = 0x10, NIF_SHOWTIP = 0x80;
    private const uint NIIF_NONE = 0x0, NIIF_RESPECT_QUIET_TIME = 0x80;
    private const uint NOTIFYICON_VERSION_4 = 4;
    private const uint NIN_SELECT = 0x400, NIN_KEYSELECT = 0x401;
    private const uint WM_NULL = 0x0, WM_QUERYENDSESSION = 0x11, WM_ENDSESSION = 0x16, WM_SETTINGCHANGE = 0x1A,
                       WM_CONTEXTMENU = 0x7B;
    private const uint MF_STRING = 0x0, MF_GRAYED = 0x1, MF_CHECKED = 0x8, MF_POPUP = 0x10, MF_SEPARATOR = 0x800;
    private const uint TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 0x2, TPM_BOTTOMALIGN = 0x20;
    private const uint IMAGE_ICON = 1, LR_LOADFROMFILE = 0x10;
    private const int SM_CXSMICON = 49;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassExW(ref WNDCLASSEXW windowClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowExW(uint exStyle, string className, string windowName, uint style,
                                                 int x, int y, int width, int height, IntPtr parent, IntPtr menu,
                                                 IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProcW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessageW(string name);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string? text);

    [DllImport("user32.dll")]
    private static extern bool SetMenuDefaultItem(IntPtr menu, uint item, uint byPosition);

    [DllImport("user32.dll")]
    private static extern uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr parameters);

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadImageW(IntPtr instance, string name, uint type, int cx, int cy, uint load);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandleW(IntPtr moduleName);
}
