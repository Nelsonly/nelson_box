const MAX_BYTES = 64 * 1024;
const TOKEN_KEY = "nelson_token";
const DEVICE_KEY = "nelson_device_id";

const $ = (id) => document.getElementById(id);
const storage = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch {} },
  del(k) { try { localStorage.removeItem(k); } catch {} },
};

let token = storage.get(TOKEN_KEY);
// 每个标签页一个设备 ID：同一浏览器开两个页面也能互传，不会互相挤下线
let deviceId = null;
try { deviceId = sessionStorage.getItem(DEVICE_KEY); } catch {}
if (!deviceId) {
  deviceId = "web_" + Math.random().toString(36).slice(2, 10);
  try { sessionStorage.setItem(DEVICE_KEY, deviceId); } catch {}
}
const deviceName = /iPhone|iPad|Android/i.test(navigator.userAgent) ? "手机浏览器" : "网页端";

let ws = null;
let history = [];
let devices = [];
let reconnectTimer = null;

// ---------- 连接 ----------
function connect() {
  clearTimeout(reconnectTimer);
  setStatus("连接中...", "");
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const qs = new URLSearchParams({ device_id: deviceId, name: deviceName, device_type: "web", token });
  ws = new WebSocket(`${proto}//${location.host}/ws?${qs}`);

  ws.onopen = () => {
    showApp();
    AI.onConnected();
  };
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.type === "clipboard:history") {
      history = msg.history;
      renderHistory();
    } else if (msg.type === "clipboard:sync") {
      history = [msg.data, ...history.filter((h) => h.text !== msg.data.text)].slice(0, 50);
      renderHistory();
      toast(`收到来自【${msg.data.sender}】的内容`);
    } else if (msg.type === "devices:update") {
      devices = msg.devices;
      renderDevices();
      renderTargets();
    } else if (msg.type === "clipboard:error") {
      toast(msg.error);
    } else if (msg.type.startsWith("ai:")) {
      AI.handle(msg);
    } else if (msg.type === "rtc:config") {
      P2P.setIceServers(msg.ice_servers);
    } else if (msg.type === "rtc:signal") {
      P2P.handleSignal(msg.from, msg.from_name, msg.data);
    } else if (msg.type === "rtc:error") {
      P2P.handleError(msg);
    }
  };
  ws.onclose = (e) => {
    if (e.code === 4001) {
      logout("令牌错误");
      return;
    }
    setStatus("已断开", "offline");
    if (token) reconnectTimer = setTimeout(connect, 3000);
  };
}

function setStatus(text, cls) {
  const el = $("status");
  el.textContent = text;
  el.className = "pill " + cls;
}

// ---------- 渲染 ----------
function renderHistory() {
  const list = $("history");
  list.replaceChildren();
  if (!history.length) {
    const li = document.createElement("li");
    li.className = "muted";
    li.textContent = "暂无记录";
    list.append(li);
    return;
  }
  for (const item of history) {
    const li = document.createElement("li");
    const body = document.createElement("div");
    body.className = "item-body";
    const text = document.createElement("div");
    text.className = "item-text";
    text.textContent = item.text;
    const meta = document.createElement("div");
    meta.className = "item-meta";
    meta.textContent = `${item.sender} · ${formatTime(item.updated_at)}`;
    body.append(text, meta);

    const btn = document.createElement("button");
    btn.className = "copy";
    btn.textContent = "复制";
    btn.onclick = () => copyText(item.text);
    li.append(body, btn);
    list.append(li);
  }
}

function renderDevices() {
  const others = devices.filter((d) => d.id !== deviceId);
  setStatus(`${devices.length} 台在线`, "online");
  $("devices").hidden = others.length === 0;
  const list = $("device-list");
  list.replaceChildren(
    ...devices.map((d) => {
      const li = document.createElement("li");
      li.textContent = `${d.id === deviceId ? "● " : "○ "}${d.name}（${d.type}）`;
      return li;
    })
  );
}

