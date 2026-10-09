# AI 聊天协议

手机 / Windows 网页通过服务器，和 Mac 上的 AI 命令行工具（Claude Code / Codex / Antigravity）对话。

```text
客户端 ──ai:send──▶ 服务器（保存对话）──ai:run──▶ Mac（AI 主机，调用命令行）
客户端 ◀─ai:delta / ai:msg── 服务器 ◀─ai:delta / ai:done── Mac
```

- 服务器不调用 AI，只转发、保存对话文字（最多 50 个对话 × 200 条消息）。
- Mac 在本机运行 AI，用的是本机登录的账号。客户端掉线不影响 Mac 继续生成，重连后用 `ai:open` 拿到完整内容。
- 所有消息都走现有的 WebSocket（`/ws`），需要令牌。

## 权限

| 模式 | `mode` | 条件 | AI 能做什么 |
|---|---|---|---|
| 只读问答 | `ask` | 无 | 读所选项目的文件、回答问题；不能改文件、不能执行有副作用的命令 |
| 可修改 | `edit` | 请求带 `passcode`，且与 Mac 上设置的编辑口令一致 | 在项目目录里改文件、运行命令 |

口令只由 Mac 核对，服务器不保存。口令错误时 Mac 直接拒绝（回复状态 `error`）。
Android App 只用 `ask` 模式，不提供口令输入。

## 客户端 → 服务器

| type | 字段 | 说明 |
|---|---|---|
| `ai:list` | — | 请求对话列表，服务器回 `ai:convs` 和 `ai:hosts` |
| `ai:open` | `conv_id` | 请求完整对话，服务器回 `ai:conv` |
| `ai:send` | `conv_id?`, `engine`, `project`, `text`, `mode`, `model?`, `effort?`, `passcode?`, `client_req?` | 发消息。`model` / `effort` 每条消息都可以不同，空或不传表示用 Mac 上该工具的默认设置。没有 `conv_id` 时新建对话（`engine`、`project` 只在新建时生效，之后固定）。服务器回 `ai:conv`（带 `client_req` 原样返回，用于对应新建的对话） |
| `ai:cancel` | `msg_id` | 取消正在生成的回复 |
| `ai:delete` | `conv_id` | 删除对话 |

`engine`：`claude` / `codex` / `antigravity`。`project`：Mac 上配置的项目名，空字符串表示不选项目（Mac 在 `~/NelsonBox-AI` 里回答）。

## 服务器 → 客户端

| type | 字段 | 说明 |
|---|---|---|
| `ai:hosts` | `hosts: [{id, name, engines: [{id, name, available, default_model, default_effort, models: [{id, name, efforts: [..]}]}], projects: [{name}], edit_enabled}]` | 在线的 AI 主机。空数组表示 Mac 不在线。`models` 是可选模型，`efforts` 为空表示该模型不支持选推理强度；`default_model` / `default_effort` 是不指定时实际会用的（可能为空，表示未知） |
| `ai:convs` | `convs: [{id, title, engine, project, updated_at, busy}]` | 对话列表（新的在前），有变化时推送 |
| `ai:conv` | `conv`, `client_req?` | 完整对话 |
| `ai:delta` | `conv_id`, `msg_id`, `text` | 回复的增量文字，追加到该消息 |
| `ai:msg` | `conv_id`, `message` | 单条消息的完整最新状态（替换本地那条） |
| `ai:error` | `error` | 请求被拒（如上一条还没回复完） |

对话 `conv`：

```json
{"id": "…", "title": "…", "engine": "codex", "project": "nelson_box", "session": "…",
 "created_at": 0, "updated_at": 0,
 "messages": [
   {"id": "…", "role": "user", "text": "…", "sender": "Windows", "mode": "ask", "status": "done", "created_at": 0},
   {"id": "…", "role": "assistant", "text": "…", "status": "running", "engine": "codex", "mode_used": "ask",
    "model": "gpt-6-sol", "effort": "high", "error": "…"}
 ]}
```

助手消息的 `model` / `effort` 是这条回复实际使用的模型和推理强度（Mac 在 `ai:done` 里回报，没指定时为默认值）。

消息 `status`：`pending`（等 Mac 接手）→ `running`（生成中）→ `done` / `error` / `cancelled`。

回复文字是 Markdown。工具调用以引用行显示，例如 `> ▶ \`git status\``、`> ✏️ 修改了 a.py`。

## 服务器 ↔ Mac（AI 主机）

- Mac 连上后发 `ai:host {name, engines, projects, edit_enabled}`，能力变化时再发。
- 服务器发 `ai:run {conv_id, msg_id, engine, project, session, text, mode, model, effort, passcode, from_name}`、`ai:cancel {msg_id}`。
- Mac 回 `ai:delta {msg_id, text}`、`ai:done {msg_id, status, text, error?, session?, mode_used, model, effort}`。
- Mac 重连后对进行中的任务发 `ai:snapshot {msg_id, text}` 补齐内容。主机掉线超过 2 分钟，进行中的回复标记为失败。
