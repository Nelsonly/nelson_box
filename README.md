# NelsonBox 📋

自建的跨设备剪贴板同步：手机、Mac、浏览器之间实时同步文字。

```text
 [ Android App ]   [ 网页 / PWA ]   [ Mac 菜单栏 App ]   [ Python Agent (Linux/Windows) ]
        └────────────────┴──────── WebSocket ─┴──────────────────┘
                                    │
                         ☁️ 中枢服务 (FastAPI)
                         历史记录：最多 50 条 × 64KB，存在单个 JSON 文件
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
- 数据保存在 `server/data/clipboard.json`，单条超过 64KB 会被拒绝
- 不记录访问日志（日志级别为 warning），避免占用磁盘、泄露令牌

生产环境用 systemd 运行，配置在 `/etc/systemd/system/nelson-box.service`，令牌在 `/etc/nelson_box.env`。

更新服务器代码：

```bash
COPYFILE_DISABLE=1 tar czf - server/app.py server/config.py server/static | ssh root@<服务器> 'tar xzf - -C /opt/nelson_box && systemctl restart nelson-box'
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

支持：一键发送手机剪贴板、选中文字菜单 / 分享菜单直接发送、收到内容自动复制。

**Mac**

```bash
./mac/build.sh   # 生成 mac/build/NelsonBox.app
```

菜单栏常驻，复制即同步；自动跳过密码管理器复制的密码。

**网页**：浏览器打开服务器地址，输入令牌。

**Python Agent**：`./start_agent.sh http://<服务器>:18888 <令牌>`

## License

MIT License © 2026 Nelson
