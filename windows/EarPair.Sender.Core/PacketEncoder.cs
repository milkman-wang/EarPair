using System.Buffers.Binary;

namespace EarPair.Sender;

/// <summary>
/// 把连续的立体声 16-bit 帧切成固定长度的 EarPair v1 数据包。格式见 protocol/audio-packet.md。
/// </summary>
public sealed class PacketEncoder
{
    public const int HeaderSize = 32;
    private const byte Version = 1;
    private const byte CodecPcm16 = 1;
    private const int Channels = 2;

    private readonly int _framesPerPacket;
    private readonly uint _sampleRate;
    private readonly uint _streamId;
    private readonly byte[] _packet;
    private readonly short[] _pending;  // 还没凑满一包的帧（交错）
    private int _pendingFrames;
    private uint _sequence;
    private ulong _sampleTime;

    public PacketEncoder(int sampleRate, int framesPerPacket, uint streamId)
    {
        _framesPerPacket = framesPerPacket;
        _sampleRate = (uint)sampleRate;
        _streamId = streamId;
        _packet = new byte[HeaderSize + framesPerPacket * Channels * 2];
        _pending = new short[framesPerPacket * Channels];
    }

    /// <summary>下一个包的序号</summary>
    public uint NextSequence => _sequence;

    /// <summary>追加交错立体声帧；每凑满一个包就调用一次 send(包缓冲, 长度)。</summary>
    public void Append(ReadOnlySpan<short> interleaved, Action<byte[], int> send)
    {
        int offset = 0;
        while (offset < interleaved.Length)
        {
            int wanted = (_framesPerPacket - _pendingFrames) * Channels;
            int take = Math.Min(wanted, interleaved.Length - offset);
            interleaved.Slice(offset, take).CopyTo(_pending.AsSpan(_pendingFrames * Channels));
            _pendingFrames += take / Channels;
            offset += take;
            if (_pendingFrames == _framesPerPacket)
            {
                send(_packet, Encode());
                _pendingFrames = 0;
            }
        }
    }

    private int Encode()
    {
        Span<byte> p = _packet;
        p[0] = (byte)'E';
        p[1] = (byte)'A';
        p[2] = (byte)'R';
        p[3] = (byte)'P';
        p[4] = Version;
        p[5] = 0; // flags
        p[6] = CodecPcm16;
        p[7] = Channels;
        BinaryPrimitives.WriteUInt32LittleEndian(p[8..], _streamId);
        BinaryPrimitives.WriteUInt32LittleEndian(p[12..], _sequence);
        BinaryPrimitives.WriteUInt64LittleEndian(p[16..], _sampleTime);
        BinaryPrimitives.WriteUInt32LittleEndian(p[24..], _sampleRate);
        BinaryPrimitives.WriteUInt16LittleEndian(p[28..], (ushort)_framesPerPacket);
        BinaryPrimitives.WriteUInt16LittleEndian(p[30..], 0); // reserved

        Span<byte> payload = p[HeaderSize..];
        for (int i = 0; i < _framesPerPacket * Channels; i++)
            BinaryPrimitives.WriteInt16LittleEndian(payload[(i * 2)..], _pending[i]);

        _sequence++; // 到 uint.MaxValue 后自然回到 0
        _sampleTime += (ulong)_framesPerPacket;
        return HeaderSize + _framesPerPacket * Channels * 2;
    }
}
