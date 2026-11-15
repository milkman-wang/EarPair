using System.Net;

namespace EarPair.App.Services;

/// <summary>
/// 目标 Mac 的局域网地址变了（换了 Wi-Fi、DHCP 换了 IP、插上了网线……）时，决定换到哪个地址。
/// Bonjour 报的“最好的地址”和正在用的不一样：联系不上就换；更好（比如从 ZeroTier 换到同一个局域网）也换。
/// 最好的地址也联系不上（Windows 有时还在报旧地址）：挨个试这台 Mac 最近报告过的其他地址。
/// </summary>
public static class AddressFollower
{
    /// <param name="current">正在用的地址</param>
    /// <param name="best">Bonjour 现在挑的地址</param>
    /// <param name="addresses">这台 Mac 最近报告过的所有地址，最近报告的在前</param>
    /// <param name="unreachable">正在用的地址联系不上</param>
    /// <param name="tried">这次联系不上以后已经试过的地址</param>
    /// <returns>要换成的地址；不换是 null</returns>
    public static string? Next(string current, string? best, IReadOnlyList<string> addresses, bool unreachable,
                               IReadOnlyCollection<string> tried, IReadOnlyList<LocalNetwork> local)
    {
        // 手动填的主机名由系统解析，不替换
        if (!IPAddress.TryParse(current, out _)) return null;
        if (best is not null && best != current && !tried.Contains(best))
        {
            if (unreachable || AddressPicker.Pick([current, best], current, local) == best) return best;
        }
        if (!unreachable) return null;
        // 按 AddressPicker 的档次试（同一档里最近报告的先试）；不在本机任何网段的也试，可能经路由能到
        return addresses
            .Where(a => a != current && !tried.Contains(a) && AddressPicker.Pick([a], null, local) is not null)
            .OrderBy(a => AddressPicker.Rank(IPAddress.Parse(a), local))
            .FirstOrDefault();
    }
}
