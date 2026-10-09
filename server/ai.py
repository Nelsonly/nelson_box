"""AI 聊天中介：保存对话、在客户端和 Mac（AI 主机）之间转发消息。

服务器不调用任何 AI，只做三件事：
1. 把客户端（网页 / 手机）的提问转给在线的 AI 主机（Mac 上的 NelsonBox）
2. 把主机流式返回的内容转给所有客户端，并实时保存，手机断线重连后能接着看
3. 保存对话文字（有条数和长度上限，磁盘占用很小）

编辑口令只透传给主机核对，服务器不保存。
"""
import asyncio
import json
import os
import time
import uuid
from typing import Callable, Dict, List, Optional

from .config import DATA_DIR

CHATS_FILE = DATA_DIR / "chats.json"
MAX_CONVERSATIONS = 50
MAX_MESSAGES = 200
MAX_PROMPT_CHARS = 20_000
MAX_REPLY_CHARS = 200_000
HOST_LOST_TIMEOUT = 120  # 主机掉线超过这么久，进行中的回复标记为失败


def now() -> float:
    return time.time()


class ChatStore:
    def __init__(self):
        self.convs: Dict[str, dict] = {}
        self.dirty = False
        try:
            for c in json.loads(CHATS_FILE.read_text("utf-8")):
                self.convs[c["id"]] = c
        except (FileNotFoundError, ValueError):
            pass

    def save(self):
        if not self.dirty:
            return
        tmp = CHATS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(list(self.convs.values()), ensure_ascii=False), "utf-8")
        os.replace(tmp, CHATS_FILE)
        self.dirty = False

    def summaries(self) -> List[dict]:
        out = []
        for c in sorted(self.convs.values(), key=lambda c: c["updated_at"], reverse=True):
            last = c["messages"][-1] if c["messages"] else None
            out.append({
                "id": c["id"],
                "title": c["title"],
                "engine": c["engine"],
                "project": c["project"],
                "updated_at": c["updated_at"],
                "busy": bool(last and last["status"] in ("pending", "running")),
            })
        return out

    def create(self, engine: str, project: str, text: str) -> dict:
        title = " ".join(text.split())[:40] or "新对话"
        c = {
            "id": uuid.uuid4().hex[:12],
            "title": title,
            "engine": engine,
            "project": project,
            "session": None,  # AI 工具自己的会话 ID（由主机返回，原样保存）
            "created_at": now(),
            "updated_at": now(),
            "messages": [],
        }
        self.convs[c["id"]] = c
        # 超出上限时删除最久没动的对话
        for old in sorted(self.convs.values(), key=lambda c: c["updated_at"])[: max(0, len(self.convs) - MAX_CONVERSATIONS)]:
            del self.convs[old["id"]]
        self.dirty = True
        return c

    def add_message(self, conv: dict, **fields) -> dict:
        msg = {"id": uuid.uuid4().hex[:12], "created_at": now(), **fields}
        conv["messages"].append(msg)
        del conv["messages"][: max(0, len(conv["messages"]) - MAX_MESSAGES)]
        conv["updated_at"] = now()
        self.dirty = True
        return msg

    def find_message(self, msg_id: str):
        for c in self.convs.values():
            for m in reversed(c["messages"]):
                if m["id"] == msg_id:
                    return c, m
        return None, None


