using System.Numerics;
using EarPair.App.ViewModels;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace EarPair.App.Controls;

/// <summary>连线用到的颜色（从当前主题取，见 SignalPath 的探针）</summary>
public readonly record struct LinkPalette(Color Accent, Color Secondary, Color Tertiary, Color Inactive, Color Caution,
                                          Color Critical);

/// <summary>
/// 路线上的一段连线，全部画在合成层上，动画由合成器自己跑，不占界面线程。
/// 线型和 Mac 一样：点线（静止或流动）、淡色实线、实线加光点、灰线、黄色短划线加 ⚠、红线加 ✕。
/// 会动的线型：图形比线段多画一个周期，裁到线段范围内，整体从 −周期 平移到 0 循环，所以整段线是同步移动的。
/// </summary>
public sealed partial class SignalLink : Grid
{
    private const float Thickness = 3;
    /// <summary>光点的间距和速度（DIP、DIP/s）</summary>
    private const float PulsePeriod = 26, PulseSpeed = 40;
    /// <summary>⚠ / ✕ 在线中间留出的缺口</summary>
    private const float MarkGap = 28;

    private readonly FontIcon _mark = new()
    {
        FontSize = 16,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Visibility = Visibility.Collapsed,
    };

    private ContainerVisual? _root;
    private ShapeVisual? _line;
    private ShapeVisual? _pulses;
    /// <summary>光点的平移动画在跑：只在有声音时跑，没声音（看不见）或最小化时停掉</summary>
    private bool _sliding;
    private LinkLook _look = LinkLook.Inactive;
    private LinkPalette? _palette;
    private bool _animate = true;
    private float _intensity;

    public SignalLink()
    {
        Children.Add(_mark);
        SizeChanged += (_, _) => Rebuild();
        Unloaded += (_, _) => Clear();
        Loaded += (_, _) => Rebuild();
    }

    /// <summary>光点亮度 0…1（没声音时是 0，光点看不见）</summary>
    public float Intensity
    {
        get => _intensity;
        set
        {
            float intensity = Math.Clamp(value, 0, 1);
            if (intensity == _intensity) return;
            _intensity = intensity;
            ApplyIntensity();
        }
    }

    public void Update(LinkLook look, LinkPalette palette, bool animate)
    {
        if (look == _look && palette == _palette && animate == _animate && _root is not null) return;
        _look = look;
        _palette = palette;
        _animate = animate;
        Rebuild();
    }

    private void ApplyIntensity()
    {
        if (_look != LinkLook.Flowing) return;
        if (_pulses is not null)
        {
            _pulses.Opacity = _intensity;
            bool sound = _intensity > 0;
            if (sound && !_sliding) Slide(_pulses.Compositor, _pulses, PulsePeriod, PulsePeriod / PulseSpeed);
            else if (!sound && _sliding) _pulses.StopAnimation("Offset.X");
            _sliding = sound;
        }
        // 关掉了动画效果：没有光点，实线本身随电平变亮
        else if (_line is not null) _line.Opacity = 0.35f + 0.65f * _intensity;
    }

    private void Clear()
    {
        ElementCompositionPreview.SetElementChildVisual(this, null);
        _root?.Dispose();
        _root = null;
        _line = null;
        _pulses = null;
        _sliding = false;
    }

    private void Rebuild()
    {
        Clear();
        float width = (float)ActualWidth, height = (float)ActualHeight;
        bool marked = _look is LinkLook.Warning or LinkLook.Failed;
        _mark.Visibility = marked ? Visibility.Visible : Visibility.Collapsed;
        if (width < 2 || height < Thickness || _palette is not { } palette || !IsLoaded) return;

        if (marked)
        {
            _mark.Glyph = _look == LinkLook.Warning ? "" : "";
            _mark.Foreground = new SolidColorBrush(_look == LinkLook.Warning ? palette.Caution : palette.Critical);
        }

        Compositor compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        ContainerVisual root = compositor.CreateContainerVisual();
        root.Size = new Vector2(width, height);
        root.Clip = compositor.CreateInsetClip(); // 移动的图形裁到线段范围内
        float y = height / 2 - Thickness / 2;
        // 有 ⚠ / ✕ 时线在中间断开
        (float Start, float End)[] spans = marked
            ? [(0, Math.Max(0, width / 2 - MarkGap / 2)), (Math.Min(width, width / 2 + MarkGap / 2), width)]
            : [(0, width)];

        switch (_look)
        {
            case LinkLook.Waiting:
                root.Children.InsertAtTop(Dots(compositor, width, y, palette.Tertiary, moving: false));
                break;
            case LinkLook.Connecting:
                root.Children.InsertAtTop(Dots(compositor, width, y, palette.Secondary, moving: _animate));
                break;
            case LinkLook.Quiet:
                _line = Bars(compositor, width, y, palette.Accent, spans, 0.35f);
                root.Children.InsertAtTop(_line);
                break;
            case LinkLook.Flowing:
                _line = Bars(compositor, width, y, palette.Accent, spans, 0.35f);
                root.Children.InsertAtTop(_line);
                if (_animate)
                {
                    _pulses = Pulses(compositor, width, y, palette.Accent);
                    root.Children.InsertAtTop(_pulses);
                }
                break;
            case LinkLook.Inactive:
                root.Children.InsertAtTop(Bars(compositor, width, y, palette.Inactive, spans, 1));
                break;
            case LinkLook.Warning:
                foreach ((float start, float end) in spans)
                    root.Children.InsertAtTop(Dashes(compositor, start, end, y, palette.Caution));
                break;
            case LinkLook.Failed:
                root.Children.InsertAtTop(Bars(compositor, width, y, palette.Critical, spans, 0.6f));
                break;
        }
        _root = root;
        ElementCompositionPreview.SetElementChildVisual(this, root);
        ApplyIntensity();
    }

