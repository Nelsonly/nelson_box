import AppKit
import Foundation
import WebRTC

// P2P 文件传输（WebRTC DataChannel），协议见 docs/p2p-protocol.md
// 服务器只转发信令，文件数据不经过服务器。

private let chunkSize = 16384
private let highWater: UInt64 = 1024 * 1024
private let lowWater: UInt64 = 256 * 1024
private let readBlock = 1024 * 1024
private let connectTimeout: TimeInterval = 20

struct TransferInfo: Identifiable {
    enum Status { case waiting, connecting, transferring, finishing, done, failed }

    let id: String
    let outgoing: Bool
    let peerName: String
    let names: [String]
    let total: Int64
    var done: Int64 = 0
    var status: Status = .waiting
    var error = ""
    var conn = ""
    var startedAt = Date()
    var finishedAt: Date?
    var saved: [URL] = []

    var active: Bool { status != .done && status != .failed }

    var speed: Double {
        let secs = (finishedAt ?? Date()).timeIntervalSince(startedAt)
        return secs > 0 ? Double(done) / secs : 0
    }
}

final class P2PManager: ObservableObject {
    @Published private(set) var transfers: [TransferInfo] = [] // 最新的在前
    var iceServers: [[String: Any]] = []
    var sendSignal: (String, [String: Any]) -> Void = { _, _ in }
    var onNotice: (String) -> Void = { _ in }

    private var sessions: [String: Session] = [:]

    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    func send(_ urls: [URL], to peerId: String, peerName: String) {
        var sources: [Session.Source] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                onNotice("暂不支持发送文件夹：\(url.lastPathComponent)")
                continue
            }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size > 0 { sources.append(.init(url: url, name: url.lastPathComponent, size: size)) }
        }
        guard !sources.isEmpty else {
            onNotice("没有可发送的文件（空文件会被跳过）")
            return
        }
        let s = Session(manager: self, id: UUID().uuidString.prefix(10).lowercased(), peerId: peerId,
                        peerName: peerName, outgoing: true,
                        names: sources.map(\.name), total: sources.reduce(0) { $0 + $1.size })
        s.sources = sources
        add(s)
        s.signal(["kind": "offer-file", "files": sources.map { ["name": $0.name, "size": $0.size] }, "total": s.info.total])
        s.startTimeout()
    }

    func cancel(_ id: String) {
        sessions[id]?.fail("已取消", notifyPeer: true)
    }

    func handleSignal(from: String, fromName: String, data: [String: Any]) {
        guard let tid = data["transfer_id"] as? String, let kind = data["kind"] as? String else { return }
        let s = sessions[tid]
        switch kind {
        case "offer-file":
            guard s == nil else { return }
            let files = data["files"] as? [[String: Any]] ?? []
            let total = (data["total"] as? NSNumber)?.int64Value ?? 0
            let r = Session(manager: self, id: tid, peerId: from, peerName: fromName, outgoing: false,
                            names: files.compactMap { $0["name"] as? String }, total: total)
            add(r)
            r.startReceiver()
        case "accept":
            if let s, s.outgoing, s.info.status == .waiting { s.startSender() }
        case "decline":
            s?.fail(data["reason"] as? String ?? "对方拒绝接收", notifyPeer: false)
        case "sdp":
            if let sdp = data["sdp"] as? [String: Any] { s?.onRemoteSdp(sdp) }
        case "ice":
            if let c = data["candidate"] as? [String: Any] { s?.onRemoteIce(c) }
        case "cancel":
            let reason = data["reason"] as? String
            s?.fail(reason == nil || reason == "已取消" ? "对方已取消" : reason!, notifyPeer: false)
        default:
            break
        }
    }

    func handleError(transferId: String?, error: String) {
        guard let transferId else { return }
        sessions[transferId]?.fail(error, notifyPeer: false)
    }

    private func add(_ s: Session) {
        sessions[s.id] = s
        transfers.insert(s.info, at: 0)
    }

    fileprivate func publish(_ s: Session) {
        if let i = transfers.firstIndex(where: { $0.id == s.id }) { transfers[i] = s.info }
    }

    fileprivate func finished(_ s: Session) {
        // 保留记录，只释放连接对象
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.sessions[s.id] = nil }
    }
}

// MARK: - 单次传输

