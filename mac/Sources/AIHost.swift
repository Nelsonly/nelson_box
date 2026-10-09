import Foundation
import Security

// Mac 作为 AI 主机：收到服务器转来的提问，在本机调用 claude / codex / gemini 命令行，
// 把输出流式发回服务器。服务器只转发和保存文字，AI 都在本机运行，用的是本机登录的账号。
//
// 权限：
// - 只读问答（默认）：AI 只能读取所选项目的文件，不能修改、不能执行命令
// - 可修改：请求里带的编辑口令和本机设置的一致才允许，AI 可在项目目录里改文件、运行命令

struct AIProject: Codable, Hashable, Identifiable {
    var name: String
    var path: String
    var id: String { name }
}

/// 某个 AI 工具可选的模型，以及不指定时的默认值
struct EngineModels {
    var models: [(id: String, name: String, efforts: [String])] = []
    var defaultModel: String?
    var defaultEffort: String?

    var json: [[String: Any]] { models.map { ["id": $0.id, "name": $0.name, "efforts": $0.efforts] } }

    func allows(model: String) -> Bool { models.contains { $0.id == model } }
    func allows(effort: String, model: String?) -> Bool {
        let m = model ?? defaultModel
        return models.first { $0.id == m }?.efforts.contains(effort) ?? false
    }
}

enum AIEngine: String, CaseIterable, Identifiable {
    case claude, codex, gemini
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    /// 命令行可执行文件的常见位置（GUI 程序拿不到终端的 PATH，所以先查这些）
    var candidates: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .claude: return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        case .codex: return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]
        case .gemini: return ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "\(home)/.local/bin/gemini"]
        }
    }
}

final class AIHost: ObservableObject {
    @Published var projects: [AIProject] { didSet { saveProjects(); onChange() } }
    @Published private(set) var hasPasscode: Bool
    @Published private(set) var enginePaths: [AIEngine: String] = [:]
    @Published private(set) var engineModels: [AIEngine: EngineModels] = [:]
    @Published private(set) var activity: [String] = [] // 最近的任务记录，显示在界面上

    /// 由 Hub 设置：发消息给服务器、当前是否在线
    var send: ([String: Any]) -> Void = { _ in }
    var isOnline: () -> Bool = { false }
    var hostName: () -> String = { "Mac" }

    private var runs: [String: AIRun] = [:]
    private var pendingDone: [[String: Any]] = [] // 断线期间结束的任务，重连后补发
    private var shellPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private let maxConcurrent = 3

