# P2P 文件传输协议

文件通过 WebRTC DataChannel 在设备之间传输，**优先直连**（局域网 / 打洞 / IPv6）。
两端都是对称型 NAT 等无法打洞的情况，WebRTC 会自动改走服务器上的 TURN（coturn）实时转发。
转发的是 DTLS 加密后的数据包，服务器无法解密，也不落盘。

## 1. 服务器提供

**ICE 配置**：WebSocket 连上后，服务器推送一次：

```json
{"type": "rtc:config", "ice_servers": [
  {"urls": ["stun:<服务器>:3478"]},
  {"urls": ["turn:<服务器>:3478?transport=udp", "turn:<服务器>:3478?transport=tcp"], "username": "<过期时间戳>:<device_id>", "credential": "<HMAC>"},
  {"urls": ["stun:stun.cloudflare.com:3478"]}
]}
```

客户端原样用它创建 `RTCPeerConnection`（要带上 `username` / `credential`）。TURN 账号由服务器按 coturn 的
`use-auth-secret` 规则临时生成，24 小时有效，WebSocket 重连时会拿到新的。

**信令转发**：客户端发

```json
{"type": "rtc:signal", "to": "<目标 device_id>", "data": { ... }}
```

服务器原样转给目标设备，并补上发送方信息：

```json
{"type": "rtc:signal", "from": "<来源 device_id>", "from_name": "<来源设备名>", "data": { ... }}
```

目标不在线时，服务器回给发送方：

```json
{"type": "rtc:error", "to": "<目标 device_id>", "transfer_id": "<data.transfer_id>", "error": "对方不在线"}
```

## 2. 信令消息（`data` 字段）

所有消息都带 `transfer_id`（发送方生成的随机字符串），一次传输一个 `RTCPeerConnection`。

| kind | 方向 | 内容 |
|---|---|---|
| `offer-file` | 发送方 → 接收方 | `files: [{name, size}]`, `total`（总字节） |
| `accept` | 接收方 → 发送方 | 同意接收 |
| `decline` | 接收方 → 发送方 | `reason`，拒绝（如网页端文件过大） |
| `sdp` | 双向 | `sdp: {type, sdp}`。发送方是 offerer，接收方回 answer |
| `ice` | 双向 | `candidate: {candidate, sdpMid, sdpMLineIndex}`，trickle ICE |
| `cancel` | 双向 | `reason`，任一方中止；收到后关闭连接、删除未完成文件 |

流程：

1. 发送方发 `offer-file`。
2. 接收方（默认自动接收）回 `accept`。
3. 发送方创建 `RTCPeerConnection` 和 DataChannel（label `"file"`，ordered、可靠），createOffer → 发 `sdp`。
4. 接收方 setRemoteDescription → createAnswer → 发 `sdp`。双方各自发 `ice`。
5. DataChannel 打开后按第 3 节传数据。
6. 发送方发出 `offer-file` 后 **20 秒**内 DataChannel 没打开（连中转也失败），发 `cancel` 并提示“无法建立直连（双方网络都不支持打洞）”。接收方同样设 20 秒超时。
7. 连接建立后可用 `getStats` 的选中候选对显示连接方式：任一端是 `relay` → 服务器中转；两端都是内网地址 → 局域网直连；有 `srflx`/`prflx` → 打洞直连。

## 3. DataChannel 数据格式

文本消息是 JSON 控制帧，二进制消息是文件数据。

发送方，按顺序逐个文件：

```text
文本 {"t": "file", "index": 0, "name": "a.jpg", "size": 12345}
二进制 块 × N（每块 ≤ 16384 字节）
文本 {"t": "end", "index": 0}
…下一个文件…
文本 {"t": "done"}
```

接收方：

- 收到 `file` 时开始写新文件，收到二进制块就追加，收到 `end` 时校验字节数等于 `size`。
- 收到 `done` 后回 `{"t": "ack"}`。发送方收到 `ack` 才关闭连接，避免数据还在缓冲区就被关掉。
- 出错时回 `{"t": "error", "message": "..."}`，双方关闭连接。

**流控**：发送方在 `bufferedAmount > 1 MB` 时暂停，等 `bufferedAmountLow` 事件（阈值 256 KB）后继续。

## 4. 保存位置

- Mac：`~/Downloads/`，同名时加 ` (1)`
- Android：`下载/NelsonBox/`
- 网页：浏览器下载（整个文件先缓存在内存里，网页端接收上限 500 MB，超出回 `decline`）
