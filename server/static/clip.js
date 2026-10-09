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
let deviceId = storage.get(DEVICE_KEY);
if (!deviceId) {
  deviceId = "web_" + Math.random().toString(36).slice(2, 10);
  storage.set(DEVICE_KEY, deviceId);
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

  ws.onopen = () => showApp();
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
    } else if (msg.type === "clipboard:error") {
      toast(msg.error);
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
$("status").onclick = () => $("devices").scrollIntoView({ behavior: "smooth" });

if (token) connect();
else showLogin();
