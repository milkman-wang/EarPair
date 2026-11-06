using EarPair.App.ViewModels;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace EarPair.App.Controls;

/// <summary>
/// 音频路线：这台电脑 → Mac（→ Mac 的输出设备）。节点是中性色，状态画在连线上，参数和 Mac 端一致。
/// 整条路线对屏幕阅读器是一个元素。
/// </summary>
public sealed partial class SignalPath : UserControl
{
    private readonly bool _animations = new UISettings().AnimationsEnabled;
    private PathView? _path;

    public SignalPath()
    {
        InitializeComponent();
        foreach (UIElement child in Layout.Children)
            AutomationProperties.SetAccessibilityView(child, AccessibilityView.Raw);
        // 主题变了：探针上的 ThemeResource 更新之后再取颜色重画连线
        ActualThemeChanged += (_, _) => DispatcherQueue.TryEnqueue(ApplyLinks);
    }

    /// <summary>有正在走光点的连线（这时才需要取电平）</summary>
    public bool HasFlowing =>
        _path is { } p && (p.First == LinkLook.Flowing || p.Output is not null && p.Second == LinkLook.Flowing);

    public void Apply(PathView path, string description)
    {
        _path = path;
        PcNode.Apply(path.Pc);
        MacNode.Apply(path.Mac);
        bool output = path.Output is not null;
        OutputNode.Visibility = output ? Visibility.Visible : Visibility.Collapsed;
        SecondLink.Visibility = output ? Visibility.Visible : Visibility.Collapsed;
        if (path.Output is { } node) OutputNode.Apply(node);
        AutomationProperties.SetName(this, description);
        ApplyLinks();
    }

    /// <summary>光点亮度 0…1</summary>
    public void SetIntensity(float value)
    {
        FirstLink.Intensity = value;
        SecondLink.Intensity = value;
    }

    private void ApplyLinks()
    {
        if (_path is not { } path) return;
        var palette = new LinkPalette(Probe(AccentProbe), Probe(SecondaryProbe), Probe(TertiaryProbe),
                                      Probe(InactiveProbe), Probe(CautionProbe), Probe(CriticalProbe));
        FirstLink.Update(path.First, palette, _animations);
        SecondLink.Update(path.Second, palette, _animations);
    }

    private static Windows.UI.Color Probe(Border probe) => probe.Background is SolidColorBrush brush ? brush.Color : Colors.Gray;

    protected override AutomationPeer OnCreateAutomationPeer() => new PathPeer(this);

    /// <summary>让屏幕阅读器把整条路线当成一张图读出它的名字</summary>
    private sealed partial class PathPeer(SignalPath owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;
        protected override bool IsControlElementCore() => true;
        protected override bool IsContentElementCore() => true;
    }
}
