using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Windows.Devices.Enumeration;

namespace EarPair.App.Services;

/// <summary>局域网里一台在接收 EarPair 的 Mac（Mac 端用 Bonjour 广播 _earpair._udp）。MacId、Kind 来自 TXT 记录。</summary>
public sealed record DiscoveredMac(string Id, string Name, string Address, int Port, string? MacId, string? Kind = null);

/// <summary>
/// 用 Windows 自带的 DNS-SD（mDNS）浏览局域网里的 Mac，不需要第三方库，也不会弹防火墙提示。
/// Changed 事件在系统线程上触发，界面自己切回界面线程。
/// </summary>
public sealed class MacDiscovery : IDisposable
{
    private const string DnssdProtocol = "{4526e8c1-8aac-4153-9b16-55e86ada0e54}";
    private const string ServiceType = "_earpair._udp";
    private static readonly string[] Properties =
    [
        "System.Devices.Dnssd.InstanceName",
        "System.Devices.Dnssd.HostName",
        "System.Devices.Dnssd.PortNumber",
        "System.Devices.IpAddress",
        "System.Devices.Dnssd.TextAttributes",
    ];

    private readonly object _lock = new();
    private readonly Dictionary<string, DiscoveredMac> _macs = new();
    /// <summary>每台 Mac 见过的全部地址：每次更新可能只带其中一部分</summary>
    private readonly Dictionary<string, HashSet<string>> _addresses = new();
    private DeviceWatcher? _watcher;

    public event Action? Changed;

    /// <summary>第一轮扫描已经完成（之后列表还是空的就是没找到）</summary>
    public bool EnumerationCompleted { get; private set; }

    public IReadOnlyList<DiscoveredMac> Macs
    {
        get
        {
            lock (_lock) return _macs.Values.OrderBy(m => m.Name, StringComparer.CurrentCulture).ToList();
        }
    }

    /// <summary>重新扫描：清空列表，重启浏览</summary>
    public void Restart()
    {
        Dispose();
        lock (_lock)
        {
            _macs.Clear();
            _addresses.Clear();
        }
        Changed?.Invoke();
        Start();
    }

    public void Start()
    {
        if (_watcher is not null) return;
        EnumerationCompleted = false;
        string query = $"System.Devices.AepService.ProtocolId:=\"{DnssdProtocol}\" AND " +
                       $"System.Devices.Dnssd.Domain:=\"local\" AND System.Devices.Dnssd.ServiceName:=\"{ServiceType}\"";
        _watcher = DeviceInformation.CreateWatcher(query, Properties, DeviceInformationKind.AssociationEndpointService);
        _watcher.Added += (_, info) => Update(info.Id, info.Properties);
        _watcher.Updated += (_, update) => Update(update.Id, update.Properties);
        _watcher.Removed += (_, update) => Remove(update.Id);
        _watcher.EnumerationCompleted += (_, _) =>
        {
            EnumerationCompleted = true;
            Changed?.Invoke();
        };
        _watcher.Start();
    }

    private void Update(string id, IReadOnlyDictionary<string, object> properties)
    {
        // Bonjour 会把同一台 Mac 的信息分几次送来，大多数时候什么都没变：没变就不通知
        lock (_lock)
        {
            _macs.TryGetValue(id, out DiscoveredMac? old);
            string? name = properties.TryGetValue(Properties[0], out object? n) ? n as string : null;
            name ??= old?.Name;
            int port = properties.TryGetValue(Properties[2], out object? p) && p is not null ? Convert.ToInt32(p) : old?.Port ?? 0;
            if (!_addresses.TryGetValue(id, out HashSet<string>? seen)) _addresses[id] = seen = [];
            if (properties.TryGetValue(Properties[3], out object? a) && a is string[] list) seen.UnionWith(list);
            string? address = PickAddress(seen, old?.Address);
            if (name is null || address is null || port == 0) return; // 信息还不全，等 Updated
            string[]? text = properties.TryGetValue(Properties[4], out object? t) ? t as string[] : null;
            string? Txt(string key) =>
                text?.Select(entry => entry.Split('=', 2)).FirstOrDefault(kv => kv.Length == 2 && kv[0] == key)?[1];
            string? macId = Txt("id") ?? old?.MacId;
            string? kind = Txt("kind") is "laptop" or "desktop" ? Txt("kind") : old?.Kind;
            var mac = new DiscoveredMac(id, name, address, port, macId, kind);
            if (mac == old) return;
            _macs[id] = mac;
        }
        Changed?.Invoke();
    }

    private void Remove(string id)
    {
        bool removed;
        lock (_lock)
        {
            removed = _macs.Remove(id);
            _addresses.Remove(id);
        }
        if (removed) Changed?.Invoke();
    }

    /// <summary>
    /// Mac 在每个网卡上都会广播自己的地址（Wi-Fi、虚拟机网桥、VPN……）。
    /// 选和本机某个网卡在同一网段的 IPv4 地址；之前选过的地址还在就继续用，避免来回跳。
    /// </summary>
    private static string? PickAddress(IEnumerable<string> addresses, string? previous)
    {
        List<IPAddress> candidates = addresses
            .Select(s => IPAddress.TryParse(s, out IPAddress? ip) ? ip : null)
            .OfType<IPAddress>()
            .Where(ip => ip.AddressFamily == AddressFamily.InterNetwork && !ip.ToString().StartsWith("169.254."))
            .ToList();
        if (candidates.Count == 0) return null;
        List<(IPAddress Address, IPAddress Mask)> local = LocalNetworks();
        bool OnLink(IPAddress ip) => local.Any(n => SameSubnet(ip, n.Address, n.Mask));
        IPAddress? kept = candidates.FirstOrDefault(ip => ip.ToString() == previous);
        if (kept is not null && OnLink(kept)) return previous;
        IPAddress? onLink = candidates.FirstOrDefault(OnLink);
        return (onLink ?? kept ?? candidates[0]).ToString();
    }

    private static List<(IPAddress, IPAddress)> LocalNetworks()
    {
        var result = new List<(IPAddress, IPAddress)>();
        try
        {
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                foreach (UnicastIPAddressInformation info in nic.GetIPProperties().UnicastAddresses)
                {
                    if (info.Address.AddressFamily == AddressFamily.InterNetwork && info.IPv4Mask is not null)
                        result.Add((info.Address, info.IPv4Mask));
                }
            }
        }
        catch (NetworkInformationException)
        {
            // 取不到就不按网段挑
        }
        return result;
    }

    private static bool SameSubnet(IPAddress a, IPAddress b, IPAddress mask)
    {
        byte[] x = a.GetAddressBytes(), y = b.GetAddressBytes(), m = mask.GetAddressBytes();
        for (int i = 0; i < 4; i++)
            if ((x[i] & m[i]) != (y[i] & m[i])) return false;
        return true;
    }

#if DEBUG
    /// <summary>--demo：直接放几台假的 Mac，不扫描</summary>
    public void ShowDemo(IEnumerable<DiscoveredMac> macs)
    {
        lock (_lock)
        {
            _macs.Clear();
            foreach (DiscoveredMac mac in macs) _macs[mac.Id] = mac;
        }
        EnumerationCompleted = true;
        Changed?.Invoke();
    }
#endif

    public void Dispose()
    {
        if (_watcher is { } watcher && watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted)
            watcher.Stop();
        _watcher = null;
    }
}
