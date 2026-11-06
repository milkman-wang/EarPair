# EarPair 控制包 v1（EARC）

音频包（`audio-packet.md`，magic `EARP`）之外的第二种包，用来：

- 互相告诉对方自己的名字（界面上显示“DESKTOP-7Q2 → milkman的MacBook Air”而不是 IP）；
- Mac 把接收状态回传给 Windows（Windows 端能显示“正在播放 / Mac 正忙 / Mac 已静音”，Mac 离开时自动暂停）；
- 发送端停止时立即通知 Mac（不用等 1 秒超时）；
- 电脑没有声音时暂停发音频包（待机），只用 HELLO 保持握手，省电省流量。

找到 Mac 用 Bonjour（DNS-SD），不在这个协议里：Mac 广播服务类型 `_earpair._udp`，实例名是电脑名，端口是接收端口，TXT 记录 `v=1`、`id=<接收端 id>`、`kind=laptop|desktop`（发现列表在连接之前就能画对图标）。

## 包格式

和音频包共用 UDP 端口（Mac 上默认 47800），用前 4 个字节区分。多字节字段小端序。

| 偏移 | 长度 | 字段 | 说明 |
|---:|---:|---|---|
| 0 | 4 | `magic` | ASCII `EARC`（`45 41 52 43`） |
| 4 | 1 | `version` | `1`；只处理 1，其他版本忽略 |
| 5 | 1 | `type` | 3 HELLO，4 STATUS，5 BYE；不认识的类型忽略（1、2 留给以后的广播发现） |
| 6 | 2 | `length` | 消息体字节数 N |
| 8 | N | `body` | UTF-8 JSON 对象（无 BOM） |

- 整包长度必须正好是 `8 + N`，并且不超过 1400 字节，否则丢弃。
- JSON 里不认识的字段忽略，缺的字段用默认值：以后加字段不用升版本。
- `id`：32 位小写十六进制字符串（UUID 去掉连字符），各自第一次运行时生成并保存。

## 消息

| 类型 | 方向 | 什么时候 | 消息体（例） |
|---|---|---|---|
| HELLO (3) | 发送端 → 接收端，从发音频的同一个套接字发 | 开始发送时立即发，之后每 2 秒；待机时每秒一次（进入待机时立即发，0.25 秒后再发一份；恢复后 0.25 秒内发一个不带 `standby` 的）；探测或暂停发送（等 Mac 回来）时 `stream` 为 0，头 30 秒每秒一次，之后每 3 秒一次 | `{"sender":"9c1d…","name":"DESKTOP-7Q2","kind":"desktop","app":"0.2.0","stream":16909060}`；待机时多两个字段 `"standby":true,"seq":4321` |
| STATUS (4) | 接收端 → 最近一次 HELLO 的源地址和端口 | 6 秒内收到过 HELLO 的地址，每秒 1 次；收到 HELLO 时立即回一次 | 见下 |
| BYE (5) | 发送端 → 接收端 | 停止发送时发 2 次 | `{"stream":16909060,"reason":"user"}` |

HELLO 的 `name` 是 Windows 的 DNS 主机名（`Dns.GetHostName()`，保留大小写），`kind` 是 `laptop`（有电池）或 `desktop`。待机时 `standby` 为 `true`，`seq` 是恢复后第一个音频包的序号（不待机时这两个字段不写）。

STATUS：

```json
{"id":"5f0e3c2a9b7d4e1f8a6c2b9d0e1f3a4b","name":"milkman的MacBook Air","kind":"laptop","app":"0.2.0",
 "stream":16909060,"state":"playing","busyName":null,
 "bufferMs":59.6,"targetMs":60,"received":69467,"lost":0,"late":0,"underruns":0,
 "output":"milkman的AirPods Pro","transport":"bluetooth","muted":false,"volume":1.0,"features":["standby"]}
```

| 字段 | 说明 |
|---|---|
| `state` | 对这个 HELLO 的发送端来说：`buffering` / `playing` / `standby`（它在待机）/ `idle`；接收端正在播另一个发送端时是 `busy`，`busyName` 是那个发送端的名字（不知道名字时是 IP） |
| `features` | 接收端支持的功能：`standby` 表示认得待机。发送端只在看到它时才待机 |
| `stream` | 接收端当前锁定的流（`state` 为 `idle` 时是 0） |
| `received` / `lost` / `late` / `underruns` | 接收端的累计统计 |
| `bufferMs` / `targetMs` | 缓冲水位和目标 |
| `kind` | Mac 是 `laptop` 还是 `desktop` |
| `output` / `transport` | Mac 的输出设备名；`builtin` / `headphones`（内置输出走耳机口）/ `bluetooth` / `usb` / `airplay` / `hdmi` / `other` |
| `muted` / `volume` | Mac 端 EarPair 的静音和音量（0–2） |

