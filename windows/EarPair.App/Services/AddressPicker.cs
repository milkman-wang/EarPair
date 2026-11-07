using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace EarPair.App.Services;

/// <summary>本机的一个 IPv4 网段，以及它所在网卡的情况</summary>
public sealed record LocalNetwork(IPAddress Address, IPAddress Mask, bool HasGateway, bool Virtual);

/// <summary>
/// Mac 在每个网卡上都广播自己的地址（Wi-Fi、以太网、虚拟机网桥、ZeroTier 这类虚拟局域网……），这里挑一个。
/// 和本机同网段的才连得上；同网段里，真实网卡优先于虚拟网卡（ZeroTier、Tailscale、Hyper-V……：
/// 经它们走要多一层加密和封包），有默认网关的网卡（平时上网用的局域网）优先于没有的。
/// 之前选过的地址只在仍属于最好的一档时继续用：避免来回跳，也不会一直卡在虚拟网卡上。
/// </summary>
public static class AddressPicker
{
    /// <summary>虚拟网卡的说明或名字里常见的词</summary>
    private static readonly string[] VirtualMarkers =
    [
        "ZeroTier", "Tailscale", "WireGuard", "Wintun", "Hyper-V", "vEthernet", "VMware", "VirtualBox",
        "TAP-Windows", "OpenVPN", "Hamachi", "Npcap",
    ];

    public static string? Pick(IEnumerable<string> addresses, string? previous, IReadOnlyList<LocalNetwork> local)
    {
        List<IPAddress> candidates = addresses
            .Select(s => IPAddress.TryParse(s, out IPAddress? ip) ? ip : null)
            .OfType<IPAddress>()
            .Where(ip => ip.AddressFamily == AddressFamily.InterNetwork && !ip.ToString().StartsWith("169.254."))
            .Distinct()
            .ToList();
        if (candidates.Count == 0) return null;

        // 0 真实网卡、有网关；1 真实网卡、没网关；2 虚拟网卡、有网关；3 虚拟网卡、没网关；4 不在本机任何网段
        int Rank(IPAddress ip)
        {
            int best = 4;
            foreach (LocalNetwork n in local)
            {
                if (SameSubnet(ip, n.Address, n.Mask))
                    best = Math.Min(best, (n.Virtual ? 2 : 0) + (n.HasGateway ? 0 : 1));
            }
            return best;
        }

        int top = candidates.Min(Rank);
        List<IPAddress> best = candidates.Where(ip => Rank(ip) == top).ToList();
        return (best.FirstOrDefault(ip => ip.ToString() == previous) ?? best[0]).ToString();
    }

    /// <summary>本机现在启用的网卡上的 IPv4 网段</summary>
    public static List<LocalNetwork> Current()
    {
        var result = new List<LocalNetwork>();
        try
        {
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                IPInterfaceProperties properties = nic.GetIPProperties();
                bool gateway = properties.GatewayAddresses.Any(g =>
                    g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
                bool isVirtual = IsVirtual(nic.NetworkInterfaceType, nic.Description, nic.Name);
                foreach (UnicastIPAddressInformation info in properties.UnicastAddresses)
                {
                    if (info.Address.AddressFamily == AddressFamily.InterNetwork && info.IPv4Mask is not null)
                        result.Add(new LocalNetwork(info.Address, info.IPv4Mask, gateway, isVirtual));
                }
            }
        }
        catch (NetworkInformationException)
        {
            // 取不到就不按网段挑
        }
        return result;
    }

    public static bool IsVirtual(NetworkInterfaceType type, string description, string name) =>
        type is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp ||
        VirtualMarkers.Any(m => description.Contains(m, StringComparison.OrdinalIgnoreCase) ||
                                name.Contains(m, StringComparison.OrdinalIgnoreCase));

    private static bool SameSubnet(IPAddress a, IPAddress b, IPAddress mask)
    {
        byte[] x = a.GetAddressBytes(), y = b.GetAddressBytes(), m = mask.GetAddressBytes();
        for (int i = 0; i < 4; i++)
            if ((x[i] & m[i]) != (y[i] & m[i])) return false;
        return true;
    }
}
