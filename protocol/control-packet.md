# EarPair 控制包 v1（EARC）

音频包（`audio-packet.md`，magic `EARP`）之外的第二种包，用来：

- 互相告诉对方自己的名字（界面上显示“DESKTOP-7Q2 → milkman的MacBook Air”而不是 IP）；
- Mac 把接收状态回传给 Windows（Windows 端能显示“正在播放 / Mac 正忙 / Mac 已静音”，Mac 离开时自动暂停）；
- 发送端停止时立即通知 Mac（不用等 1 秒超时）。

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
| HELLO (3) | 发送端 → 接收端，从发音频的同一个套接字发 | 开始发送时立即发，之后每 2 秒；探测或暂停发送（等 Mac 回来）时 `stream` 为 0，头 30 秒每秒一次，之后每 3 秒一次 | `{"sender":"9c1d…","name":"DESKTOP-7Q2","kind":"desktop","app":"0.2.0","stream":16909060}` |
| STATUS (4) | 接收端 → 最近一次 HELLO 的源地址和端口 | 6 秒内收到过 HELLO 的地址，每秒 1 次；收到 HELLO 时立即回一次 | 见下 |
| BYE (5) | 发送端 → 接收端 | 停止发送时发 2 次 | `{"stream":16909060,"reason":"user"}` |

HELLO 的 `name` 是 Windows 的 DNS 主机名（`Dns.GetHostName()`，保留大小写），`kind` 是 `laptop`（有电池）或 `desktop`。

STATUS：

```json
{"id":"5f0e3c2a9b7d4e1f8a6c2b9d0e1f3a4b","name":"milkman的MacBook Air","kind":"laptop","app":"0.2.0",
 "stream":16909060,"state":"playing","busyName":null,
 "bufferMs":59.6,"targetMs":60,"received":69467,"lost":0,"late":0,"underruns":0,
 "output":"milkman的AirPods Pro","transport":"bluetooth","muted":false,"volume":1.0}
```

| 字段 | 说明 |
|---|---|
| `state` | 对这个 HELLO 的发送端来说：`buffering` / `playing` / `idle`；接收端正在播另一个发送端时是 `busy`，`busyName` 是那个发送端的名字（不知道名字时是 IP） |
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

## 兼容性

| 组合 | 结果 |
|---|---|
| 新发送端 → 0.1 接收端 | 音频照常（音频包没变）。0.1 把 EARC 包当成 magic 不对的包丢掉，不回 STATUS；发送端显示“正在发送”，不会自动暂停 |
| 0.1 发送端 → 新接收端 | 音频照常；没有 HELLO，接收端用反查主机名或 IP 显示发送端 |
| 新 ↔ 新 | 全部功能 |

## 测试向量

```
BYE {"stream":16909060}（27 字节）
45 41 52 43 01 05 13 00 7b 22 73 74 72 65 61 6d 22 3a 31 36 39 30 39 30 36 30 7d

HELLO {"stream":1}（20 字节）
45 41 52 43 01 03 0c 00 7b 22 73 74 72 65 61 6d 22 3a 31 7d
```
