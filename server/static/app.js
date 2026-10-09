// --- 全局状态 ---
let socket = null;
let currentDeviceId = localStorage.getItem("nelson_device_id");
if (!currentDeviceId) {
  currentDeviceId = "web_" + Math.random().toString(36).substring(2, 9);
  localStorage.setItem("nelson_device_id", currentDeviceId);
}

let deviceName = localStorage.getItem("nelson_device_name") || "我的手机/浏览器";
let authToken = localStorage.getItem("nelson_auth_token") || "nelson2026";
let onlineDevices = [];
let currentActiveStreamBubble = null;
let activeStreamContent = "";

// --- 初始化与生命周期 ---
document.addEventListener("DOMContentLoaded", () => {
  // 初始化 Lucide 图标
  if (window.lucide) lucide.createIcons();

  // 恢复输入框设置
  const nameInput = document.getElementById("setting-device-name");
  const tokenInput = document.getElementById("setting-token");
  if (nameInput) nameInput.value = deviceName;
  if (tokenInput && tokenInput.value) {
    if (!localStorage.getItem("nelson_auth_token")) {
      localStorage.setItem("nelson_auth_token", tokenInput.value);
    }
    authToken = localStorage.getItem("nelson_auth_token");
    tokenInput.value = authToken;
  }

  // 建立 WebSocket 连接
  initWebSocket();

  // 初始化加载剪贴板和文件
  fetchClipboardData();
  fetchFileList();

  // 初始化文件拖放
  initDragAndDrop();

  // 输入框自适应高度与快捷键发送
  const aiInput = document.getElementById("ai-input");
  if (aiInput) {
    aiInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        sendAiPrompt();
      }
    });
  }
});

// --- WebSocket 连接管理 ---
function initWebSocket() {
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  const wsUrl = `${protocol}//${window.location.host}/ws?device_id=${encodeURIComponent(currentDeviceId)}&name=${encodeURIComponent(deviceName)}&device_type=web&token=${encodeURIComponent(authToken)}`;

  updateConnStatus(false, "连接中...");

  try {
    socket = new WebSocket(wsUrl);
  } catch (e) {
    console.error("WS 初始化错误:", e);
    setTimeout(initWebSocket, 3000);
    return;
  }

  socket.onopen = () => {
    updateConnStatus(true, "已连接");
  };

  socket.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      handleSocketMessage(msg);
    } catch (e) {
      console.error("解析消息失败:", e);
    }
  };

  socket.onclose = () => {
    updateConnStatus(false, "离线 (重连中)");
    setTimeout(initWebSocket, 2500);
  };

  socket.onerror = (err) => {
    console.warn("WS 异常:", err);
  };
}

function updateConnStatus(connected, text) {
  const dot = document.getElementById("conn-dot");
  const countSpan = document.getElementById("online-count");
  if (dot && countSpan) {
    if (connected) {
      dot.className = "w-2 h-2 rounded-full bg-emerald-400";
      countSpan.textContent = `${onlineDevices.length || 1} 台设备`;
    } else {
      dot.className = "w-2 h-2 rounded-full bg-amber-400 animate-pulse";
      countSpan.textContent = text;
    }
  }
}

// --- 消息分发处理 ---
function handleSocketMessage(msg) {
  switch (msg.type) {
    case "devices:update":
      onlineDevices = msg.devices || [];
      renderDevices(onlineDevices);
      break;

    case "clipboard:sync":
      renderCurrentClipboard(msg.data);
      fetchClipboardData(); // 刷新历史
      break;

    case "file:new":
      fetchFileList();
      break;

    case "ai:stream_chunk":
      handleAiChunk(msg.chunk);
      break;

    case "ai:done":
      handleAiDone();
      break;

    case "ai:error":
      handleAiError(msg.error);
      break;
  }
}

// --- 剪贴板模块 ---
async function fetchClipboardData() {
  try {
    const res = await fetch("/api/clipboard");
    const data = await res.json();
    if (data.current) renderCurrentClipboard(data.current);
    if (data.history) renderClipboardHistory(data.history);
  } catch (e) {
    console.error("获取剪贴板数据失败:", e);
  }
}

