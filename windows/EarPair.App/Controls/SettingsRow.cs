using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EarPair.App.Controls;

/// <summary>设置卡：左边图标、中间名称、右边放控件。模板在 Themes/Generic.xaml。</summary>
public sealed class SettingsRow : ContentControl
{
    public static readonly DependencyProperty GlyphProperty =
        DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(SettingsRow), new PropertyMetadata(null));

    public static readonly DependencyProperty HeaderProperty =
        DependencyProperty.Register(nameof(Header), typeof(string), typeof(SettingsRow), new PropertyMetadata(null));

    public SettingsRow() => DefaultStyleKey = typeof(SettingsRow);

    public string? Glyph
    {
        get => (string?)GetValue(GlyphProperty);
        set => SetValue(GlyphProperty, value);
    }

    public string? Header
    {
        get => (string?)GetValue(HeaderProperty);
        set => SetValue(HeaderProperty, value);
    }
}
