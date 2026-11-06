using EarPair.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EarPair.App.Controls;

/// <summary>路线上的一个设备节点。颜色都在 XAML 里用 ThemeResource，切换深浅色时自动跟着变。</summary>
public sealed partial class SignalNode : UserControl
{
    public SignalNode() => InitializeComponent();

    public void Apply(NodeView node)
    {
        Icon.Glyph = node.Glyph;
        FaintIcon.Glyph = node.Glyph;
        NameText.Text = node.Name;
        FaintNameText.Text = node.Name;

        bool placeholder = node.Look == NodeLook.Placeholder;
        bool faint = node.Look != NodeLook.Normal;
        Disc.Visibility = placeholder ? Visibility.Collapsed : Visibility.Visible;
        Ring.Visibility = placeholder ? Visibility.Visible : Visibility.Collapsed;
        Icon.Visibility = placeholder ? Visibility.Collapsed : Visibility.Visible;
        FaintIcon.Visibility = placeholder ? Visibility.Visible : Visibility.Collapsed;
        NameText.Visibility = faint ? Visibility.Collapsed : Visibility.Visible;
        FaintNameText.Visibility = faint ? Visibility.Visible : Visibility.Collapsed;
        Circle.Opacity = node.Look == NodeLook.Dimmed ? 0.45 : 1;
        Badge.Visibility = node.Muted ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(this, string.IsNullOrEmpty(node.ToolTip) ? null : node.ToolTip);
    }
}