class AIBroker:
    def __init__(self, send_to: Callable, broadcast: Callable):
        self.store = ChatStore()
        self.send_to = send_to  # async (device_id, msg) -> bool
        self.broadcast = broadcast  # async (msg, exclude=None)
        self.hosts: Dict[str, dict] = {}  # device_id -> 主机能力
        self.host_lost_at: Optional[float] = now()
        # 服务重启后，进行中的回复等主机重连后由主机补发
        for c in self.store.convs.values():
            for m in c["messages"]:
                if m.get("status") in ("pending", "running"):
                    m["host_seen"] = False

    # ---------- 主机 ----------
    def host_info(self) -> List[dict]:
        return [{"id": did, **info} for did, info in self.hosts.items()]

    async def host_online(self, device_id: str, data: dict):
        self.hosts[device_id] = {
            "name": data.get("name", "Mac"),
            "engines": data.get("engines", []),
            "projects": data.get("projects", []),
            "edit_enabled": bool(data.get("edit_enabled")),
        }
        self.host_lost_at = None
        await self.broadcast({"type": "ai:hosts", "hosts": self.host_info()})

    async def host_offline(self, device_id: str):
        if self.hosts.pop(device_id, None) is None:
            return
        if not self.hosts:
            self.host_lost_at = now()
        await self.broadcast({"type": "ai:hosts", "hosts": self.host_info()})

    def pick_host(self) -> Optional[str]:
        return next(iter(self.hosts), None)

    # ---------- 客户端请求 ----------
    async def handle_client(self, device_id: str, device_name: str, data: dict, reply: Callable):
        t = data.get("type")
        if t == "ai:list":
            await reply({"type": "ai:convs", "convs": self.store.summaries()})
            await reply({"type": "ai:hosts", "hosts": self.host_info()})
        elif t == "ai:open":
            c = self.store.convs.get(data.get("conv_id"))
            await reply({"type": "ai:conv", "conv": c} if c else {"type": "ai:error", "error": "对话不存在"})
        elif t == "ai:send":
            await self.send(device_id, device_name, data, reply)
        elif t == "ai:cancel":
            c, m = self.store.find_message(data.get("msg_id", ""))
            host = self.pick_host()
            if m and host:
                await self.send_to(host, {"type": "ai:cancel", "msg_id": m["id"]})
        elif t == "ai:delete":
            c = self.store.convs.pop(data.get("conv_id"), None)
            if c:
                self.store.dirty = True
                await self.broadcast({"type": "ai:convs", "convs": self.store.summaries()})

    async def send(self, device_id: str, device_name: str, data: dict, reply: Callable):
        text = data.get("text")
        if not isinstance(text, str) or not text.strip():
            return
        if len(text) > MAX_PROMPT_CHARS:
            return await reply({"type": "ai:error", "error": f"内容太长（上限 {MAX_PROMPT_CHARS} 字）"})
        host = self.pick_host()

        conv = self.store.convs.get(data.get("conv_id") or "")
        if conv is None:
            conv = self.store.create(str(data.get("engine", "")), str(data.get("project", "")), text)
        last = conv["messages"][-1] if conv["messages"] else None
        if last and last["status"] in ("pending", "running"):
            return await reply({"type": "ai:error", "error": "上一条回复还没结束"})

        mode = "edit" if data.get("mode") == "edit" else "ask"
        model = str(data.get("model") or "")[:100]
        effort = str(data.get("effort") or "")[:20]
        self.store.add_message(conv, role="user", text=text, sender=device_name, mode=mode, status="done")
        answer = self.store.add_message(conv, role="assistant", text="", status="pending", engine=conv["engine"],
                                        model=model, effort=effort)
        if not host:
            answer.update(status="error", error="Mac 不在线（NelsonBox 没有打开或没联网）")
        self.store.save()

        await reply({"type": "ai:conv", "conv": conv, "client_req": data.get("client_req")})
        await self.broadcast({"type": "ai:convs", "convs": self.store.summaries()})
        await self.broadcast({"type": "ai:conv", "conv": conv}, exclude=device_id)
        if not host:
            return

        answer["host_seen"] = True
        await self.send_to(host, {
            "type": "ai:run",
            "conv_id": conv["id"],
            "msg_id": answer["id"],
            "engine": conv["engine"],
            "project": conv["project"],
            "session": conv["session"],
            "text": text,
            "mode": mode,
            "model": model,
            "effort": effort,
            "passcode": data.get("passcode") or "",  # 只转给主机核对，不保存
            "from_name": device_name,
            "from_type": data.get("device_type", ""),
        })

    # ---------- 主机消息 ----------
    async def handle_host(self, device_id: str, data: dict):
        t = data.get("type")
        if t == "ai:host":
            return await self.host_online(device_id, data)
        if device_id not in self.hosts:
            return
        conv, msg = self.store.find_message(data.get("msg_id", ""))
        if not msg:
            return
        msg["host_seen"] = True
        if t == "ai:delta":
            delta = data.get("text", "")
            if len(msg["text"]) < MAX_REPLY_CHARS:
                msg["text"] += delta
                msg["status"] = "running"
                self.store.dirty = True
                await self.broadcast({"type": "ai:delta", "conv_id": conv["id"], "msg_id": msg["id"], "text": delta},
                                     exclude=device_id)
        elif t == "ai:snapshot":
            # 主机重连后补发完整内容
            msg["text"] = str(data.get("text", ""))[:MAX_REPLY_CHARS]
            msg["status"] = "running"
            self.store.dirty = True
            await self.broadcast({"type": "ai:msg", "conv_id": conv["id"], "message": msg}, exclude=device_id)
        elif t == "ai:done":
            if data.get("text") is not None:
                msg["text"] = str(data["text"])[:MAX_REPLY_CHARS]
            msg["status"] = data.get("status", "done")
            if data.get("error"):
                msg["error"] = str(data["error"])[:2000]
            if data.get("mode_used"):
                msg["mode_used"] = data["mode_used"]
            for k in ("model", "effort"):
                if data.get(k) is not None:
                    msg[k] = str(data[k])[:100]
            if data.get("session"):
                conv["session"] = data["session"]
            conv["updated_at"] = now()
            self.store.dirty = True
            self.store.save()
            await self.broadcast({"type": "ai:msg", "conv_id": conv["id"], "message": msg}, exclude=device_id)
            await self.broadcast({"type": "ai:convs", "convs": self.store.summaries()})

    # ---------- 后台维护 ----------
    async def maintenance_loop(self):
        while True:
            await asyncio.sleep(5)
            if self.host_lost_at and now() - self.host_lost_at > HOST_LOST_TIMEOUT:
                for c in self.store.convs.values():
                    for m in c["messages"]:
                        if m.get("status") in ("pending", "running"):
                            m.update(status="error", error="Mac 断开连接，回复中断")
                            self.store.dirty = True
                            await self.broadcast({"type": "ai:msg", "conv_id": c["id"], "message": m})
            self.store.save()