    static let defaultDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("NelsonBox-AI")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: "aiProjects"),
           let list = try? JSONDecoder().decode([AIProject].self, from: data) {
            projects = list
        } else {
            projects = []
        }
        hasPasscode = Keychain.get("aiPasscode")?.isEmpty == false
        detectEngines()
    }

    // MARK: 设置

    private func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) { UserDefaults.standard.set(data, forKey: "aiProjects") }
    }

    func setPasscode(_ code: String) {
        if code.isEmpty { Keychain.delete("aiPasscode") } else { Keychain.set("aiPasscode", code) }
        hasPasscode = !code.isEmpty
        onChange()
    }

    func addProject(_ url: URL) {
        var name = url.lastPathComponent
        var n = 2
        while projects.contains(where: { $0.name == name }) { name = "\(url.lastPathComponent) \(n)"; n += 1 }
        projects.append(AIProject(name: name, path: url.path))
    }

    /// 在登录 shell 里找命令行工具的位置，并记下完整 PATH（gemini 等依赖 node）
    func detectEngines() {
        DispatchQueue.global().async {
            let path = Self.shell("echo $PATH").trimmingCharacters(in: .whitespacesAndNewlines)
            var found: [AIEngine: String] = [:]
            for e in AIEngine.allCases {
                let fromShell = Self.shell("command -v \(e.rawValue)").trimmingCharacters(in: .whitespacesAndNewlines)
                let list = (fromShell.hasPrefix("/") ? [fromShell] : []) + e.candidates
                if let p = list.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { found[e] = p }
            }
            let models = Dictionary(uniqueKeysWithValues: AIEngine.allCases.map { ($0, Self.loadModels($0)) })
            DispatchQueue.main.async {
                if path.contains("/") { self.shellPath = path + ":/usr/local/bin:/opt/homebrew/bin" }
                self.enginePaths = found
                self.engineModels = models
                self.onChange()
            }
        }
    }

    /// 读取各工具可选的模型：Codex 用本机缓存的账号模型列表，其他用常用模型别名
    private static func loadModels(_ engine: AIEngine) -> EngineModels {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var em = EngineModels()
        switch engine {
        case .codex:
            if let data = try? Data(contentsOf: home.appendingPathComponent(".codex/models_cache.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["models"] as? [[String: Any]] {
                for m in list where (m["visibility"] as? String ?? "list") == "list" {
                    guard let id = m["slug"] as? String else { continue }
                    let efforts = (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                    em.models.append((id, m["display_name"] as? String ?? id, efforts))
                }
            }
            if let toml = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
                em.defaultModel = tomlValue(toml, "model")
                em.defaultEffort = tomlValue(toml, "model_reasoning_effort")
            }
        case .claude:
            em.models = [("claude-fable-5-1", "Claude Fable 5.1", []), ("opus", "Claude Opus（最新）", []),
                         ("sonnet", "Claude Sonnet（最新）", []), ("haiku", "Claude Haiku（最新）", [])]
            if let data = try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                em.defaultModel = obj["model"] as? String
            }
        case .gemini:
            em.models = [("pro", "Gemini Pro", []), ("flash", "Gemini Flash", []), ("flash-lite", "Gemini Flash-Lite", [])]
        }
        return em
    }

    /// 只取 TOML 顶层（第一个 [section] 之前）的 key = "value"
    private static func tomlValue(_ toml: String, _ key: String) -> String? {
        for line in toml.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }
            let parts = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return nil
    }

    private static func shell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", cmd + " 2>/dev/null | tail -1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 和服务器的交互

    /// 能力有变化或重新连上服务器时，告诉服务器本机能做什么
    func onChange() {
        guard isOnline() else { return }
        send([
            "type": "ai:host",
            "name": hostName(),
            "engines": AIEngine.allCases.map { e -> [String: Any] in
                let m = engineModels[e] ?? EngineModels()
                return ["id": e.rawValue, "name": e.title, "available": enginePaths[e] != nil, "models": m.json,
                        "default_model": m.defaultModel ?? "", "default_effort": m.defaultEffort ?? ""]
            },
            "projects": projects.map { ["name": $0.name] },
            "edit_enabled": hasPasscode,
        ])
    }

    func onConnected() {
        onChange()
        for run in runs.values { send(["type": "ai:snapshot", "msg_id": run.msgId, "text": run.text]) }
        for d in pendingDone { send(d) }
        pendingDone.removeAll()
    }

    func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "ai:run": start(obj)
        case "ai:cancel": if let id = obj["msg_id"] as? String { runs[id]?.cancel() }
        default: break
        }
    }

    private func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        activity.insert("\(f.string(from: Date())) \(line)", at: 0)
        if activity.count > 30 { activity.removeLast() }
    }

    // MARK: 执行

    private func start(_ req: [String: Any]) {
        guard let msgId = req["msg_id"] as? String else { return }
        let fail = { (msg: String) in self.finish(msgId: msgId, text: msg, status: "error", error: msg, session: nil, mode: nil) }

        guard let engine = AIEngine(rawValue: req["engine"] as? String ?? ""), let exe = enginePaths[engine] else {
            return fail("这台 Mac 上没有安装或找不到 \(req["engine"] as? String ?? "") 命令行工具")
        }
        guard runs.count < maxConcurrent else { return fail("Mac 上同时进行的任务太多，请稍后再试") }

        let wantEdit = (req["mode"] as? String) == "edit"
        if wantEdit {
            let code = Keychain.get("aiPasscode") ?? ""
            guard !code.isEmpty, constantTimeEqual(code, req["passcode"] as? String ?? "") else {
                log("拒绝 \(req["from_name"] as? String ?? "") 的修改请求：编辑口令不对")
                return fail("编辑口令错误，已拒绝修改请求（可以改用只读问答）")
            }
        }

        let projectName = req["project"] as? String ?? ""
        let cwd: URL
        if let p = projects.first(where: { $0.name == projectName }) {
            cwd = URL(fileURLWithPath: p.path)
        } else if projectName.isEmpty {
            cwd = Self.defaultDir
        } else {
            return fail("Mac 上没有名为“\(projectName)”的项目")
        }

        let prompt = req["text"] as? String ?? ""
        // 只接受本机提供的模型和推理强度，防止被塞进奇怪的参数
        let em = engineModels[engine] ?? EngineModels()
        let model = (req["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let effort = (req["effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let model, !em.allows(model: model) { return fail("Mac 上的 \(engine.title) 没有模型 \(model)") }
        if let effort, !em.allows(effort: effort, model: model) { return fail("模型不支持推理强度 \(effort)") }
        let modelUsed = model ?? em.defaultModel
        let effortUsed = effort ?? (engine == .codex ? em.defaultEffort : nil)
        let session = req["session"] as? String
        let run = AIRun(msgId: msgId, engine: engine, edit: wantEdit)
        run.onDelta = { [weak self] delta in
            guard let self, self.isOnline() else { return }
            self.send(["type": "ai:delta", "msg_id": msgId, "text": delta])
        }
        run.onFinish = { [weak self] status, error, session in
            guard let self else { return }
            self.runs[msgId] = nil
            self.finish(msgId: msgId, text: run.text, status: status, error: error, session: session,
                        mode: wantEdit ? "edit" : "ask", model: modelUsed, effort: effortUsed)
            self.log("\(engine.title) \(status == "done" ? "完成" : status == "cancelled" ? "已取消" : "失败")")
        }
        runs[msgId] = run
        send(["type": "ai:delta", "msg_id": msgId, "text": ""]) // 告诉客户端 Mac 已开始处理
        log("\(req["from_name"] as? String ?? "") → \(engine.title)（\(wantEdit ? "可修改" : "只读")）\(projectName.isEmpty ? "" : " @\(projectName)")")
        run.start(exe: exe, args: arguments(engine, prompt: prompt, session: session, edit: wantEdit, cwd: cwd,
                                             model: model, effort: effort),
                  cwd: cwd, path: shellPath)
    }

    private func finish(msgId: String, text: String, status: String, error: String?, session: String?, mode: String?,
                        model: String? = nil, effort: String? = nil) {
        var d: [String: Any] = ["type": "ai:done", "msg_id": msgId, "status": status, "text": text]
        if let error { d["error"] = error }
        if let session { d["session"] = session }
        if let mode { d["mode_used"] = mode }
        d["model"] = model ?? ""
        d["effort"] = effort ?? ""
        if isOnline() { send(d) } else { pendingDone.append(d) }
    }

    private func arguments(_ engine: AIEngine, prompt: String, session: String?, edit: Bool, cwd: URL,
                           model: String?, effort: String?) -> [String] {
        switch engine {
        case .claude:
            var a = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            if let model { a += ["--model", model] }
            if let session { a += ["--resume", session] }
            a += edit ? ["--permission-mode", "bypassPermissions"]
                      : ["--permission-mode", "default", "--disallowedTools", "Bash,Edit,Write,MultiEdit,NotebookEdit"]
            return a
        case .codex:
            var a = ["exec", "--json", "--skip-git-repo-check", "-C", cwd.path]
            if let model { a += ["-m", model] }
            if let effort { a += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            a += edit ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--sandbox", "read-only"]
            if let session { a += ["resume", session] }
            return a + [prompt]
        case .gemini:
            var a = ["-p", prompt, "--output-format", "stream-json"]
            if let model { a += ["-m", model] }
            if let session { a += ["--resume", session] }
            a += ["--approval-mode", edit ? "yolo" : "default"]
            return a
        }
    }
}

// MARK: - 单次执行

final class AIRun {
    let msgId: String
    let engine: AIEngine
    let edit: Bool
    private(set) var text = "" // 已输出的完整内容（主线程）
    var onDelta: (String) -> Void = { _ in }
    var onFinish: (String, String?, String?) -> Void = { _, _, _ in }

    private let process = Process()
    private var buffer = Data()
    private var stderrTail = ""
    private var session: String?
    private var resultError: String?
    private var cancelled = false
    private var pendingDelta = ""
    private var flushTimer: Timer?

    init(msgId: String, engine: AIEngine, edit: Bool) {
        self.msgId = msgId
        self.engine = engine
        self.edit = edit
    }

    func start(exe: String, args: [String], cwd: URL, path: String) {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["NO_COLOR"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + s).suffix(2000))
            }
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { self?.terminated(status: p.terminationStatus, rest: rest) }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.flush() }
        do {
            try process.run()
        } catch {
            flushTimer?.invalidate()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            onFinish("error", "无法启动 \(engine.title)：\(error.localizedDescription)", nil)
        }
    }

    func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    private func emit(_ s: String) {
        guard !s.isEmpty else { return }
        text += s
        pendingDelta += s
    }

    private func flush() {
        guard !pendingDelta.isEmpty else { return }
        onDelta(pendingDelta)
        pendingDelta = ""
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex ..< nl)
            buffer.removeSubrange(buffer.startIndex ... nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { parse(obj) }
        }
    }

    private func terminated(status: Int32, rest: Data) {
        consume(rest + Data([0x0A]))
        flushTimer?.invalidate()
        flush()
        if cancelled {
            onFinish("cancelled", "已取消", session)
        } else if let resultError {
            onFinish("error", resultError, session)
        } else if status != 0 && text.isEmpty {
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            onFinish("error", "\(engine.title) 退出（代码 \(status)）\(tail.isEmpty ? "" : "：\n" + String(tail.suffix(600)))", session)
        } else {
            onFinish("done", nil, session)
        }
    }

    // MARK: 解析各工具的 JSON 事件流

    private func parse(_ o: [String: Any]) {
        switch engine {
        case .claude: parseClaude(o)
        case .codex: parseCodex(o)
        case .gemini: parseGemini(o)
        }
    }

    private var claudeStreamed = false

    private func parseClaude(_ o: [String: Any]) {
        if let sid = o["session_id"] as? String { session = sid }
        switch o["type"] as? String {
        case "stream_event":
            let ev = o["event"] as? [String: Any] ?? [:]
            if ev["type"] as? String == "content_block_delta",
               let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                claudeStreamed = true
                emit(t)
            } else if ev["type"] as? String == "message_stop" {
                emit("\n\n")
            }
        case "assistant":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content {
                if c["type"] as? String == "tool_use" {
                    emit(toolLine(c["name"] as? String ?? "工具", c["input"]))
                } else if c["type"] as? String == "text", !claudeStreamed, let t = c["text"] as? String {
                    emit(t + "\n\n")
                }
            }
        case "result":
            if o["is_error"] as? Bool == true {
                resultError = o["result"] as? String ?? "Claude 出错"
            }
        default:
            break
        }
    }

    private func parseCodex(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "thread.started":
            session = o["thread_id"] as? String
        case "item.started", "item.completed":
            let item = o["item"] as? [String: Any] ?? [:]
            let started = o["type"] as? String == "item.started"
            switch item["type"] as? String {
            case "agent_message":
                if !started, let t = item["text"] as? String { emit(t + "\n\n") }
            case "command_execution":
                if started { emit("> ▶ `\(oneLine(item["command"] as? String ?? ""))`\n\n") }
            case "file_change":
                if !started {
                    let files = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                    emit("> ✏️ 修改了 \(files.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))\n\n")
                }
            case "error":
                // 对话中途换模型时 Codex 会提示“会话原来用的是另一个模型”，这是预期行为，不显示
                if let m = item["message"] as? String, !m.hasPrefix("This session was recorded with model") {
                    emit("> ⚠️ \(m)\n\n")
                }
            default:
                break
            }
        case "turn.failed", "error":
            let e = (o["error"] as? [String: Any])?["message"] as? String ?? o["message"] as? String
            resultError = e ?? "Codex 出错"
        default:
            break
        }
    }

    private func parseGemini(_ o: [String: Any]) {
        if let sid = o["session_id"] as? String { session = sid }
        switch o["type"] as? String {
        case "message":
            if o["role"] as? String == "assistant", let t = o["content"] as? String { emit(t) }
        case "tool_use":
            emit("\n\n" + toolLine(o["tool_name"] as? String ?? "工具", o["parameters"]))
        case "result":
            emit("\n\n")
            if o["status"] as? String == "error" {
                resultError = ((o["error"] as? [String: Any])?["message"] as? String) ?? "Gemini 出错"
            }
        case "error":
            if let m = o["message"] as? String { emit("> ⚠️ \(m)\n\n") }
        default:
            break
        }
    }

    private func toolLine(_ name: String, _ input: Any?) -> String {
        let inp = input as? [String: Any] ?? [:]
        let detail = (inp["command"] ?? inp["file_path"] ?? inp["path"] ?? inp["pattern"] ?? inp["url"]) as? String
        return "> 🔧 \(name)\(detail.map { "：`\(oneLine($0))`" } ?? "")\n\n"
    }

    private func oneLine(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count > 120 ? String(t.prefix(120)) + "…" : t
    }
}

// MARK: - 工具

private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0 ..< x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}

/// 编辑口令存在钥匙串里
enum Keychain {
    private static let service = "com.nelsonbox.mac"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