private final class Session: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    struct Source {
        let url: URL
        let name: String
        let size: Int64
    }

    weak var manager: P2PManager?
    let id: String
    let peerId: String
    let outgoing: Bool
    var info: TransferInfo // 只在主线程读写
    var sources: [Source] = []

    private var pc: RTCPeerConnection?
    private var dc: RTCDataChannel?
    private var pendingIce: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var opened = false
    private var timeout: DispatchWorkItem?

    private let lock = NSLock()
    private var isFinished = false
    private var waitingLow = false
    private let lowSignal = DispatchSemaphore(value: 0)
    private var bytesDone: Int64 = 0
    private var lastPublish = Date.distantPast

    // 接收状态（WebRTC 线程上按顺序访问）
    private var recvHandle: FileHandle?
    private var recvTmp: URL?
    private var recvName = ""
    private var recvSize: Int64 = 0
    private var recvGot: Int64 = 0

    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    init(manager: P2PManager, id: String, peerId: String, peerName: String, outgoing: Bool, names: [String], total: Int64) {
        self.manager = manager
        self.id = id
        self.peerId = peerId
        self.outgoing = outgoing
        info = TransferInfo(id: id, outgoing: outgoing, peerName: peerName, names: names, total: total)
        super.init()
    }

    private var finished: Bool {
        lock.lock(); defer { lock.unlock() }
        return isFinished
    }

    private func markFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isFinished { return false }
        isFinished = true
        return true
    }

    // MARK: 信令

    func signal(_ data: [String: Any]) {
        var d = data
        d["transfer_id"] = id
        onMain { self.manager?.sendSignal(self.peerId, d) }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func publish(force: Bool = true) {
        onMain {
            let now = Date()
            if !force && now.timeIntervalSince(self.lastPublish) < 0.15 { return }
            self.lastPublish = now
            self.lock.lock()
            self.info.done = self.bytesDone
            self.lock.unlock()
            self.manager?.publish(self)
        }
    }

    func startTimeout() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.opened else { return }
            self.fail(self.info.status == .waiting ? "对方没有响应" : "无法建立直连（双方网络都不支持打洞）", notifyPeer: true)
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout, execute: item)
    }

    private func makePeer() -> RTCPeerConnection? {
        let config = RTCConfiguration()
        config.iceServers = (manager?.iceServers ?? []).compactMap { s in
            let urls = (s["urls"] as? [String]) ?? ((s["urls"] as? String).map { [$0] } ?? [])
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: s["username"] as? String, credential: s["credential"] as? String)
        }
        config.sdpSemantics = .unifiedPlan
        let pc = P2PManager.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        self.pc = pc
        return pc
    }

    func startSender() {
        info.status = .connecting
        publish()
        guard let pc = makePeer() else { return fail("无法创建连接", notifyPeer: true) }
        let cfg = RTCDataChannelConfiguration()
        cfg.isOrdered = true
        guard let dc = pc.dataChannel(forLabel: "file", configuration: cfg) else {
            return fail("无法创建数据通道", notifyPeer: true)
        }
        setup(dc)
        pc.offer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp else { self?.fail("连接失败", notifyPeer: true); return }
            pc.setLocalDescription(sdp) { _ in
                self.signal(["kind": "sdp", "sdp": ["type": "offer", "sdp": sdp.sdp]])
            }
        }
    }

    func startReceiver() {
        info.status = .connecting
        publish()
        guard makePeer() != nil else { return fail("无法创建连接", notifyPeer: true) }
        signal(["kind": "accept"])
        startTimeout()
    }

    func onRemoteSdp(_ dict: [String: Any]) {
        guard let pc, let typeStr = dict["type"] as? String, let sdp = dict["sdp"] as? String else { return }
        let desc = RTCSessionDescription(type: RTCSessionDescription.type(for: typeStr), sdp: sdp)
        pc.setRemoteDescription(desc) { [weak self] err in
            guard let self else { return }
            if err != nil { return self.fail("连接失败", notifyPeer: true) }
            self.onMain {
                self.hasRemoteDescription = true
                for c in self.pendingIce { pc.add(c) { _ in } }
                self.pendingIce.removeAll()
            }
            if desc.type == .offer {
                pc.answer(for: self.constraints) { answer, _ in
                    guard let answer else { return self.fail("连接失败", notifyPeer: true) }
                    pc.setLocalDescription(answer) { _ in
                        self.signal(["kind": "sdp", "sdp": ["type": "answer", "sdp": answer.sdp]])
                    }
                }
            }
        }
    }

    func onRemoteIce(_ c: [String: Any]) {
        guard let sdp = c["candidate"] as? String, !sdp.isEmpty else { return }
        let candidate = RTCIceCandidate(sdp: sdp,
                                        sdpMLineIndex: Int32((c["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                                        sdpMid: c["sdpMid"] as? String)
        if hasRemoteDescription, let pc {
            pc.add(candidate) { _ in }
        } else {
            pendingIce.append(candidate)
        }
    }

    // MARK: 连接状态

    private func setup(_ dc: RTCDataChannel) {
        self.dc = dc
        dc.delegate = self
        if dc.readyState == .open { onMain { self.didOpen() } }
    }

    private func didOpen() {
        guard !opened else { return }
        opened = true
        timeout?.cancel()
        info.status = .transferring
        info.startedAt = Date()
        publish()
        detectConnectionType()
        if outgoing {
            DispatchQueue.global(qos: .userInitiated).async { self.pump() }
        }
    }

    private func detectConnectionType() {
        pc?.statistics { [weak self] report in
            let stats = report.statistics
            var pair: RTCStatistics?
            for s in stats.values where s.type == "transport" {
                if let pid = s.values["selectedCandidatePairId"] as? String { pair = stats[pid] }
            }
            guard let pair,
                  let lid = pair.values["localCandidateId"] as? String, let rid = pair.values["remoteCandidateId"] as? String,
                  let local = stats[lid], let remote = stats[rid] else { return }
            let la = local.values["address"] as? String ?? "", ra = remote.values["address"] as? String ?? ""
            let lt = local.values["candidateType"] as? String ?? "", rt = remote.values["candidateType"] as? String ?? ""
            var conn: String
            if lt == "relay" || rt == "relay" {
                conn = "服务器中转"
            } else if isPrivate(la) && isPrivate(ra) {
                conn = "局域网直连"
            } else if [lt, rt].contains(where: { $0 == "srflx" || $0 == "prflx" }) {
                conn = "打洞直连"
            } else {
                conn = "公网直连"
            }
            if la.contains(":") && conn != "局域网直连" && conn != "服务器中转" { conn += " · IPv6" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.info.conn = conn
                self.publish()
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .failed {
            onMain { self.fail(self.opened ? "传输中断" : "无法建立直连（双方网络都不支持打洞）", notifyPeer: true) }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        signal(["kind": "ice", "candidate": [
            "candidate": candidate.sdp,
            "sdpMid": (candidate.sdpMid as Any?) ?? NSNull(),
            "sdpMLineIndex": candidate.sdpMLineIndex,
        ]])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        setup(dataChannel)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    // MARK: 数据通道

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            onMain { self.didOpen() }
        case .closed:
            onMain { if !self.finished { self.fail("传输中断", notifyPeer: false) } }
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        lock.lock()
        if waitingLow && dataChannel.bufferedAmount <= lowWater {
            waitingLow = false
            lock.unlock()
            lowSignal.signal()
        } else {
            lock.unlock()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if finished { return }
        if buffer.isBinary {
            receiveChunk(buffer.data)
        } else if let obj = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] {
            receiveControl(obj)
        }
    }

    private func sendControl(_ obj: [String: Any]) -> Bool {
        guard let dc, let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        return dc.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    // MARK: 发送

    private func waitForLowWater(_ dc: RTCDataChannel) {
        lock.lock()
        waitingLow = true
        lock.unlock()
        if dc.bufferedAmount <= lowWater {
            lock.lock()
            waitingLow = false
            lock.unlock()
            return
        }
        _ = lowSignal.wait(timeout: .now() + 30)
    }

    private func pump() {
        guard let dc else { return }
        for (i, src) in sources.enumerated() {
            guard sendControl(["t": "file", "index": i, "name": src.name, "size": src.size]) else {
                return fail("传输中断", notifyPeer: true)
            }
            guard let fh = try? FileHandle(forReadingFrom: src.url) else {
                return fail("无法读取 \(src.name)", notifyPeer: true)
            }
            defer { try? fh.close() }
            while true {
                if finished { return }
                guard let block = try? fh.read(upToCount: readBlock), !block.isEmpty else { break }
                var off = 0
                while off < block.count {
                    if finished { return }
                    if dc.bufferedAmount > highWater { waitForLowWater(dc) }
                    let end = min(off + chunkSize, block.count)
                    let chunk = block.subdata(in: off ..< end)
                    guard dc.sendData(RTCDataBuffer(data: chunk, isBinary: true)) else {
                        return fail("传输中断", notifyPeer: true)
                    }
                    off = end
                    lock.lock(); bytesDone += Int64(chunk.count); lock.unlock()
                    publish(force: false)
                }
            }
            _ = sendControl(["t": "end", "index": i])
        }
        _ = sendControl(["t": "done"])
        onMain {
            guard !self.finished else { return }
            self.info.status = .finishing // 等对方回 ack
            self.publish()
        }
    }

    // MARK: 接收

    private func receiveControl(_ msg: [String: Any]) {
        switch msg["t"] as? String {
        case "file":
            closeRecvFile(remove: true)
            recvName = safeFileName(msg["name"] as? String ?? "")
            recvSize = (msg["size"] as? NSNumber)?.int64Value ?? 0
            recvGot = 0
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nelsonbox-\(id)-\(UUID().uuidString).part")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            recvTmp = tmp
            recvHandle = try? FileHandle(forWritingTo: tmp)
            if recvHandle == nil { fail("无法写入文件", notifyPeer: true) }
        case "end":
            guard let tmp = recvTmp, recvGot == recvSize else { return fail("文件不完整", notifyPeer: true) }
            try? recvHandle?.close()
            recvHandle = nil
            recvTmp = nil
            let dest = uniqueDownloadURL(for: recvName)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                onMain {
                    self.info.saved.append(dest)
                    self.publish()
                }
            } catch {
                fail("保存失败：\(error.localizedDescription)", notifyPeer: true)
            }
        case "done":
            _ = sendControl(["t": "ack"])
            onMain { self.complete() }
        case "ack":
            onMain { self.complete() }
        case "error":
            let m = msg["message"] as? String ?? "对方出错"
            onMain { self.fail(m, notifyPeer: false) }
        default:
            break
        }
    }

    private func receiveChunk(_ data: Data) {
        guard let h = recvHandle else { return fail("数据格式错误", notifyPeer: true) }
        do {
            try h.write(contentsOf: data)
        } catch {
            return fail("写入失败（磁盘满了？）", notifyPeer: true)
        }
        recvGot += Int64(data.count)
        lock.lock(); bytesDone += Int64(data.count); lock.unlock()
        publish(force: false)
    }

    private func closeRecvFile(remove: Bool) {
        try? recvHandle?.close()
        recvHandle = nil
        if remove, let tmp = recvTmp { try? FileManager.default.removeItem(at: tmp) }
        recvTmp = nil
    }

    // MARK: 结束

    private func complete() {
        guard markFinished() else { return }
        info.status = .done
        lock.lock(); bytesDone = info.total; lock.unlock()
        info.finishedAt = Date()
        publish()
        manager?.onNotice(outgoing ? "已发送给【\(info.peerName)】" : "已收到【\(info.peerName)】的文件，保存在“下载”")
        if !outgoing, let first = info.saved.first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
        cleanup(after: 1)
    }

    func fail(_ reason: String, notifyPeer: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.fail(reason, notifyPeer: notifyPeer) }
            return
        }
        guard markFinished() else { return }
        timeout?.cancel()
        info.status = .failed
        info.error = reason
        info.finishedAt = Date()
        if notifyPeer { signal(["kind": "cancel", "reason": reason]) }
        if dc?.readyState == .open { _ = sendControl(["t": "error", "message": reason]) }
        lowSignal.signal() // 唤醒可能在等缓冲区的发送线程
        publish()
        manager?.onNotice("传输失败：\(reason)")
        cleanup(after: 0)
    }

    private func cleanup(after delay: TimeInterval) {
        timeout?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.dc?.close()
            self.pc?.close()
            self.closeRecvFile(remove: true)
            self.manager?.finished(self)
        }
    }
}

// MARK: - 工具

private func isPrivate(_ a: String) -> Bool {
    let pattern = #"^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|169\.254\.|fe80:|f[cd][0-9a-f]{2}:|::1$)"#
    return a.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil || a.hasSuffix(".local")
}

/// 只保留文件名本身，防止对方传来 ../ 之类的路径
private func safeFileName(_ name: String) -> String {
    var n = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    while n.hasPrefix(".") { n.removeFirst() }
    n = n.trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? "file" : String(n.prefix(200))
}
