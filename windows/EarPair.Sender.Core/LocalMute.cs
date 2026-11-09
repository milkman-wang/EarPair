using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;

namespace EarPair.Sender;

internal enum MuteResult
{
    /// <summary>我们静的音，停止时恢复</summary>
    Muted,
    /// <summary>原来就静着（用户自己静的），不归我们管</summary>
    AlreadyMuted,
    /// <summary>这次发送中用户取消过我们的静音，不再静</summary>
    UserOverrode,
    /// <summary>设置静音失败（设备没了等）</summary>
    Failed,
}

/// <summary>
/// 发送时让本机不出声：静音正在采集的输出设备，停止时恢复。只恢复我们自己静的；
/// 用户中途自己取消了静音，就放手不再管。只在发送引擎的线程上使用（UserUnmuted 除外）。
/// </summary>
internal sealed class LocalMute : IDisposable
{
    private readonly MMDevice _device;
    private readonly int _processId = Environment.ProcessId;
    private volatile bool _mutedByUs;
    private volatile bool _userOverrode;

    public string DeviceId { get; }
    public string DeviceName { get; }
    public bool MutedByUs => _mutedByUs;

    /// <summary>我们静着的时候被取消了静音（用户点的，或者按了音量键）。在系统的通知线程上触发。</summary>
    public event Action? UserUnmuted;

    public LocalMute(MMDevice device)
    {
        _device = device;
        DeviceId = device.ID;
        DeviceName = device.FriendlyName;
        _device.AudioEndpointVolume.OnVolumeNotification += OnVolumeNotification;
    }

    /// <summary>静音（原来没静音才算我们静的）。</summary>
    public MuteResult Mute()
    {
        if (_userOverrode) return MuteResult.UserOverrode;
        try
        {
            if (_device.AudioEndpointVolume.Mute) return MuteResult.AlreadyMuted;
            _mutedByUs = true;
            _device.AudioEndpointVolume.Mute = true;
            return MuteResult.Muted;
        }
        catch (COMException)
        {
            _mutedByUs = false;
            return MuteResult.Failed;
        }
    }

    /// <summary>恢复我们静的音。设备已经没了、恢复不成时返回 false（不是我们静的音也返回 true）。</summary>
    public bool Restore()
    {
        if (!_mutedByUs) return true;
        // 先改标记再取消静音：音量通知里看到的“取消静音”不能当成用户点的
        _mutedByUs = false;
        try
        {
            _device.AudioEndpointVolume.Mute = false;
            return true;
        }
        catch (COMException)
        {
            return false; // 设备已经没了
        }
    }

    /// <summary>这个设备上其他程序正在播放的峰值（0…1），用来判断“静音之后采不到声音”。</summary>
    public float OthersPeak()
    {
        float peak = 0;
        try
        {
            AudioSessionManager manager = _device.AudioSessionManager;
            manager.RefreshSessions();
            SessionCollection sessions = manager.Sessions;
            for (int i = 0; i < sessions.Count; i++)
            {
                AudioSessionControl session = sessions[i];
                if (session.GetProcessID == (uint)_processId) continue;
                peak = Math.Max(peak, session.AudioMeterInformation.MasterPeakValue);
            }
        }
        catch (COMException)
        {
            // 取不到就当没有
        }
        return peak;
    }

    private void OnVolumeNotification(AudioVolumeNotificationData data)
    {
        // 我们静着的时候收到“取消静音”：是用户自己点的，放手
        if (_mutedByUs && !data.Muted)
        {
            _mutedByUs = false;
            _userOverrode = true;
            UserUnmuted?.Invoke();
        }
    }

    public void Dispose()
    {
        Restore();
        try
        {
            _device.AudioEndpointVolume.OnVolumeNotification -= OnVolumeNotification;
        }
        catch (COMException)
        {
        }
    }

    /// <summary>之前没恢复成的静音（异常退出、设备被拔掉）：那个设备还静着就恢复。设备现在不在（恢复不了）时返回 false。</summary>
    public static bool RestoreLeftover(string deviceId)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            MMDevice device = enumerator.GetDevice(deviceId);
            if (device.State != DeviceState.Active) return false;
            if (device.AudioEndpointVolume.Mute) device.AudioEndpointVolume.Mute = false;
            return true;
        }
        catch (COMException)
        {
            Debug.WriteLine("恢复之前的静音失败：设备不在了");
            return false;
        }
    }
}