function renderCurrentClipboard(item) {
  if (!item) return;
  const textEl = document.getElementById("clip-text");
  const sourceEl = document.getElementById("clip-source");
  const timeEl = document.getElementById("clip-time");

  if (textEl) textEl.textContent = item.text || "";
  if (sourceEl) sourceEl.textContent = `来自 ${item.sender || "未知设备"}`;
  if (timeEl && item.updated_at) {
    const d = new Date(item.updated_at * 1000);
    timeEl.textContent = d.toLocaleTimeString();
  }
}

function renderClipboardHistory(history) {
  const container = document.getElementById("clip-history-list");
  if (!container) return;

  if (!history || history.length === 0) {
    container.innerHTML = '<p class="text-xs text-slate-500 text-center py-2">暂无历史记录</p>';
    return;
  }

  container.innerHTML = history.map((item) => {
    const timeStr = new Date(item.updated_at * 1000).toLocaleTimeString();
    // 转义 HTML
    const escaped = item.text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    return `
      <div class="bg-slate-900/60 hover:bg-slate-900 border border-slate-800/60 rounded-xl p-3 text-xs transition flex flex-col space-y-1.5">
        <div class="flex items-center justify-between text-slate-500 text-[11px]">
          <span>来自 ${item.sender || "未知"}</span>
          <span>${timeStr}</span>
        </div>
        <div class="font-mono text-slate-200 line-clamp-2 select-text">${escaped}</div>
        <div class="flex justify-end pt-1">
          <button onclick="copyText(${JSON.stringify(item.text)})" class="text-blue-400 hover:text-blue-300 flex items-center space-x-1">
            <i data-lucide="copy" class="w-3 h-3"></i>
            <span>复制</span>
          </button>
        </div>
      </div>
    `;
  }).join("");

  if (window.lucide) lucide.createIcons();
}

function copyCurrentClipboard() {
  const textEl = document.getElementById("clip-text");
  if (!textEl) return;
  copyText(textEl.textContent);
}

function copyText(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(showCopyToast);
  } else {
    // 降级使用 textarea
    const ta = document.createElement("textarea");
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
    showCopyToast();
  }
}

function showCopyToast() {
  const toast = document.getElementById("copy-toast");
  if (toast) {
    toast.style.opacity = "1";
    setTimeout(() => { toast.style.opacity = "0"; }, 1500);
  }
}

function broadcastClipboard() {
  const input = document.getElementById("clip-input");
  if (!input || !input.value.trim()) return;

  const text = input.value.trim();
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({
      type: "clipboard:send",
      text: text
    }));
    input.value = "";
    showCopyToast();
  } else {
    // 降级走 REST API
    fetch("/api/clipboard", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text: text,
        sender: deviceName,
        sender_id: currentDeviceId
      })
    }).then(() => {
      input.value = "";
      fetchClipboardData();
    });
  }
}

// --- 文件快传模块 ---
function initDragAndDrop() {
  const dropZone = document.getElementById("drop-zone");
  const fileInput = document.getElementById("file-input");
  if (!dropZone || !fileInput) return;

  dropZone.addEventListener("click", () => fileInput.click());

  ["dragenter", "dragover"].forEach((eventName) => {
    dropZone.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropZone.classList.add("border-blue-500", "bg-blue-600/5");
    });
  });

  ["dragleave", "drop"].forEach((eventName) => {
    dropZone.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropZone.classList.remove("border-blue-500", "bg-blue-600/5");
    });
  });

  dropZone.addEventListener("drop", (e) => {
    if (e.dataTransfer && e.dataTransfer.files) {
      handleFileSelect(e.dataTransfer.files);
    }
  });
}

function handleFileSelect(files) {
  if (!files || files.length === 0) return;
  for (let i = 0; i < files.length; i++) {
    uploadFile(files[i]);
  }
}

async function uploadFile(file) {
  const formData = new FormData();
  formData.append("file", file);
  formData.append("sender", deviceName);
  formData.append("sender_id", currentDeviceId);

  try {
    const res = await fetch("/api/upload", {
      method: "POST",
      body: formData,
    });
    if (res.ok) {
      fetchFileList();
    }
  } catch (e) {
    console.error("上传文件异常:", e);
  }
}

async function fetchFileList() {
  try {
    const res = await fetch("/api/files");
    const data = await res.json();
    renderFileList(data.files || []);
  } catch (e) {
    console.error("拉取文件列表异常:", e);
  }
}

