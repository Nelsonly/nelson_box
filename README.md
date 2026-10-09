# NelsonBox 📋

自建的跨设备工具：手机、Mac、浏览器之间同步剪贴板，点对点直传文件。

```text
 [ Android App ]   [ 网页 / PWA ]   [ Mac 菜单栏 App ]   [ Python Agent (Linux/Windows) ]
        └────────────────┴──────── WebSocket ─┴──────────────────┘
                                    │
                         ☁️ 中枢服务 (FastAPI)
                         剪贴板：最多 50 条 × 64KB
                         文件：WebRTC 优先直连，打不通时经 TURN 加密转发（不落盘）
```

## 目录

| 目录 | 说明 |
|---|---|
| `server/` | 中枢服务（FastAPI + WebSocket）和网页端 |
| `app/` | Android App（Flutter） |
| `mac/` | Mac 菜单栏 App（Swift，无需 Xcode 工程） |
| `agent/` | Python 版桌面 Agent，可用于 Linux / Windows |

## 服务端

```bash
pip install fastapi uvicorn websockets
NELSON_BOX_TOKEN=$(openssl rand -hex 16) ./start_server.sh
```

- 所有接口都需要令牌：REST 用 `Authorization: Bearer <token>`，WebSocket 用 `?token=`
- 剪贴板保存在 `server/data/clipboard.json`，单条超过 64KB 会被拒绝
- 文件优先在设备之间直连（WebRTC，协议见 [docs/p2p-protocol.md](docs/p2p-protocol.md)）。两端都打不通时，经服务器上的 coturn（TURN）实时转发加密数据，服务器不解密、不落盘
- 设置 `NELSON_BOX_TURN_SECRET`（与 `/etc/turnserver.conf` 的 `static-auth-secret` 相同）后，服务器会给客户端下发 24 小时有效的 TURN 临时账号；同时设 `NELSON_BOX_STUN_PORT=0` 关闭内置 STUN，由 coturn 在 3478 端口提供 STUN/TURN。没装 coturn 时内置 STUN 仍可用于打洞
- coturn 中转端口为 UDP 49160–49260，禁止转发到内网地址。配置模板见 `deploy/turnserver.conf.example`，systemd 服务见 `deploy/nelson-box.service`
- 不记录访问日志（日志级别为 warning），避免占用磁盘、泄露令牌

生产环境用 systemd 运行，配置在 `/etc/systemd/system/nelson-box.service`，令牌在 `/etc/nelson_box.env`。

更新服务器代码：

```bash
COPYFILE_DISABLE=1 tar czf - server/app.py server/config.py server/stun.py server/static | ssh root@<服务器> 'tar xzf - -C /opt/nelson_box && systemctl restart nelson-box'
```

## 客户端

服务器地址和令牌在编译时注入，写在 `app/dart_defines.json`（已被 git 忽略）：

```json
{ "NB_SERVER": "http://<服务器>:18888", "NB_TOKEN": "<令牌>" }
```

**Android**

```bash
cd app && flutter build apk --release --split-per-abi --dart-define-from-file=dart_defines.json
```

支持：一键发送手机剪贴板、选中文字菜单 / 分享菜单直接发送文字或文件、收到内容自动复制、P2P 收发文件（保存到 下载/NelsonBox，需要 App 在前台）。

**Mac**

```bash
./mac/build.sh   # 用 SwiftPM 编译（依赖 WebRTC 预编译包），生成 mac/build/NelsonBox.app
```

窗口应用：发送文字 / Mac 剪贴板，点击记录复制；选择目标设备后拖入文件直传，收到的文件保存到“下载”。不自动监听剪贴板。

**网页**：浏览器打开服务器地址，输入令牌。支持剪贴板和 P2P 文件（网页端接收上限 500MB）。

**Python Agent**（仅剪贴板，自动双向同步）：`./start_agent.sh http://<服务器>:18888 <令牌>`

## License

MIT License © 2026 Nelson