## 规则

- 接收端只把 STATUS 发给 6 秒内发过 HELLO 的地址，不发广播。
- STATUS 都从接收端口发出、发往 HELLO 的源端口：Windows 防火墙按会话放行，发送端不需要在固定端口上监听，也不会弹防火墙提示。
- 发送端停止时（关开关、暂停、换目标、退出）**先停采集，再发 BYE ×2**：BYE 之后这一路流不会再有音频包。
- BYE 的 `reason`（可选）：`user` 手动停止（关开关、退出、换目标、关机或注销）；`network` 联系不上 Mac、自己暂停了；`device` 音频设备没了；`busy` Mac 正在放别的电脑。没有或不认识的 `reason` 当作 `user`。
- 收到 BYE：如果是当前流，接收端立即结束这个流并记下原因。之后同一（发送端 IP，`stream`）迟到的音频包都忽略；同一个 IP 发来新的 `stream` 时照常开始。
- 接收端区分两种结束：`user`、`device` 是发送端主动停的（界面“已停止”）；`network` 和超时（1 秒没包）是网络问题（界面“正在重新连接”）。
- 网络问题时接收端主动联系发送端：60 秒内每秒往它最近一次 HELLO 的来源发一个 STATUS（`state` 为 `idle`）。发送端如果因为联系不上 Mac 暂停了，收到不忙的 STATUS 就立即恢复发送；手动停止的发送端会忽略它。
- `kind`、`transport` 遇到不认识的值一律当作未知：Windows 电脑画成台式机，Mac 画成笔记本，输出画成扬声器。

### 待机

- 发送端连续 3 秒没有声音（16-bit 峰值不超过 3，约 −80 dBFS），并且 3 秒内收到的 STATUS 的 `features` 里有 `standby`、`stream` 是自己的流、`state` 是 `playing` / `buffering` / `standby`（接收端确实在收）：停发音频包，HELLO 带上 `standby: true` 和 `seq`（暂停前最后一个包之后的序号），立即发一个，0.25 秒后再发一份，之后每秒一次。
- 一有声音就接着发同一个流：序号和采样时间接着暂停前的，中间不补包。恢复后 0.25 秒内发一个不带 `standby` 的 HELLO（那时接收端已经攒够缓冲）。
- 接收端收到当前流的待机 HELLO：这个流进入待机（STATUS 的 `state` 为 `standby`），清掉缓冲；不再按 1 秒没包算断开，也不算卡顿；6 秒收不到 HELLO 才算网络断开。
- 待机的发送端照样占着接收端：别的电脑发来的音频包忽略，STATUS 回 `busy`，直到它结束或者 6 秒没有 HELLO。
- 接收端看音频包恢复，不看 HELLO（HELLO 可能乱序）：序号小于 `seq` 的包是暂停前发出、晚到的，忽略；序号不小于 `seq` 的包到了，从这个包开始重新缓冲。已经收到过 `seq` 及之后的包时，再来的待机 HELLO 是旧的，忽略。
- 待机中 STATUS 说接收端没有这一路流（`idle`，比如 Mac 上的 EarPair 重新打开过），或者不再声明 `standby`：发送端先照常发 1 秒（静音也发），接收端接上之后再待机。

## 兼容性

| 组合 | 结果 |
|---|---|
| 新发送端 → 0.1 接收端 | 音频照常（音频包没变）。0.1 把 EARC 包当成 magic 不对的包丢掉，不回 STATUS；发送端显示“正在发送”，不会自动暂停 |
| 0.1 发送端 → 新接收端 | 音频照常；没有 HELLO，接收端用反查主机名或 IP 显示发送端 |
| 新 ↔ 新 | 全部功能 |
| 有待机的发送端 → 没有待机的接收端 | STATUS 里没有 `features`，发送端一直发，不待机 |
| 没有待机的发送端 → 有待机的接收端 | 发送端一直发，接收端照常收 |

## 测试向量

```
BYE {"stream":16909060}（27 字节）
45 41 52 43 01 05 13 00 7b 22 73 74 72 65 61 6d 22 3a 31 36 39 30 39 30 36 30 7d

HELLO {"stream":1}（20 字节）
45 41 52 43 01 03 0c 00 7b 22 73 74 72 65 61 6d 22 3a 31 7d

待机的 HELLO {"stream":7,"standby":true,"seq":42}（44 字节）
45 41 52 43 01 03 24 00 7b 22 73 74 72 65 61 6d 22 3a 37 2c 22 73 74 61 6e 64 62 79 22 3a 74 72 75 65 2c 22 73 65 71 22 3a 34 32 7d
```
