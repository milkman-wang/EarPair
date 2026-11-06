using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace EarPair.Sender;

/// <summary>控制包 v1（EARC）：8 字节包头 + UTF-8 JSON。格式见 protocol/control-packet.md。</summary>
public static class ControlPacket
{
    public const int HeaderSize = 8;
    public const int MaxSize = 1400;
    private const byte Version = 1;

    public enum Kind : byte
    {
        Hello = 3,
        Status = 4,
        Bye = 5,
    }

    public static bool IsControl(ReadOnlySpan<byte> packet) =>
        packet.Length >= 4 && packet[0] == 'E' && packet[1] == 'A' && packet[2] == 'R' && packet[3] == 'C';

    public static byte[] Encode(Kind kind, ReadOnlySpan<byte> body)
    {
        if (HeaderSize + body.Length > MaxSize) throw new ArgumentException("控制包太长", nameof(body));
        var packet = new byte[HeaderSize + body.Length];
        packet[0] = (byte)'E';
        packet[1] = (byte)'A';
        packet[2] = (byte)'R';
        packet[3] = (byte)'C';
        packet[4] = Version;
        packet[5] = (byte)kind;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(6), (ushort)body.Length);
        body.CopyTo(packet.AsSpan(HeaderSize));
        return packet;
    }

    public static byte[] Encode(HelloMessage message) =>
        Encode(Kind.Hello, JsonSerializer.SerializeToUtf8Bytes(message, ControlJson.Default.HelloMessage));

    public static byte[] Encode(ByeMessage message) =>
        Encode(Kind.Bye, JsonSerializer.SerializeToUtf8Bytes(message, ControlJson.Default.ByeMessage));

    /// <summary>解析包头；格式、长度、版本不对或者类型不认识时返回 false。</summary>
    public static bool TryParse(ReadOnlySpan<byte> packet, out Kind kind, out ReadOnlySpan<byte> body)
    {
        kind = default;
        body = default;
        if (packet.Length < HeaderSize || packet.Length > MaxSize || !IsControl(packet) || packet[4] != Version)
            return false;
        if (!Enum.IsDefined((Kind)packet[5])) return false;
        int length = BinaryPrimitives.ReadUInt16LittleEndian(packet[6..]);
        if (packet.Length != HeaderSize + length) return false;
        kind = (Kind)packet[5];
        body = packet[HeaderSize..];
        return true;
    }

    /// <summary>解析 STATUS；不是 STATUS 或 JSON 坏了返回 null。</summary>
    public static StatusMessage? ParseStatus(ReadOnlySpan<byte> packet)
    {
        if (!TryParse(packet, out Kind kind, out ReadOnlySpan<byte> body) || kind != Kind.Status) return null;
        try
        {
            return JsonSerializer.Deserialize(body, ControlJson.Default.StatusMessage);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>发送端 → 接收端：我是谁、正在发哪个流（0 表示还没在发，只是问接收端在不在）。</summary>
public sealed record HelloMessage(
    [property: JsonPropertyName("sender")] string? Sender,
    [property: JsonPropertyName("name")] string? Name,
    [property: JsonPropertyName("kind")] string? Kind, // laptop / desktop
    [property: JsonPropertyName("app")] string? App,
    [property: JsonPropertyName("stream")] uint Stream);

/// <summary>发送端停止发送。</summary>
public sealed record ByeMessage([property: JsonPropertyName("stream")] uint Stream);

/// <summary>接收端 → 发送端：接收状态。</summary>
public sealed record StatusMessage
{
    [JsonPropertyName("id")] public string? Id { get; init; }
    [JsonPropertyName("name")] public string? Name { get; init; }
    /// <summary>Mac 是 laptop 还是 desktop</summary>
    [JsonPropertyName("kind")] public string? Kind { get; init; }
    [JsonPropertyName("app")] public string? App { get; init; }
    [JsonPropertyName("stream")] public uint Stream { get; init; }
    /// <summary>buffering / playing / idle / busy</summary>
    [JsonPropertyName("state")] public string? State { get; init; }
    [JsonPropertyName("busyName")] public string? BusyName { get; init; }
    [JsonPropertyName("bufferMs")] public double? BufferMs { get; init; }
    [JsonPropertyName("targetMs")] public double? TargetMs { get; init; }
    [JsonPropertyName("received")] public long? Received { get; init; }
    [JsonPropertyName("lost")] public long? Lost { get; init; }
    [JsonPropertyName("late")] public long? Late { get; init; }
    [JsonPropertyName("underruns")] public long? Underruns { get; init; }
    [JsonPropertyName("output")] public string? Output { get; init; }
    /// <summary>builtin / headphones（内置输出走耳机口）/ bluetooth / usb / airplay / hdmi / other</summary>
    [JsonPropertyName("transport")] public string? Transport { get; init; }
    [JsonPropertyName("muted")] public bool? Muted { get; init; }
    [JsonPropertyName("volume")] public double? Volume { get; init; }

    public bool IsBusy => State == "busy";
    public bool IsPlaying => State == "playing";
    public bool IsBuffering => State == "buffering";
}

[JsonSourceGenerationOptions(DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(HelloMessage))]
[JsonSerializable(typeof(ByeMessage))]
[JsonSerializable(typeof(StatusMessage))]
internal sealed partial class ControlJson : JsonSerializerContext;
