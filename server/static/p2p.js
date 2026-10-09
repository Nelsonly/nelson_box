// P2P 文件传输（WebRTC DataChannel），协议见 docs/p2p-protocol.md
// 优先直连；直连失败时经服务器 TURN 实时转发（端到端加密，服务器不存储）。
const P2P = (() => {
  const CHUNK = 16384;
  const HIGH_WATER = 1024 * 1024;
  const LOW_WATER = 256 * 1024;
  const READ_BLOCK = 1024 * 1024;
  const CONNECT_TIMEOUT = 20000;
  const WEB_RECEIVE_MAX = 500 * 1024 * 1024; // 网页端接收时整个文件在内存里

  let iceServers = [];
  let sendSignal = () => {};
  let onUpdate = () => {};
  let onReceived = () => {};
  const transfers = new Map();

  const randomId = () => Math.random().toString(36).slice(2, 12);

  function configure(opts) {
    sendSignal = opts.signal;
    onUpdate = opts.update || onUpdate;
    onReceived = opts.received || onReceived;
  }

  function setIceServers(list) {
    iceServers = list || [];
  }

  function signal(t, data) {
    sendSignal(t.peerId, { transfer_id: t.id, ...data });
  }

  function newTransfer(fields) {
    const t = {
      done: 0,
      status: "waiting",
      error: "",
      conn: "",
      startedAt: Date.now(),
      pendingIce: [],
      saved: [],
      ...fields,
    };
    transfers.set(t.id, t);
    update(t);
    return t;
  }

  let lastUpdate = 0;
  function update(t, force = true) {
    const now = Date.now();
    if (!force && now - lastUpdate < 150) return; // 进度刷新节流
    lastUpdate = now;
    onUpdate(t);
  }

  // ---------- 发送 ----------
  function sendFiles(peerId, peerName, fileList) {
    const files = [...fileList].filter((f) => f.size > 0);
    if (!files.length) return null;
    const meta = files.map((f) => ({ name: f.name, size: f.size }));
    const total = meta.reduce((n, f) => n + f.size, 0);
    const t = newTransfer({ id: randomId(), dir: "send", peerId, peerName, files: meta, total, blobs: files });
    signal(t, { kind: "offer-file", files: meta, total });
    startTimeout(t);
    return t;
  }

  async function startSender(t) {
    t.status = "connecting";
    update(t);
    const pc = createPeer(t);
    const dc = pc.createDataChannel("file", { ordered: true });
    setupChannel(t, dc);
    dc.onopen = () => {
      opened(t);
      pump(t).catch((e) => fail(t, "传输中断", true, e));
    };
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    signal(t, { kind: "sdp", sdp: { type: offer.type, sdp: offer.sdp } });
  }

  function waitLow(dc) {
    return new Promise((resolve) => {
      if (dc.bufferedAmount <= LOW_WATER) return resolve();
      dc.onbufferedamountlow = () => {
        dc.onbufferedamountlow = null;
        resolve();
      };
    });
  }

  async function pump(t) {
    const dc = t.dc;
    for (let i = 0; i < t.blobs.length; i++) {
      const file = t.blobs[i];
      dc.send(JSON.stringify({ t: "file", index: i, name: file.name, size: file.size }));
      for (let off = 0; off < file.size; off += READ_BLOCK) {
        const block = await file.slice(off, off + READ_BLOCK).arrayBuffer();
        for (let p = 0; p < block.byteLength; p += CHUNK) {
          if (isFinished(t)) return;
          if (dc.bufferedAmount > HIGH_WATER) await waitLow(dc);
          const chunk = block.slice(p, p + CHUNK);
          dc.send(chunk);
          t.done += chunk.byteLength;
          update(t, false);
        }
      }
      dc.send(JSON.stringify({ t: "end", index: i }));
    }
    dc.send(JSON.stringify({ t: "done" }));
    t.status = "finishing"; // 等对方回 ack
    update(t);
  }

  // ---------- 接收 ----------
  function incoming(from, fromName, data) {
    const t = newTransfer({
      id: data.transfer_id,
      dir: "recv",
      peerId: from,
      peerName: fromName,
      files: data.files || [],
      total: data.total || 0,
      status: "connecting",
    });
    if (t.total > WEB_RECEIVE_MAX) {
      signal(t, { kind: "decline", reason: "网页端单次最多接收 500 MB，请用 App 接收" });
      return fail(t, "超过网页端 500 MB 接收上限", false);
    }
    const pc = createPeer(t);
    pc.ondatachannel = (e) => {
      setupChannel(t, e.channel);
      e.channel.onopen = () => opened(t);
      if (e.channel.readyState === "open") opened(t);
    };
    signal(t, { kind: "accept" });
    startTimeout(t);
  }

  function onChannelMessage(t, data) {
    if (typeof data !== "string") {
      const cur = t.current;
      if (!cur) return fail(t, "数据格式错误", true);
      cur.parts.push(data);
      cur.got += data.byteLength;
      t.done += data.byteLength;
      return update(t, false);
    }
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }
    if (msg.t === "file") {
      t.current = { name: msg.name, size: msg.size, parts: [], got: 0 };
    } else if (msg.t === "end") {
      const cur = t.current;
      if (!cur || cur.got !== cur.size) return fail(t, "文件不完整", true);
      const blob = new Blob(cur.parts);
      t.saved.push({ name: cur.name, blob });
      t.current = null;
      onReceived(t, cur.name, blob);
    } else if (msg.t === "done") {
      t.dc.send(JSON.stringify({ t: "ack" }));
      complete(t);
    } else if (msg.t === "ack") {
      complete(t);
    } else if (msg.t === "error") {
      fail(t, msg.message || "对方出错", false);
    }
  }

  // ---------- 连接 ----------
  function createPeer(t) {
    const pc = new RTCPeerConnection({ iceServers });
    t.pc = pc;
    pc.onicecandidate = (e) => {
      if (e.candidate) signal(t, { kind: "ice", candidate: e.candidate.toJSON() });
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "failed") {
        fail(t, t.opened ? "传输中断" : "无法建立直连（双方网络都不支持打洞）", true);
      }
    };
    return pc;
  }

  function setupChannel(t, dc) {
    t.dc = dc;
    dc.binaryType = "arraybuffer";
    dc.bufferedAmountLowThreshold = LOW_WATER;
    dc.onmessage = (e) => onChannelMessage(t, e.data);
    dc.onclose = () => {
      if (!isFinished(t)) fail(t, "传输中断", false);
    };
  }

  function opened(t) {
    if (t.opened) return;
    t.opened = true;
    clearTimeout(t.timer);
    t.status = "transferring";
    t.startedAt = Date.now();
    update(t);
    detectConnectionType(t);
  }

  async function detectConnectionType(t) {
    try {
      const stats = await t.pc.getStats();
      let pair;
      stats.forEach((s) => {
        if (s.type === "transport" && s.selectedCandidatePairId) pair = stats.get(s.selectedCandidatePairId);
      });
      if (!pair) stats.forEach((s) => { if (s.type === "candidate-pair" && s.nominated && s.state === "succeeded") pair = s; });
      const local = pair && stats.get(pair.localCandidateId);
      const remote = pair && stats.get(pair.remoteCandidateId);
      if (!local || !remote) return;
      const isPrivate = (a) =>
        /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|169\.254\.|fe80:|f[cd][0-9a-f]{2}:|::1$)/i.test(a || "") ||
        (a || "").endsWith(".local"); // 浏览器用 mDNS 隐藏的内网地址
      const ipv6 = (local.address || "").includes(":");
      if (local.candidateType === "relay" || remote.candidateType === "relay") t.conn = "服务器中转";
      else if (isPrivate(local.address) && isPrivate(remote.address)) t.conn = "局域网直连";
      else if ([local.candidateType, remote.candidateType].some((x) => x === "srflx" || x === "prflx")) t.conn = "打洞直连";
      else t.conn = "公网直连";
      if (ipv6 && !["局域网直连", "服务器中转"].includes(t.conn)) t.conn += " · IPv6";
      update(t);
    } catch {}
  }

  async function onSdp(t, sdp) {
    const pc = t.pc;
    if (!pc) return;
    await pc.setRemoteDescription(sdp);
    if (sdp.type === "offer") {
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      signal(t, { kind: "sdp", sdp: { type: answer.type, sdp: answer.sdp } });
    }
    for (const c of t.pendingIce.splice(0)) await pc.addIceCandidate(c).catch(() => {});
  }

  async function onIce(t, candidate) {
    if (!t.pc || !t.pc.remoteDescription) {
      t.pendingIce.push(candidate);
      return;
    }
    await t.pc.addIceCandidate(candidate).catch(() => {});
  }

  function startTimeout(t) {
    t.timer = setTimeout(() => {
      if (!t.opened) fail(t, t.status === "waiting" ? "对方没有响应" : "无法建立直连（双方网络都不支持打洞）", true);
    }, CONNECT_TIMEOUT);
  }

  // ---------- 结束 ----------
  const isFinished = (t) => t.status === "done" || t.status === "failed";

  function complete(t) {
    if (isFinished(t)) return;
    t.status = "done";
    t.done = t.total;
    t.finishedAt = Date.now();
    update(t);
    cleanup(t, 1000);
  }

  function fail(t, reason, notifyPeer, err) {
    if (isFinished(t)) return;
    if (err) console.warn("P2P", err);
    t.status = "failed";
    t.error = reason;
    if (notifyPeer) signal(t, { kind: "cancel", reason });
    if (t.dc?.readyState === "open") {
      try { t.dc.send(JSON.stringify({ t: "error", message: reason })); } catch {}
    }
    t.current = null;
    update(t);
    cleanup(t, 0);
  }

  function cleanup(t, delay) {
    clearTimeout(t.timer);
    setTimeout(() => {
      try { t.dc?.close(); } catch {}
      try { t.pc?.close(); } catch {}
      t.blobs = null;
    }, delay);
  }

  function cancel(id) {
    const t = transfers.get(id);
    if (t) fail(t, "已取消", true);
  }

  // ---------- 信令入口 ----------
  function handleSignal(from, fromName, data) {
    const t = transfers.get(data.transfer_id);
    switch (data.kind) {
      case "offer-file":
        if (!t) incoming(from, fromName, data);
        break;
      case "accept":
        if (t?.dir === "send" && t.status === "waiting") startSender(t).catch((e) => fail(t, "连接失败", true, e));
        break;
      case "decline":
        if (t) fail(t, data.reason || "对方拒绝接收", false);
        break;
      case "sdp":
        if (t) onSdp(t, data.sdp).catch((e) => fail(t, "连接失败", true, e));
        break;
      case "ice":
        if (t) onIce(t, data.candidate);
        break;
      case "cancel":
        if (t) fail(t, data.reason === "已取消" ? "对方已取消" : data.reason || "对方已取消", false);
        break;
    }
  }

  function handleError(msg) {
    const t = transfers.get(msg.transfer_id);
    if (t) fail(t, msg.error || "发送失败", false);
  }

  return { configure, setIceServers, sendFiles, cancel, handleSignal, handleError, transfers };
})();
