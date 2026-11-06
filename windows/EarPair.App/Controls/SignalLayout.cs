using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace EarPair.App.Controls;

/// <summary>
/// 路线的排版：子元素依次是 节点、连线、节点（、连线、节点），折叠的不算。
/// 自己算位置而不用 Grid 列：名字可以比圆盘宽、伸到两边，又不会把连线挤开；整条路线居中。
/// </summary>
public sealed partial class SignalLayout : Panel
{
    public const double Disc = 64;
    private const double Pad = 48;
    private const double Gap = 12;

    private (List<UIElement> Nodes, List<UIElement> Links) Parts()
    {
        var nodes = new List<UIElement>();
        var links = new List<UIElement>();
        foreach (UIElement child in Children)
        {
            if (child.Visibility != Visibility.Visible) continue;
            if (child is SignalLink) links.Add(child);
            else nodes.Add(child);
        }
        return (nodes, links);
    }

    /// <summary>相邻两个圆之间的距离、第一个圆的左边、名字的宽度</summary>
    private static (double Link, double X0, double NameWidth) Compute(double width, int count)
    {
        if (count < 2) return (0, (width - Disc) / 2, Math.Min(160, width));
        double link = Math.Clamp((width - 2 * Pad - count * Disc) / (count - 1), 72, 244);
        double x0 = (width - (count * Disc + (count - 1) * link)) / 2;
        double nameWidth = Math.Min(160, Disc + link - 8); // 相邻的名字永远不会重叠
        return (link, x0, nameWidth);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        (List<UIElement> nodes, List<UIElement> links) = Parts();
        double width = double.IsInfinity(availableSize.Width) ? 600 : availableSize.Width;
        (double link, _, double nameWidth) = Compute(width, nodes.Count);
        double height = Disc;
        foreach (UIElement node in nodes)
        {
            node.Measure(new Size(nameWidth, double.PositiveInfinity));
            height = Math.Max(height, node.DesiredSize.Height);
        }
        foreach (UIElement line in links) line.Measure(new Size(Math.Max(0, link - 2 * Gap), Disc));
        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        (List<UIElement> nodes, List<UIElement> links) = Parts();
        (double link, double x0, double nameWidth) = Compute(finalSize.Width, nodes.Count);
        for (int i = 0; i < nodes.Count; i++)
        {
            double center = x0 + Disc / 2 + i * (Disc + link);
            nodes[i].Arrange(new Rect(center - nameWidth / 2, 0, nameWidth, nodes[i].DesiredSize.Height));
            if (i < links.Count && i < nodes.Count - 1)
                links[i].Arrange(new Rect(center + Disc / 2 + Gap, 0, Math.Max(0, link - 2 * Gap), Disc));
        }
        for (int i = Math.Max(0, nodes.Count - 1); i < links.Count; i++) links[i].Arrange(new Rect(0, 0, 0, 0));
        return finalSize;
    }
}