function formatTime(ts) {
  const d = new Date(ts * 1000);
  const sameDay = d.toDateString() === new Date().toDateString();
  return sameDay
    ? d.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })
    : d.toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

// ---------- 操作 ----------
function send() {
  const text = $("input").value;
  if (!text.trim()) return;
  if (new Blob([text]).size > MAX_BYTES) {
    toast("内容超过 64KB 上限");
    return;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    toast("未连接，请稍后再试");
    return;
  }
  ws.send(JSON.stringify({ type: "clipboard:send", text }));
  history = [
    { text, sender: deviceName, updated_at: Date.now() / 1000 },
    ...history.filter((h) => h.text !== text),
  ].slice(0, 50);
  renderHistory();
  $("input").value = "";
  updateSizeHint();
  toast("已发送");
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // HTTP 页面下 navigator.clipboard 不可用，退回旧方法
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.append(ta);
    ta.select();
    document.execCommand("copy");
    ta.remove();
  }
  toast("已复制");
}

async function clearHistory() {
  if (!confirm("确定清空所有剪贴板记录？")) return;
  const res = await fetch("/api/clipboard", {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) toast("清空失败");
}

function updateSizeHint() {
  const size = new Blob([$("input").value]).size;
  $("size-hint").textContent = size ? `${(size / 1024).toFixed(1)} / 64 KB` : "";
  $("send").disabled = size > MAX_BYTES;
}

let toastTimer;
function toast(text) {
  const el = $("toast");
  el.textContent = text;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 1800);
}

// ---------- 文件（P2P 直传）----------
function formatSize(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

function renderTargets() {
  const select = $("target");
  const prev = select.value;
  const others = devices.filter((d) => d.id !== deviceId);
  select.replaceChildren(
    ...others.map((d) => {
      const opt = document.createElement("option");
      opt.value = d.id;
      opt.textContent = `${d.name}（${d.type}）`;
      return opt;
    })
  );
  if (!others.length) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "没有其他在线设备";
    select.append(opt);
  }
  if (others.some((d) => d.id === prev)) select.value = prev;
}

function sendFilesTo(fileList) {
  const target = devices.find((d) => d.id === $("target").value && d.id !== deviceId);
  if (!target) {
    toast("没有可发送的在线设备");
    return;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    toast("未连接到服务器");
    return;
  }
  if (!P2P.sendFiles(target.id, target.name, fileList)) toast("没有可发送的文件（空文件会被跳过）");
}

const STATUS_TEXT = {
  waiting: "等待对方响应…",
  connecting: "正在建立直连…",
  transferring: "传输中",
  finishing: "等待对方确认…",
  done: "完成",
};

function renderTransfers() {
  const list = $("transfers");
  const items = [...P2P.transfers.values()].reverse();
  list.replaceChildren();
  if (!items.length) {
    const li = document.createElement("li");
    li.className = "muted";
    li.textContent = "暂无记录";
    list.append(li);
    return;
  }
  for (const t of items) {
    const li = document.createElement("li");
    const body = document.createElement("div");
    body.className = "item-body";
    const name = document.createElement("div");
    name.className = "file-name";
    const names = t.files.map((f) => f.name);
    name.textContent = `${t.dir === "send" ? "↑ 发给" : "↓ 来自"}【${t.peerName}】 ${names[0] || ""}${names.length > 1 ? ` 等 ${names.length} 个` : ""}`;
    const meta = document.createElement("div");
    meta.className = "item-meta";
    const secs = Math.max(0.001, ((t.finishedAt || Date.now()) - t.startedAt) / 1000);
    const parts = [`${formatSize(t.done)} / ${formatSize(t.total)}`];
    if (t.status === "transferring") parts.push(`${formatSize(t.done / secs)}/s`);
    if (t.conn) parts.push(t.conn);
    const status = document.createElement("span");
    status.textContent = t.status === "failed" ? `失败：${t.error}` : STATUS_TEXT[t.status] || t.status;
    status.className = `status-${t.status}`;
    meta.append(parts.join(" · ") + " · ", status);
    body.append(name, meta);
    li.append(body);

    const active = !["done", "failed"].includes(t.status);
    if (active) {
      const cancel = document.createElement("button");
      cancel.className = "icon-btn";
      cancel.textContent = "取消";
      cancel.onclick = () => P2P.cancel(t.id);
      li.append(cancel);
    } else if (t.dir === "recv" && t.saved.length) {
      const save = document.createElement("button");
      save.className = "copy";
      save.textContent = "再次保存";
      save.onclick = () => t.saved.forEach((f) => saveBlob(f.name, f.blob));
      li.append(save);
    }
    if (active && t.total) {
      const bar = document.createElement("progress");
      bar.max = 1;
      bar.value = t.done / t.total;
      li.append(bar);
    }
    list.append(li);
  }
}