function renderFileList(files) {
  const listEl = document.getElementById("file-list");
  if (!listEl) return;

  if (files.length === 0) {
    listEl.innerHTML = '<p class="text-xs text-slate-500 text-center py-4">暂无文件，拖拽或点击上方开始上传</p>';
    return;
  }

  listEl.innerHTML = files.map((f) => {
    const isImage = /\.(png|jpe?g|gif|webp|svg)$/i.test(f.name);
    const sizeStr = formatBytes(f.size);
    const timeStr = new Date(f.uploaded_at * 1000).toLocaleString();

    return `
      <div class="bg-slate-900 border border-slate-800 rounded-xl p-3 flex items-center justify-between transition hover:border-slate-700/80">
        <div class="flex items-center space-x-3 overflow-hidden">
          <div class="w-10 h-10 rounded-lg bg-slate-800 border border-slate-700/60 flex items-center justify-center shrink-0 overflow-hidden">
            ${isImage ? `<img src="${f.url}" class="w-full h-full object-cover" />` : `<i data-lucide="file" class="w-5 h-5 text-blue-400"></i>`}
          </div>
          <div class="overflow-hidden">
            <div class="text-xs font-medium text-slate-200 truncate select-text" title="${f.name}">${f.name}</div>
            <div class="text-[11px] text-slate-500">${sizeStr} · ${timeStr}</div>
          </div>
        </div>
        <a href="${f.url}" download="${f.name}" class="p-2 rounded-lg bg-slate-800 hover:bg-slate-700 text-blue-400 hover:text-blue-300 transition shrink-0">
          <i data-lucide="download" class="w-4 h-4"></i>
        </a>
      </div>
    `;
  }).join("");

  if (window.lucide) lucide.createIcons();
}

function formatBytes(bytes) {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + " " + sizes[i];
}

// --- 远程 AI 调度模块 ---
function sendAiPrompt() {
  const input = document.getElementById("ai-input");
  if (!input || !input.value.trim()) return;

  const prompt = input.value.trim();
  const targetSelect = document.getElementById("ai-target-select");
  const targetId = targetSelect ? targetSelect.value : "";

  // 1. 渲染用户消息
  appendUserChatMessage(prompt);
  input.value = "";

  // 2. 创建等待中的助手气泡
  createAssistantStreamBubble();

  // 3. 通过 WebSocket 发送任务给中枢
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({
      type: "ai:chat_request",
      prompt: prompt,
      target_device_id: targetId,
      request_id: "req_" + Date.now()
    }));
  } else {
    handleAiError("网络未连接，无法发送指令到算力节点");
  }
}

function appendUserChatMessage(text) {
  const container = document.getElementById("ai-chat-messages");
  if (!container) return;

  const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const el = document.createElement("div");
  el.className = "flex items-start justify-end space-x-2";
  el.innerHTML = `
    <div class="bg-blue-600 rounded-2xl rounded-tr-sm px-3.5 py-2.5 max-w-[85%] text-sm text-white shadow-sm leading-relaxed whitespace-pre-wrap select-text">
      ${escaped}
    </div>
    <div class="w-7 h-7 rounded-full bg-blue-500/20 border border-blue-400/40 flex items-center justify-center shrink-0">
      <i data-lucide="user" class="w-3.5 h-3.5 text-blue-300"></i>
    </div>
  `;
  container.appendChild(el);
  container.scrollTop = container.scrollHeight;
  if (window.lucide) lucide.createIcons();
}

function createAssistantStreamBubble() {
  const container = document.getElementById("ai-chat-messages");
  if (!container) return;

  activeStreamContent = "";
  const el = document.createElement("div");
  el.className = "flex items-start space-x-2.5";
  el.innerHTML = `
    <div class="w-7 h-7 rounded-full bg-indigo-600/20 border border-indigo-500/40 flex items-center justify-center shrink-0">
      <i data-lucide="cpu" class="w-3.5 h-3.5 text-indigo-400"></i>
    </div>
    <div class="ai-bubble bg-slate-900 border border-slate-800 rounded-2xl rounded-tl-sm px-3.5 py-2.5 max-w-[85%] text-sm text-slate-200 shadow-sm leading-relaxed select-text typing-cursor">
      正在连接算力节点...
    </div>
  `;
  container.appendChild(el);
  currentActiveStreamBubble = el.querySelector(".ai-bubble");
  container.scrollTop = container.scrollHeight;
  if (window.lucide) lucide.createIcons();
}

