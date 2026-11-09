using System.Buffers.Binary;
using NAudio.Wave;

namespace EarPair.Sender;

/// <summary>
/// 把 WASAPI 采到的 PCM / 浮点数据转成立体声 16-bit。
/// 多声道按 Windows 标准顺序（FL FR FC LFE BL BR SL SR）混成立体声，LFE 丢弃；
/// 混合后按最大可能的和缩小（各声道都满幅时也不削顶），响度由 Mac 端的音量平衡补回来。
/// </summary>
public sealed class PcmConverter
{
    private static readonly Guid SubtypePcm = new("00000001-0000-0010-8000-00aa00389b71");
    private static readonly Guid SubtypeIeeeFloat = new("00000003-0000-0010-8000-00aa00389b71");
    private const float SideGain = 0.7071f;
    /// <summary>四声道（FL FR BL BR）、5.1、7.1 混成立体声后的缩放：1 / 一侧所有系数之和</summary>
    private const float QuadScale = 1 / (1 + SideGain);
    private const float Surround51Scale = 1 / (1 + 2 * SideGain);
    private const float Surround71Scale = 1 / (1 + 3 * SideGain);

    private readonly int _channels;
    private readonly int _bytesPerSample;
    private readonly int _blockAlign;
    private readonly bool _isFloat;

    public PcmConverter(WaveFormat format)
    {
        _channels = format.Channels;
        _bytesPerSample = format.BitsPerSample / 8;
        _blockAlign = format.BlockAlign;
        _isFloat = IsFloat(format);
        bool supported = _isFloat
            ? _bytesPerSample == 4
            : IsPcm(format) && _bytesPerSample is 2 or 3 or 4;
        if (!supported || _channels < 1 || _blockAlign < _channels * _bytesPerSample)
            throw new NotSupportedException(CoreStrings.UnsupportedFormat(format.ToString()));
    }

    public static bool IsFloat(WaveFormat format) =>
        format.Encoding == WaveFormatEncoding.IeeeFloat ||
        (format is WaveFormatExtensible extensible && extensible.SubFormat == SubtypeIeeeFloat);

    private static bool IsPcm(WaveFormat format) =>
        format.Encoding == WaveFormatEncoding.Pcm ||
        (format is WaveFormatExtensible extensible && extensible.SubFormat == SubtypePcm);

    public int FrameCount(int byteCount) => byteCount / _blockAlign;

    /// <summary>转换 source 里的所有完整帧，写进 destination（交错立体声），返回帧数。</summary>
    public int ConvertToStereo16(ReadOnlySpan<byte> source, Span<short> destination)
    {
        int frames = source.Length / _blockAlign;
        for (int f = 0; f < frames; f++)
        {
            ReadOnlySpan<byte> frame = source.Slice(f * _blockAlign, _blockAlign);
            float left, right;
            switch (_channels)
            {
                case 1:
                    left = right = Sample(frame, 0);
                    break;
                case 4: // 四声道：FL FR BL BR
                    left = (Sample(frame, 0) + Sample(frame, 2) * SideGain) * QuadScale;
                    right = (Sample(frame, 1) + Sample(frame, 3) * SideGain) * QuadScale;
                    break;
                case 6: // 5.1：FL FR FC LFE BL BR
                {
                    float center = Sample(frame, 2) * SideGain;
                    left = (Sample(frame, 0) + center + Sample(frame, 4) * SideGain) * Surround51Scale;
                    right = (Sample(frame, 1) + center + Sample(frame, 5) * SideGain) * Surround51Scale;
                    break;
                }
                case 8: // 7.1：FL FR FC LFE BL BR SL SR
                {
                    float center = Sample(frame, 2) * SideGain;
                    left = (Sample(frame, 0) + center + (Sample(frame, 4) + Sample(frame, 6)) * SideGain) * Surround71Scale;
                    right = (Sample(frame, 1) + center + (Sample(frame, 5) + Sample(frame, 7)) * SideGain) * Surround71Scale;
                    break;
                }
                default: // 立体声；其他布局只取前两个声道
                    left = Sample(frame, 0);
                    right = Sample(frame, 1);
                    break;
            }
            destination[f * 2] = ToInt16(left);
            destination[f * 2 + 1] = ToInt16(right);
        }
        return frames;
    }

    private float Sample(ReadOnlySpan<byte> frame, int channel)
    {
        ReadOnlySpan<byte> s = frame.Slice(channel * _bytesPerSample, _bytesPerSample);
        if (_isFloat) return BinaryPrimitives.ReadSingleLittleEndian(s);
        return _bytesPerSample switch
        {
            2 => BinaryPrimitives.ReadInt16LittleEndian(s) / 32768f,
            3 => ((s[0] << 8) | (s[1] << 16) | (s[2] << 24)) / 2147483648f,
            _ => BinaryPrimitives.ReadInt32LittleEndian(s) / 2147483648f,
        };
    }

    /// <summary>浮点 → 16-bit（与 Mac 端的 ÷32768 对称），超出范围的削顶。</summary>
    private static short ToInt16(float value)
    {
        float scaled = value * 32768f;
        if (float.IsNaN(scaled)) return 0;
        if (scaled >= 32767f) return short.MaxValue;
        if (scaled <= -32768f) return short.MinValue;
        return (short)MathF.Round(scaled);
    }
}
