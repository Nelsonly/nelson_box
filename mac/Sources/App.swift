import SwiftUI
import UniformTypeIdentifiers

@main
struct NelsonBoxApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var hub: Hub

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _hub = StateObject(wrappedValue: Hub(settings: s))
    }

    var body: some Scene {
        Window("NelsonBox", id: "main") {
            ContentView()
                .environmentObject(hub)
                .environmentObject(hub.p2p)
                .environmentObject(hub.ai)
                .environmentObject(settings)
                .frame(minWidth: 520, minHeight: 480)
                .onAppear { if hub.status == .connecting { hub.connect() } }
        }
        .defaultSize(width: 620, height: 640)

        Settings {
            SettingsView()
                .environmentObject(hub)
                .environmentObject(settings)
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var hub: Hub
    @AppStorage("tab") private var tab = 0
    @AppStorage("targetId") private var targetId = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("剪贴板").tag(0)
                Text("文件").tag(1)
                Text("AI 主机").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case 0: ClipboardView()
            case 1: FilesView()
            default: AIHostView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) { StatusView() }
            ToolbarItem(placement: .automatic) {
                if #available(macOS 14.0, *) {
                    SettingsLink { Image(systemName: "gearshape") }.help("设置")
                }
            }
        }
        .overlay(alignment: .bottom) { Toast() }
        // 往窗口任意位置拖文件都能上传
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { urls in
                tab = 1
                hub.sendFiles(urls, to: currentTarget(hub, targetId))
            }
            return true
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var settings: AppSettings
    @State private var showDevices = false

    var body: some View {
        let (text, color): (String, Color) = switch hub.status {
        case .online: ("\(hub.devices.count) 台在线", .green)
        case .connecting: ("连接中", .yellow)
        case .offline: ("已断开", .red)
        case .unauthorized: ("令牌错误", .red)
        case .notConfigured: ("未设置", .gray)
        }
        Button {
            if hub.status == .online { showDevices.toggle() } else { hub.connect() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(text)
            }
        }
        .help(hub.status == .online ? "查看在线设备" : "点击重新连接")
        .popover(isPresented: $showDevices) {
            VStack(alignment: .leading, spacing: 8) {
                Text("在线设备").font(.headline)
                ForEach(hub.devices) { d in
                    Label(d.id == settings.deviceId ? "\(d.name)（本机）" : d.name, systemImage: icon(for: d.type))
                }
            }
            .padding()
            .frame(minWidth: 200, alignment: .leading)
        }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "mac", "windows", "linux": "laptopcomputer"
        case "android": "iphone"
        default: "globe"
        }
    }
}

struct Toast: View {
    @EnvironmentObject var hub: Hub

    var body: some View {
        if let msg = hub.message {
            Text(msg)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.opacity)
                .task(id: msg) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { hub.message = nil }
                }
        }
    }
}

// MARK: - 剪贴板

struct ClipboardView: View {
    @EnvironmentObject var hub: Hub
    @State private var input = ""

