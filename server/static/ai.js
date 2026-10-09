// AI 聊天：通过服务器和 Mac 上的 Claude Code / Codex / Gemini 对话，协议见 docs/ai-chat-protocol.md
const AI = (() => {
  const PASS_KEY = "nelson_ai_passcode";
  let hosts = [];
  let convs = [];
  let conv = null; // 当前打开的完整对话
  let pendingReq = null; // 新建对话时等待服务器回 ai:conv
  let sendFn = () => false;

  const $ = (id) => document.getElementById(id);

  function init(send) {
    sendFn = send;
    $("ai-send").onclick = submit;
    $("ai-input").onkeydown = (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        submit();
      }
    };
    $("ai-new").onclick = newChat;
    $("ai-mode").onchange = updateModeUI;
    $("ai-passcode").value = storage.get(PASS_KEY) || "";
    $("ai-passcode").oninput = () => storage.set(PASS_KEY, $("ai-passcode").value);
    $("ai-toggle-list").onclick = () => $("ai-layout").classList.toggle("show-list");
    renderAll();
  }

  // 连上服务器 / 重连时：刷新列表，重新打开当前对话（手机断网期间 Mac 可能已经回复完了）
  function onConnected() {
    sendFn({ type: "ai:list" });
    if (conv) sendFn({ type: "ai:open", conv_id: conv.id });
  }

  function handle(msg) {
    switch (msg.type) {
      case "ai:hosts":
        hosts = msg.hosts || [];
        renderOptions();
        renderHeader();
        break;
      case "ai:convs":
        convs = msg.convs || [];
        renderList();
        break;
      case "ai:conv":
        if (msg.client_req && msg.client_req === pendingReq) pendingReq = null;
        else if (!conv || conv.id !== msg.conv.id) return; // 别的设备的对话更新，列表会单独刷新
        conv = msg.conv;
        renderAll();
        break;
      case "ai:delta": {
        const m = conv && conv.id === msg.conv_id && conv.messages.find((x) => x.id === msg.msg_id);
        if (!m) return;
        m.text += msg.text;
        m.status = "running";
        renderMessage(m, true);
        break;
      }
      case "ai:msg": {
        if (!conv || conv.id !== msg.conv_id) return;
        const i = conv.messages.findIndex((x) => x.id === msg.message.id);
        if (i >= 0) conv.messages[i] = msg.message;
        else conv.messages.push(msg.message);
        renderMessage(msg.message, true);
        renderInputState();
        break;
      }
      case "ai:error":
        toast(msg.error);
        break;
    }
  }

  // ---------- 操作 ----------
  function host() {
    return hosts[0];
  }

  function busy() {
    const last = conv?.messages[conv.messages.length - 1];
    return !!last && last.role === "assistant" && ["pending", "running"].includes(last.status);
  }

  function submit() {
    const text = $("ai-input").value.trim();
    if (!text || busy()) return;
    if (!host()) return toast("Mac 不在线：请确认 Mac 上的 NelsonBox 已打开");
    const mode = $("ai-mode").value;
    const passcode = $("ai-passcode").value.trim();
    if (mode === "edit" && !passcode) return toast("可修改模式需要输入编辑口令");
    const req = Math.random().toString(36).slice(2);
    const payload = { type: "ai:send", text, mode, client_req: req };
    if ($("ai-model").value) payload.model = $("ai-model").value;
    if ($("ai-effort").value && !$("ai-effort").hidden) payload.effort = $("ai-effort").value;
    if (mode === "edit") payload.passcode = passcode;
    if (conv) payload.conv_id = conv.id;
    else {
      payload.engine = $("ai-engine").value;
      payload.project = $("ai-project").value;
      if (!payload.engine) return toast("Mac 上没有可用的 AI 工具");
    }
    if (!sendFn(payload)) return toast("未连接到服务器");
    pendingReq = conv ? null : req;
    $("ai-input").value = "";
  }

  function newChat() {
    conv = null;
    $("ai-layout").classList.remove("show-list");
    renderAll();
    $("ai-input").focus();
  }

  function openConv(id) {
    sendFn({ type: "ai:open", conv_id: id });
    conv = { id, messages: [], title: "", engine: "", project: "" };
    $("ai-layout").classList.remove("show-list");
    renderAll();
  }

  function deleteConv(c) {
    if (!confirm(`删除对话“${c.title}”？`)) return;
    sendFn({ type: "ai:delete", conv_id: c.id });
    if (conv?.id === c.id) newChat();
  }

  // ---------- 渲染 ----------
  function renderAll() {
    renderOptions();
    renderHeader();
    renderList();
    renderMessages();
    renderInputState();
    updateModeUI();
  }

  function renderOptions() {
    const h = host();
    const engineSel = $("ai-engine");
    const projSel = $("ai-project");
    const prevE = engineSel.value || storage.get("nelson_ai_engine");
    const prevP = projSel.value;
    engineSel.replaceChildren(
      ...(h?.engines || []).filter((e) => e.available).map((e) => new Option(e.name, e.id))
    );
    if ([...engineSel.options].some((o) => o.value === prevE)) engineSel.value = prevE;
    engineSel.onchange = () => {
      storage.set("nelson_ai_engine", engineSel.value);
      renderModels();
    };
    projSel.replaceChildren(new Option("不选项目", ""), ...(h?.projects || []).map((p) => new Option(p.name, p.name)));
    if ([...projSel.options].some((o) => o.value === prevP)) projSel.value = prevP;
    // 已有对话时引擎和项目固定
    engineSel.disabled = projSel.disabled = !!conv;
    if (conv?.engine) {
      if (![...engineSel.options].some((o) => o.value === conv.engine)) engineSel.append(new Option(conv.engine, conv.engine));
      engineSel.value = conv.engine;
      if (![...projSel.options].some((o) => o.value === conv.project)) projSel.append(new Option(conv.project, conv.project));
      projSel.value = conv.project || "";
    }
    renderModels();
    const editOpt = $("ai-mode").querySelector('option[value="edit"]');
    editOpt.disabled = !h?.edit_enabled;
    if (!h?.edit_enabled) $("ai-mode").value = "ask";
  }

  function currentEngine() {
    const id = conv?.engine || $("ai-engine").value;
    return host()?.engines.find((e) => e.id === id);
  }

  function modelName(engineId, modelId) {
    const e = host()?.engines.find((x) => x.id === engineId);
    return e?.models?.find((m) => m.id === modelId)?.name || modelId;
  }

  // 模型和推理强度：每条消息都可以换；按工具记住上次的选择
  function renderModels() {
    const e = currentEngine();
    const modelSel = $("ai-model");
    const key = `nelson_ai_model_${e?.id}`;
    const prev = modelSel.dataset.engine === e?.id ? modelSel.value : storage.get(key) || "";
    const defName = e?.default_model ? `默认（${modelName(e.id, e.default_model)}）` : "默认模型";
    modelSel.replaceChildren(new Option(defName, ""), ...(e?.models || []).map((m) => new Option(m.name, m.id)));
    modelSel.value = [...modelSel.options].some((o) => o.value === prev) ? prev : "";
    modelSel.dataset.engine = e?.id || "";
    modelSel.hidden = !e;
    modelSel.onchange = () => {
      storage.set(key, modelSel.value);
      renderEfforts();
    };
    renderEfforts();
  }

  function renderEfforts() {
    const e = currentEngine();
    const modelId = $("ai-model").value || e?.default_model;
    const efforts = e?.models?.find((m) => m.id === modelId)?.efforts || [];
    const sel = $("ai-effort");
    const key = `nelson_ai_effort_${e?.id}`;
    const prev = sel.value || storage.get(key) || "";
    const def = !$("ai-model").value && e?.default_effort ? `默认强度（${e.default_effort}）` : "默认强度";
    sel.replaceChildren(new Option(def, ""), ...efforts.map((x) => new Option(x, x)));
    sel.value = efforts.includes(prev) ? prev : "";
    sel.hidden = !efforts.length;
    sel.onchange = () => storage.set(key, sel.value);
  }

  function renderHeader() {
    const h = host();
    $("ai-host").textContent = h ? `${h.name} 在线` : "Mac 不在线";
    $("ai-host").className = "pill " + (h ? "online" : "offline");
    $("ai-title").textContent = conv?.title || "新对话";
  }

  function renderList() {
    const list = $("ai-conv-list");
    list.replaceChildren();
    if (!convs.length) {
      const li = document.createElement("li");
      li.className = "muted";
      li.textContent = "暂无对话";
      list.append(li);
    }
    for (const c of convs) {
      const li = document.createElement("li");
      li.className = "ai-conv" + (conv?.id === c.id ? " active" : "");
      const t = document.createElement("div");
      t.className = "ai-conv-title";
      t.textContent = (c.busy ? "● " : "") + c.title;
      const meta = document.createElement("div");
      meta.className = "item-meta";
      meta.textContent = `${engineName(c.engine)}${c.project ? " · " + c.project : ""} · ${formatTime(c.updated_at)}`;
      const del = document.createElement("button");
      del.className = "icon-btn";
      del.textContent = "删除";
      del.onclick = (e) => {
        e.stopPropagation();
        deleteConv(c);
      };
      const body = document.createElement("div");
      body.className = "item-body";
      body.append(t, meta);
      li.append(body, del);
      li.onclick = () => openConv(c.id);
      list.append(li);
    }
  }

  function engineName(id) {
    return { claude: "Claude Code", codex: "Codex", gemini: "Gemini" }[id] || id;
  }

  function renderMessages() {
    const box = $("ai-messages");
    box.replaceChildren();
    if (!conv || !conv.messages.length) {
      const empty = document.createElement("div");
      empty.className = "ai-empty muted";
      empty.textContent = conv ? "加载中…" : "选择 AI 工具和项目，开始提问。回复由你 Mac 上的命令行工具生成。";
      box.append(empty);
      return;
    }
    for (const m of conv.messages) box.append(messageEl(m));
    box.scrollTop = box.scrollHeight;
  }

  function renderMessage(m, scroll) {
    const box = $("ai-messages");
    const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
    const old = box.querySelector(`[data-id="${m.id}"]`);
    const el = messageEl(m);
    if (old) old.replaceWith(el);
    else {
      box.querySelector(".ai-empty")?.remove();
      box.append(el);
    }
    if (scroll && atBottom) box.scrollTop = box.scrollHeight;
  }

  function messageEl(m) {
    const el = document.createElement("div");
    el.className = `ai-msg ${m.role}`;
    el.dataset.id = m.id;
    const bubble = document.createElement("div");
    bubble.className = "ai-bubble";
    if (m.role === "user") {
      bubble.textContent = m.text;
    } else {
      bubble.innerHTML = renderMarkdown(m.text || "");
      for (const pre of bubble.querySelectorAll("pre")) {
        const btn = document.createElement("button");
        btn.className = "ai-copy-code";
        btn.textContent = "复制";
        btn.onclick = () => copyText(pre.querySelector("code").textContent);
        pre.prepend(btn);
      }
    }
    el.append(bubble);

    const meta = document.createElement("div");
    meta.className = "ai-meta";
    if (m.role === "user") {
      meta.textContent = `${m.sender || ""}${m.mode === "edit" ? " · 可修改" : ""}`;
    } else {
      const status = {
        pending: "等待 Mac 接手…",
        running: "生成中…",
        done: "",
        cancelled: "已取消",
        error: `失败：${m.error || ""}`,
      }[m.status];
      const parts = [engineName(m.engine)];
      if (m.model) parts.push(modelName(m.engine, m.model) + (m.effort ? ` · ${m.effort}` : ""));
      if (m.mode_used) parts.push(m.mode_used === "edit" ? "可修改" : "只读");
      if (status) parts.push(status);
      meta.textContent = parts.join(" · ");
      if (m.status === "error") meta.classList.add("status-failed");
      if (["pending", "running"].includes(m.status)) {
        const stop = document.createElement("button");
        stop.className = "icon-btn";
        stop.textContent = "停止";
        stop.onclick = () => sendFn({ type: "ai:cancel", msg_id: m.id });
        meta.append(" ", stop);
      } else if (m.text) {
        const copy = document.createElement("button");
        copy.className = "icon-btn";
        copy.textContent = "复制";
        copy.onclick = () => copyText(m.text);
        meta.append(" ", copy);
      }
    }
    el.append(meta);
    return el;
  }

  function renderInputState() {
    const b = busy();
    $("ai-send").disabled = b;
    $("ai-input").placeholder = b ? "等待回复完成…" : "输入问题，Enter 发送，Shift+Enter 换行";
  }

  function updateModeUI() {
    const edit = $("ai-mode").value === "edit";
    $("ai-passcode").hidden = !edit;
    $("ai-mode-hint").textContent = edit
      ? "可修改：AI 可以在 Mac 上修改项目文件、运行命令"
      : "只读：AI 只能读文件、回答问题";
  }

  // ---------- Markdown（先转义再处理，不会执行任何 HTML）----------
  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  function inline(s) {
    return s
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  }

  function renderMarkdown(src) {
    const out = [];
    const lines = src.split("\n");
    let i = 0;
    let list = null;
    const closeList = () => {
      if (list) out.push(`</${list}>`);
      list = null;
    };
    while (i < lines.length) {
      const line = lines[i];
      const fence = line.match(/^```(\S*)/);
      if (fence) {
        closeList();
        const code = [];
        i++;
        while (i < lines.length && !lines[i].startsWith("```")) code.push(lines[i++]);
        i++;
        out.push(`<pre><code>${escapeHtml(code.join("\n"))}</code></pre>`);
        continue;
      }
      const esc = escapeHtml(line);
      let m;
      if ((m = esc.match(/^(#{1,4})\s+(.*)/))) {
        closeList();
        out.push(`<h${m[1].length + 2}>${inline(m[2])}</h${m[1].length + 2}>`);
      } else if ((m = esc.match(/^\s*[-*]\s+(.*)/))) {
        if (list !== "ul") { closeList(); out.push("<ul>"); list = "ul"; }
        out.push(`<li>${inline(m[1])}</li>`);
      } else if ((m = esc.match(/^\s*\d+[.)]\s+(.*)/))) {
        if (list !== "ol") { closeList(); out.push("<ol>"); list = "ol"; }
        out.push(`<li>${inline(m[1])}</li>`);
      } else if ((m = esc.match(/^&gt;\s?(.*)/))) {
        closeList();
        out.push(`<blockquote>${inline(m[1])}</blockquote>`);
      } else if (!esc.trim()) {
        closeList();
      } else {
        closeList();
        out.push(`<p>${inline(esc)}</p>`);
      }
      i++;
    }
    closeList();
    return out.join("");
  }

  return { init, onConnected, handle, renderMarkdown };
})();
