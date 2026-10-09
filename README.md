# NelsonBox 📋

自建的跨设备工具：手机、Mac、浏览器之间同步剪贴板，点对点直传文件，并从手机或网页调用 Mac 上的 AI CLI。

```text
 [ Android App ]   [ 网页 / PWA ]   [ Mac 菜单栏 App ]   [ Python Agent (Linux/Windows) ]
        └────────────────┴──────── WebSocket ─┴──────────────────┘
                                    │
                         ☁️ 中枢服务 (FastAPI)
                         剪贴板：最多 50 条 × 64KB
                         文件：WebRTC 优先直连，打不通时经 TURN 加密转发（不落盘）
                         AI：只转发消息，由 Mac 本机执行 CLI
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

窗口应用：发送文字 / Mac 剪贴板，点击记录复制；选择目标设备后拖入文件直传，收到的文件保存到“下载”。不自动监听剪贴板。Mac 还可作为 AI 主机，调用本机已登录的 Claude Code、Codex 或 Gemini CLI。

**网页**：浏览器打开服务器地址，输入令牌。支持剪贴板、P2P 文件（网页端接收上限 500MB）和 AI 对话。

### AI 对话

Mac 端会自动检测已安装的 AI CLI，并向手机和网页公布可用引擎、模型和项目。中枢服务不直接调用 AI，只转发问题和流式回复，并把最多 50 个对话保存在 `server/data/chats.json`。

- 手机端固定为只读问答，不会修改 Mac 文件
- Mac 端的修改模式需要本机设置的编辑口令
- 编辑口令只发往 Mac 校验，不会保存在服务器
- 通信协议见 [`docs/ai-chat-protocol.md`](docs/ai-chat-protocol.md)

**Python Agent**（仅剪贴板，自动双向同步）：`./start_agent.sh http://<服务器>:18888 <令牌>`

## GitHub 构建与发布

`.github/workflows/ci.yml` 会在 `main` 分支推送和 Pull Request 时执行 Flutter 静态检查与测试。

`.github/workflows/release_android.yml` 在推送 `v*` 标签时自动：

1. 检查和测试代码
2. 使用 GitHub Secrets 中的固定证书签名 APK
3. 创建 GitHub Release 并生成更新说明
4. 上传 `NelsonBox-Android-<tag>.apk`

首次发布前，在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 添加 `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` 和 `ANDROID_STORE_PASSWORD`。另可用 `NB_SERVER` 和 `NB_TOKEN` 预置中枢地址与访问令牌；不配置时由用户在 App 内填写。

生成发布证书并上传 Secret（证书和密码丢失后将无法覆盖更新已安装的 App，请另行安全备份）：

```bash
keytool -genkeypair -v -keystore nelsonbox-release.jks \
  -alias nelsonbox -keyalg RSA -keysize 4096 -validity 10000
base64 < nelsonbox-release.jks | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEY_ALIAS --body nelsonbox
gh secret set ANDROID_KEY_PASSWORD
gh secret set ANDROID_STORE_PASSWORD
```

> 之前本地构建的 APK 使用 debug 证书。第一次改用 GitHub 正式证书的版本需要先卸载旧 App；此后所有 Release 使用同一证书，即可在 App 内直接覆盖更新。

发布新版本：

```bash
git tag v1.1.0+2
git push origin v1.1.0+2
```

也可以在 GitHub Actions 页面手动运行 **Release Android APK**。App 启动时会读取 Release 中最新的 APK，版本高于当前安装版时提示下载安装。

## License

MIT License © 2026 Nelson