function saveBlob(name, blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

P2P.configure({
  signal: (to, data) => {
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "rtc:signal", to, data }));
  },
  update: (t) => {
    renderTransfers();
    if (t.status === "failed" && t.error) toast(`传输失败：${t.error}`);
    if (t.status === "done") toast(t.dir === "send" ? `已发送给【${t.peerName}】` : `已收到【${t.peerName}】的文件`);
  },
  received: (t, name, blob) => {
    showTab("files");
    saveBlob(name, blob);
  },
});

function showTab(name) {
  for (const btn of document.querySelectorAll(".tab")) {
    btn.classList.toggle("active", btn.dataset.tab === name);
  }
  $("tab-clip").hidden = name !== "clip";
  $("tab-files").hidden = name !== "files";
  $("tab-ai").hidden = name !== "ai";
  document.body.classList.toggle("wide", name === "ai");
  storage.set("nelson_tab", name);
}

// ---------- 登录 ----------
function showLogin(error = "") {
  $("app").hidden = true;
  $("login").hidden = false;
  $("login-error").textContent = error;
  setStatus("未登录", "offline");
}

function showApp() {
  $("login").hidden = true;
  $("app").hidden = false;
}

function logout(error = "") {
  token = null;
  storage.del(TOKEN_KEY);
  clearTimeout(reconnectTimer);
  if (ws) {
    ws.onclose = null;
    ws.close();
  }
  showLogin(error);
}

$("login-form").onsubmit = (e) => {
  e.preventDefault();
  const t = $("token-input").value.trim();
  if (!t) return;
  token = t;
  storage.set(TOKEN_KEY, t);
  $("login-error").textContent = "";
  connect();
};
$("send").onclick = send;
$("input").oninput = updateSizeHint;
$("input").onkeydown = (e) => {
  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) send();
};
$("clear").onclick = clearHistory;
$("logout").onclick = () => logout();
$("status").onclick = () => {
  showTab("clip");
  $("devices").scrollIntoView({ behavior: "smooth" });
};
for (const btn of document.querySelectorAll(".tab")) {
  btn.onclick = () => showTab(btn.dataset.tab);
}
$("file-input").onchange = (e) => {
  sendFilesTo(e.target.files);
  e.target.value = "";
};
const dz = $("dropzone");
dz.ondragover = (e) => {
  e.preventDefault();
  dz.classList.add("over");
};
dz.ondragleave = () => dz.classList.remove("over");
dz.ondrop = (e) => {
  e.preventDefault();
  dz.classList.remove("over");
  sendFilesTo(e.dataTransfer.files);
};
AI.init((payload) => {
  if (ws?.readyState !== WebSocket.OPEN) return false;
  ws.send(JSON.stringify(payload));
  return true;
});
showTab(storage.get("nelson_tab") || "clip");
renderTargets();
renderTransfers();

if (token) connect();
else showLogin();