    /// <summary>实线（圆头），可以分成几段</summary>
    private static ShapeVisual Bars(Compositor c, float width, float y, Color color, (float Start, float End)[] spans,
                                    float opacity)
    {
        ShapeVisual visual = Shapes(c, width);
        foreach ((float start, float end) in spans)
            if (end - start >= Thickness) visual.Shapes.Add(Pill(c, start, y, end - start, color));
        visual.Opacity = opacity;
        return visual;
    }

    /// <summary>3 px 圆点，间距 7；流动时以 24 DIP/s 向右走</summary>
    private static ShapeVisual Dots(Compositor c, float width, float y, Color color, bool moving)
    {
        const float period = 7;
        ShapeVisual visual = Shapes(c, width + period);
        for (float x = moving ? 0 : 0.5f; x + Thickness <= width + (moving ? period : 0); x += period)
            visual.Shapes.Add(Pill(c, x, y, Thickness, color));
        if (moving) Slide(c, visual, period, period / 24f);
        return visual;
    }

    /// <summary>10×3 的光点，间距 26，以 40 DIP/s 向右走；整体的不透明度就是亮度。动画在 ApplyIntensity 里按有没有声音启停</summary>
    private static ShapeVisual Pulses(Compositor c, float width, float y, Color color)
    {
        const float length = 10;
        ShapeVisual visual = Shapes(c, width + PulsePeriod);
        for (float x = 0; x < width + PulsePeriod; x += PulsePeriod) visual.Shapes.Add(Pill(c, x, y, length, color));
        visual.Offset = new Vector3(-PulsePeriod, 0, 0);
        visual.Opacity = 0;
        return visual;
    }

    /// <summary>6×3 的短划线，间距 10，静止</summary>
    private static ShapeVisual Dashes(Compositor c, float start, float end, float y, Color color)
    {
        ShapeVisual visual = Shapes(c, end);
        for (float x = start; x + 6 <= end; x += 10) visual.Shapes.Add(Pill(c, x, y, 6, color));
        return visual;
    }

    private static ShapeVisual Shapes(Compositor c, float width)
    {
        ShapeVisual visual = c.CreateShapeVisual();
        visual.Size = new Vector2(width, 64);
        return visual;
    }

    private static CompositionSpriteShape Pill(Compositor c, float x, float y, float length, Color color)
    {
        CompositionRoundedRectangleGeometry geometry = c.CreateRoundedRectangleGeometry();
        geometry.Size = new Vector2(length, Thickness);
        geometry.CornerRadius = new Vector2(Thickness / 2, Thickness / 2);
        geometry.Offset = new Vector2(x, y);
        CompositionSpriteShape shape = c.CreateSpriteShape(geometry);
        shape.FillBrush = c.CreateColorBrush(color);
        return shape;
    }

    /// <summary>从 −周期 平移到 0，线性，一直循环</summary>
    private static void Slide(Compositor c, Visual visual, float period, float seconds)
    {
        ScalarKeyFrameAnimation slide = c.CreateScalarKeyFrameAnimation();
        slide.InsertKeyFrame(0f, -period);
        slide.InsertKeyFrame(1f, 0f, c.CreateLinearEasingFunction());
        slide.Duration = TimeSpan.FromSeconds(seconds);
        slide.IterationBehavior = AnimationIterationBehavior.Forever;
        visual.StartAnimation("Offset.X", slide);
    }
}