function handleAiChunk(chunk) {
  if (!currentActiveStreamBubble) return;

  if (activeStreamContent === "") {
    currentActiveStreamBubble.textContent = "";
  }
  activeStreamContent += chunk;

  // 使用 marked 渲染 markdown
  if (window.marked) {
    currentActiveStreamBubble.innerHTML = marked.parse(activeStreamContent);
  } else {
    currentActiveStreamBubble.textContent = activeStreamContent;
  }

  const container = document.getElementById("ai-chat-messages");
  if (container) container.scrollTop = container.scrollHeight;
}

function handleAiDone() {
  if (currentActiveStreamBubble) {
    currentActiveStreamBubble.classList.remove("typing-cursor");
    currentActiveStreamBubble = null;
    activeStreamContent = "";
  }
}

function handleAiError(err) {
  if (currentActiveStreamBubble) {
    currentActiveStreamBubble.classList.remove("typing-cursor");
    currentActiveStreamBubble.innerHTML = `<span class="text-rose-400">⚠️ ${err}</span>`;
    currentActiveStreamBubble = null;
    activeStreamContent = "";
  }
}

// --- 设备列表与模态框 ---
function renderDevices(devices) {
  const countSpan = document.getElementById("online-count");
  if (countSpan && socket && socket.readyState === WebSocket.OPEN) {
    countSpan.textContent = `${devices.length} 台设备在线`;
  }

  // 更新目标算力设备选择器
  const select = document.getElementById("ai-target-select");
  if (select) {
    const currentVal = select.value;
    select.innerHTML = '<option value="">自动寻找在线算力机 (Mac/小主机)</option>';
    devices.forEach((d) => {
      const isCompute = ["mac", "windows", "linux", "server"].includes(d.type);
      const isSelf = d.id === currentDeviceId;
      const opt = document.createElement("option");
      opt.value = d.id;
      opt.textContent = `${d.name} (${d.type})${isCompute ? " ⚡算力节点" : ""}${isSelf ? " (本机)" : ""}`;
      select.appendChild(opt);
    });
    select.value = currentVal;
  }

  // 更新模态框列表
  const modalList = document.getElementById("modal-device-list");
  if (modalList) {
    if (devices.length === 0) {
      modalList.innerHTML = '<p class="text-xs text-slate-500 py-2 text-center">暂无其他设备在线</p>';
    } else {
      modalList.innerHTML = devices.map((d) => `
        <div class="flex items-center justify-between p-2 rounded-xl bg-slate-950/60 border border-slate-800/60">
          <div class="flex items-center space-x-2">
            <span class="w-2 h-2 rounded-full bg-emerald-400"></span>
            <div>
              <div class="text-xs font-medium text-slate-200">${d.name}</div>
              <div class="text-[10px] text-slate-500 uppercase">${d.type} · ${d.id.substring(0, 8)}</div>
            </div>
          </div>
          ${d.id === currentDeviceId ? '<span class="text-[10px] text-blue-400 bg-blue-500/10 px-2 py-0.5 rounded">当前设备</span>' : ''}
        </div>
      `).join("");
    }
  }
}

function toggleDeviceModal() {
  const modal = document.getElementById("device-modal");
  if (modal) modal.classList.toggle("hidden");
}

// --- 选项卡切换 ---
function switchTab(tabName) {
  document.querySelectorAll(".tab-content").forEach((el) => el.classList.add("hidden"));
  document.querySelectorAll(".nav-tab").forEach((btn) => btn.classList.remove("active", "text-blue-400"));

  const targetTab = document.getElementById(`tab-${tabName}`);
  const targetBtn = document.getElementById(`nav-btn-${tabName}`);

  if (targetTab) targetTab.classList.remove("hidden");
  if (targetBtn) targetBtn.classList.add("active", "text-blue-400");

  if (tabName === "clipboard") fetchClipboardData();
  if (tabName === "files") fetchFileList();
}

function saveSettings() {
  const nameInput = document.getElementById("setting-device-name");
  const tokenInput = document.getElementById("setting-token");
  if (nameInput) {
    deviceName = nameInput.value.trim() || "我的设备";
    localStorage.setItem("nelson_device_name", deviceName);
  }
  if (tokenInput) {
    authToken = tokenInput.value.trim() || "nelson2026";
    localStorage.setItem("nelson_auth_token", authToken);
  }
  if (socket) socket.close();
  alert("设置已保存，正在重新建立连接！");
}
