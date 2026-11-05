using System.Net.Sockets;

namespace EarPair.Sender;

/// <summary>把数据包用 UDP 发给 Mac 接收端。</summary>
internal sealed class UdpSender : IDisposable
{
    private readonly UdpClient _client;

    public long PacketsSent { get; private set; }
    public long BytesSent { get; private set; }
    public long SendErrors { get; private set; }

    public UdpSender(string host, int port)
    {
        _client = new UdpClient();
        _client.Connect(host, port);
    }

    public void Send(byte[] datagram, int length)
    {
        try
        {
            _client.Send(datagram, length);
            PacketsSent++;
            BytesSent += length;
        }
        catch (SocketException)
        {
            // Mac 端没开或者网络暂时不通时会出现，继续发就好
            SendErrors++;
        }
    }

    public void Dispose() => _client.Dispose();
}