    var body: some View {
        VStack(spacing: 12) {
            TextEditor(text: $input)
                .font(.body)
                .frame(height: 90)
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("输入要发送的内容…").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Button {
                    hub.sendPasteboard()
                } label: {
                    Label("发送 Mac 剪贴板", systemImage: "doc.on.clipboard")
                }
                Spacer()
                Text("\(input.utf8.count / 1024) / 64 KB").font(.caption).foregroundStyle(.secondary)
                    .opacity(input.isEmpty ? 0 : 1)
                Button("发送") {
                    if hub.sendText(input) {
                        input = ""
                        hub.message = "已发送"
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                Section("记录 · 点击复制") {
                    if hub.history.isEmpty {
                        Text("暂无记录").foregroundStyle(.secondary)
                    }
                    ForEach(hub.history) { item in
                        ClipRow(item: item)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
    }
}

struct ClipRow: View {
    @EnvironmentObject var hub: Hub
    let item: ClipItem
    @State private var copied = false

    var body: some View {
        Button {
            hub.copy(item.text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text).lineLimit(3).textSelection(.enabled)
                    Text("\(item.sender ?? "未知") · \(formatTime(item.updated_at ?? 0))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

// MARK: - 文件（P2P 直传）

func currentTarget(_ hub: Hub, _ targetId: String) -> Device? {
    hub.otherDevices.first { $0.id == targetId } ?? hub.otherDevices.first
}

struct FilesView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var p2p: P2PManager
    @AppStorage("targetId") private var targetId = ""
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        let target = currentTarget(hub, targetId)
        VStack(spacing: 12) {
            HStack {
                Text("发送到")
                Picker("", selection: Binding(get: { target?.id ?? "" }, set: { targetId = $0 })) {
                    if hub.otherDevices.isEmpty { Text("没有其他在线设备").tag("") }
                    ForEach(hub.otherDevices) { d in Text("\(d.name)（\(d.type)）").tag(d.id) }
                }
                .labelsHidden()
                .disabled(hub.otherDevices.isEmpty)
            }

            // 拖放区
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.doc").font(.title)
                Text("把文件拖到这里，或")
                Button("选择文件…") { importing = true }.disabled(target == nil)
                Text("设备之间直接传输，不经过服务器；对方需要在线").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadURLs(providers) { hub.sendFiles($0, to: target) }
                return true
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { hub.sendFiles(urls, to: target) }
            }

            List {
                Section("传输记录") {
                    if p2p.transfers.isEmpty {
                        Text("暂无记录").foregroundStyle(.secondary)
                    }
                    ForEach(p2p.transfers) { t in TransferRow(t: t) }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
    }
}

struct TransferRow: View {
    @EnvironmentObject var p2p: P2PManager
    let t: TransferInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: t.outgoing ? "arrow.up.circle" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(t.status == .failed ? .red : t.status == .done ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if t.active && t.total > 0 {
                    ProgressView(value: Double(t.done), total: Double(t.total))
                }
                Text(detail).font(.caption).foregroundStyle(t.status == .failed ? .red : .secondary)
            }
            Spacer()
            if t.active {
                Button("取消") { p2p.cancel(t.id) }.buttonStyle(.borderless)
            } else if !t.saved.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(t.saved) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless).help("在访达中显示")
            }
        }
        .padding(.vertical, 3)
    }

    private var title: String {
        let first = t.names.first ?? ""
        let more = t.names.count > 1 ? " 等 \(t.names.count) 个" : ""
        return "\(t.outgoing ? "发给" : "来自")【\(t.peerName)】 \(first)\(more)"
    }

    private var detail: String {
        var parts = ["\(formatBytes(t.done)) / \(formatBytes(t.total))"]
        if t.status == .transferring { parts.append("\(formatBytes(Int64(t.speed)))/s") }
        if !t.conn.isEmpty { parts.append(t.conn) }
        switch t.status {
        case .waiting: parts.append("等待对方响应…")
        case .connecting: parts.append("正在建立直连…")
        case .transferring: break
        case .finishing: parts.append("等待对方确认…")
        case .done: parts.append("完成")
        case .failed: parts.append("失败：\(t.error)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - AI 主机

struct AIHostView: View {
    @EnvironmentObject var ai: AIHost
    @State private var passcode = ""
    @State private var showPasscode = false

    var body: some View {
        Form {
            Section {
                ForEach(AIEngine.allCases) { e in
                    HStack {
                        Image(systemName: ai.enginePaths[e] != nil ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(ai.enginePaths[e] != nil ? .green : .secondary)
                        Text(e.title)
                        Spacer()
                        Text(ai.enginePaths[e] ?? "未安装").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Button("重新检测") { ai.detectEngines() }
            } header: {
                Text("AI 工具")
            } footer: {
                Text("在 Mac 上用你已登录的命令行工具回答其他设备的提问。NelsonBox 需要保持打开。")
            }

            Section {
                if ai.projects.isEmpty {
                    Text("还没有项目。没有选项目时，AI 在 ~/NelsonBox-AI 目录里回答问题。").foregroundStyle(.secondary)
                }
                ForEach(ai.projects) { p in
                    HStack {
                        Image(systemName: "folder")
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text(p.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { ai.projects.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("添加项目目录…") { pickFolder() }
            } header: {
                Text("项目")
            } footer: {
                Text("提问时可以选择项目，AI 会在该目录里工作。")
            }

            Section {
                HStack {
                    Group {
                        if showPasscode { TextField("编辑口令", text: $passcode) } else { SecureField("编辑口令", text: $passcode) }
                    }
                    Button { showPasscode.toggle() } label: { Image(systemName: showPasscode ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                    Button("保存") {
                        ai.setPasscode(passcode.trimmingCharacters(in: .whitespaces))
                        passcode = ""
                    }
                    .disabled(passcode.trimmingCharacters(in: .whitespaces).count < 6)
                    if ai.hasPasscode {
                        Button("清除", role: .destructive) { ai.setPasscode("") }
                    }
                }
                Label(ai.hasPasscode ? "已设置：输入了正确口令的设备可以让 AI 修改文件、运行命令"
                                     : "未设置：所有设备都只能只读问答",
                      systemImage: ai.hasPasscode ? "lock.open" : "lock")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("编辑口令（至少 6 位）")
            } footer: {
                Text("口令保存在本机钥匙串，只由这台 Mac 核对，服务器不保存。手机不输入口令，就只能问答。")
            }

            Section("最近任务") {
                if ai.activity.isEmpty { Text("暂无").foregroundStyle(.secondary) }
                ForEach(ai.activity, id: \.self) { Text($0).font(.callout) }
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        if panel.runModal() == .OK, let url = panel.url { ai.addProject(url) }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var settings: AppSettings
    @State private var server = ""
    @State private var token = ""
    @State private var name = ""

    var body: some View {
        Form {
            TextField("服务器", text: $server, prompt: Text("http://1.2.3.4:18888"))
            SecureField("令牌", text: $token)
            TextField("设备名", text: $name)
            HStack {
                Spacer()
                Button("保存并重新连接") {
                    settings.server = server.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
                    settings.token = token.trimmingCharacters(in: .whitespaces)
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { settings.deviceName = n }
                    hub.connect()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            server = settings.server
            token = settings.token
            name = settings.deviceName
        }
    }
}

// MARK: - 工具

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL { DispatchQueue.main.async { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}
