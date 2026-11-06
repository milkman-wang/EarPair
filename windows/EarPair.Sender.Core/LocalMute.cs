using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;

namespace EarPair.Sender;

/// <summary>
/// 发送时让本机不出声：静音正在采集的输出设备，停止时恢复。只恢复我们自己静的；
/// 用户中途自己取消了静音，就放手不再管。只在发送引擎的线程上使用。
/// </summary>
internal sealed class LocalMute : IDisposable
{
    private readonly MMDevice _device;
    private readonly int _processId = Environment.ProcessId;
    private volatile bool _mutedByUs;
    private volatile bool _userOverrode;

    public string DeviceId { get; }
    public bool MutedByUs => _mutedByUs;

    public LocalMute(MMDevice device)
    {
        _device = device;
        DeviceId = device.ID;
        _device.AudioEndpointVolume.OnVolumeNotification += OnVolumeNotification;
    }

    /// <summary>静音（原来没静音才算我们静的）。返回是否由我们静音了。</summary>
    public bool Mute()
    {
        if (_userOverrode) return false;
        try
        {
            if (_device.AudioEndpointVolume.Mute) return false; // 用户自己静着的，不归我们管
            _mutedByUs = true;
            _device.AudioEndpointVolume.Mute = true;
            return true;
        }
        catch (COMException)
        {
            _mutedByUs = false;
            return false;
        }
    }

    /// <summary>恢复我们静的音。</summary>
    public void Restore()
    {
        if (!_mutedByUs) return;
        _mutedByUs = false;
        try
        {
            _device.AudioEndpointVolume.Mute = false;
        }
        catch (COMException)
        {
            // 设备已经没了
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

    /// <summary>上次异常退出时留下的静音：那个设备还静着就恢复。</summary>
    public static void RestoreLeftover(string deviceId)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            MMDevice device = enumerator.GetDevice(deviceId);
            if (device.State == DeviceState.Active && device.AudioEndpointVolume.Mute)
                device.AudioEndpointVolume.Mute = false;
        }
        catch (COMException)
        {
            Debug.WriteLine("恢复上次的静音失败：设备不在了");
        }
    }
}
