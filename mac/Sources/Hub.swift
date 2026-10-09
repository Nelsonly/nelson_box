import AppKit
import Foundation

let maxClipboardBytes = 64 * 1024 // 与服务端上限一致

// MARK: - 数据

struct ClipItem: Decodable, Identifiable {
    let text: String
    let sender: String?
    let sender_id: String?
    let updated_at: Double?
    var id: String { text }
}

struct Device: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String
}

// MARK: - 设置

final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var server: String { didSet { d.set(server, forKey: "server") } }
    @Published var token: String { didSet { d.set(token, forKey: "token") } }
    @Published var deviceName: String { didSet { d.set(deviceName, forKey: "deviceName") } }
    let deviceId: String

    init() {
        server = d.string(forKey: "server") ?? defaultServer
        token = d.string(forKey: "token") ?? defaultToken
        deviceName = d.string(forKey: "deviceName") ?? (Host.current().localizedName ?? "Mac")
        if let id = d.string(forKey: "deviceId") {
            deviceId = id
        } else {
            deviceId = "mac_" + UUID().uuidString.prefix(8).lowercased()
            d.set(deviceId, forKey: "deviceId")
        }
    }

    var configured: Bool { !server.isEmpty && !token.isEmpty }
}

// MARK: - 中枢连接（剪贴板 + P2P 信令）

final class Hub: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    enum Status { case notConfigured, connecting, online, offline, unauthorized }

    let settings: AppSettings
    let p2p = P2PManager()
    @Published private(set) var status: Status = .connecting
    @Published private(set) var history: [ClipItem] = []
    @Published private(set) var devices: [Device] = []
    @Published var message: String?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?

    var otherDevices: [Device] { devices.filter { $0.id != settings.deviceId } }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        p2p.sendSignal = { [weak self] to, data in
            self?.sendJSON(["type": "rtc:signal", "to": to, "data": data])
        }
        p2p.onNotice = { [weak self] in self?.message = $0 }
    }

    // MARK: 连接

    func connect() {
        reconnectTimer?.invalidate()
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil

        guard settings.configured, var comps = URLComponents(string: settings.server) else {
            status = .notConfigured
            return
        }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = "/ws"
        comps.queryItems = [
            URLQueryItem(name: "device_id", value: settings.deviceId),
            URLQueryItem(name: "name", value: settings.deviceName),
            URLQueryItem(name: "device_type", value: "mac"),
            URLQueryItem(name: "token", value: settings.token),
        ]
        guard let url = comps.url else {
            status = .notConfigured
            return
        }
        status = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                switch result {
                case .success(.string(let s)):
                    self.handle(s)
                    self.receive(t)
                case .success:
                    self.receive(t)
                case .failure:
                    self.closed(t, code: t.closeCode.rawValue)
                }
            }
        }
    }

    private func closed(_ t: URLSessionWebSocketTask, code: Int) {
        if code == 4001 {
            reconnectTimer?.invalidate()
            task = nil
            status = .unauthorized
            return
        }
        guard t === task else { return }
        task = nil
        pingTimer?.invalidate()
        status = .offline
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.connect() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        status = .online
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak webSocketTask] _ in
            webSocketTask?.sendPing { _ in }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closed(webSocketTask, code: closeCode.rawValue)
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        func decode<T: Decodable>(_ value: Any?, as: T.Type) -> T? {
            guard let value, let d = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(T.self, from: d)
        }
        switch type {
        case "clipboard:history":
            history = decode(obj["history"], as: [ClipItem].self) ?? []
        case "clipboard:sync":
            if let item = decode(obj["data"], as: ClipItem.self) { addHistory(item) }
        case "devices:update":
            devices = decode(obj["devices"], as: [Device].self) ?? []
        case "clipboard:error":
            message = obj["error"] as? String
        case "rtc:config":
            p2p.iceServers = obj["ice_servers"] as? [[String: Any]] ?? []
        case "rtc:signal":
            if let from = obj["from"] as? String, let d = obj["data"] as? [String: Any] {
                p2p.handleSignal(from: from, fromName: obj["from_name"] as? String ?? "其他设备", data: d)
            }
        case "rtc:error":
            p2p.handleError(transferId: obj["transfer_id"] as? String, error: obj["error"] as? String ?? "发送失败")
        default:
            break
        }
    }

    // MARK: 剪贴板

    func sendText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.utf8.count <= maxClipboardBytes else {
            message = "内容超过 64KB 上限"
            return false
        }
        guard status == .online else {
            message = "未连接到服务器"
            return false
        }
        sendJSON(["type": "clipboard:send", "text": text])
        addHistory(ClipItem(text: text, sender: settings.deviceName, sender_id: settings.deviceId,
                            updated_at: Date().timeIntervalSince1970))
        return true
    }

    func sendPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            message = "Mac 剪贴板里没有文字"
            return
        }
        if sendText(text) { message = "已发送 Mac 剪贴板" }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func addHistory(_ item: ClipItem) {
        history.removeAll { $0.text == item.text }
        history.insert(item, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
    }

    // MARK: 文件（P2P）

    func sendFiles(_ urls: [URL], to device: Device?) {
        guard status == .online else {
            message = "未连接到服务器"
            return
        }
        guard let device else {
            message = "没有可发送的在线设备"
            return
        }
        p2p.send(urls, to: device.id, peerName: device.name)
    }
}

// MARK: - 工具

/// ~/Downloads/名字，已存在则加 (1)、(2)…
func uniqueDownloadURL(for name: String) -> URL {
    let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var url = dir.appendingPathComponent(name)
    var n = 1
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        n += 1
    }
    return url
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}

func formatTime(_ ts: Double) -> String {
    let d = Date(timeIntervalSince1970: ts)
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
    return f.string(from: d)
}
