using System.Net;
using System.Net.Sockets;

namespace EarPair.Sender;

/// <summary>
/// 和 Mac 接收端之间的 UDP 链路：发音频包和控制包，同时在同一个套接字上收 Mac 回的 STATUS。
/// 只收已连接的那个地址发来的包；Mac 端口没开时系统会报“端口不可达”（ICMP），用来判断 Mac 上的 EarPair 有没有开。
/// </summary>
public sealed class UdpSender : IDisposable
{
    private readonly UdpClient _client;
    private readonly Thread? _receiveThread;
    private volatile bool _disposed;
    private long _lastUnreachable = long.MinValue / 2;

    public long PacketsSent { get; private set; }
    public long BytesSent { get; private set; }
    public long SendErrors { get; private set; }

    /// <summary>收到一个控制包（在接收线程上）。</summary>
    public event Action<byte[]>? ControlReceived;

    /// <summary>对方端口不可达（在接收线程上）：Mac 开着，但 EarPair 没在监听。</summary>
    public event Action? PortUnreachable;

    public IPEndPoint? RemoteEndPoint => _client.Client.RemoteEndPoint as IPEndPoint;

    public UdpSender(string host, int port, bool receive = false)
    {
        _client = new UdpClient(AddressFamily.InterNetwork);
        _client.Connect(host, port);
        if (receive)
        {
            // 不设接收超时：Dispose 关掉套接字时，阻塞中的 Receive 会抛异常，线程就退出了
            _receiveThread = new Thread(ReceiveLoop) { IsBackground = true, Name = "EarPair 回包" };
            _receiveThread.Start();
        }
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
        catch (ObjectDisposedException)
        {
            // 停止发送的瞬间，采集线程可能还会送来最后一块数据
        }
    }

    /// <summary>发控制包（不计入音频统计）。</summary>
    public void SendControl(byte[] packet)
    {
        try
        {
            _client.Send(packet, packet.Length);
        }
        catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
        {
            // 下一次再发
        }
    }

    private void ReceiveLoop()
    {
        var remote = new IPEndPoint(IPAddress.Any, 0);
        while (!_disposed)
        {
            try
            {
                byte[] packet = _client.Receive(ref remote);
                if (ControlPacket.IsControl(packet)) ControlReceived?.Invoke(packet);
            }
            catch (SocketException ex) when (ex.SocketErrorCode is SocketError.ConnectionReset or SocketError.ConnectionRefused)
            {
                // 每个音频包都可能换回一个“端口不可达”：每秒报一次就够了（引擎按 5 秒窗口判断）
                long now = Environment.TickCount64;
                if (now - _lastUnreachable >= 1000)
                {
                    _lastUnreachable = now;
                    PortUnreachable?.Invoke();
                }
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
            {
                if (_disposed) return;
                Thread.Sleep(200);
            }
        }
    }

    public void Dispose()
    {
        _disposed = true;
        _client.Dispose();
        _receiveThread?.Join(TimeSpan.FromSeconds(1));
    }
}
