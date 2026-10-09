import base64
import hashlib
import hmac
import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Dict, List, Optional

from fastapi import FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .config import (
    AUTH_TOKEN,
    BASE_DIR,
    CLIPBOARD_FILE,
    EXTRA_STUN_SERVERS,
    HOST,
    MAX_CLIPBOARD_BYTES,
    MAX_CLIPBOARD_HISTORY,
    PORT,
    STUN_HOST,
    STUN_PORT,
    TURN_PORT,
    TURN_SECRET,
    TURN_TTL_SECONDS,
)
from .stun import start_stun_server


@asynccontextmanager
async def lifespan(_app: FastAPI):
    transports = await start_stun_server(STUN_PORT) if STUN_PORT else []
    yield
    for t in transports:
        t.close()


app = FastAPI(title="NelsonBox", version="3.0.0", lifespan=lifespan)

STATIC_DIR = BASE_DIR / "static"
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


def check_token(token: Optional[str]) -> bool:
    return bool(token) and hmac.compare_digest(token, AUTH_TOKEN)


# --- 剪贴板存储（内存 + 单个 JSON 文件持久化）---
class ClipboardStore:
    def __init__(self):
        self.history: List[dict] = []
        self._load()

    def _load(self):
        try:
            self.history = json.loads(CLIPBOARD_FILE.read_text("utf-8"))[:MAX_CLIPBOARD_HISTORY]
        except (FileNotFoundError, ValueError):
            self.history = []

    def _save(self):
        # 先写临时文件再替换，避免写一半时断电导致文件损坏
        tmp = CLIPBOARD_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.history, ensure_ascii=False), "utf-8")
        os.replace(tmp, CLIPBOARD_FILE)

    @property
    def current(self) -> Optional[dict]:
        return self.history[0] if self.history else None

    def add(self, text: str, sender: str, sender_id: str) -> Optional[dict]:
        """新增一条记录；与当前内容相同则返回 None（不重复存储）"""
        if len(text.encode("utf-8")) > MAX_CLIPBOARD_BYTES:
            raise ValueError(f"内容超过 {MAX_CLIPBOARD_BYTES // 1024}KB 上限")
        if self.current and self.current["text"] == text:
            return None
        # 历史里已有相同内容则移到最前，不占两份空间
        self.history = [h for h in self.history if h["text"] != text]
        item = {
            "id": uuid.uuid4().hex[:8],
            "text": text,
            "sender": sender,
            "sender_id": sender_id,
            "updated_at": time.time(),
        }
        self.history.insert(0, item)
        del self.history[MAX_CLIPBOARD_HISTORY:]
        self._save()
        return item

    def clear(self):
        self.history = []
        self._save()


store = ClipboardStore()



# --- 连接管理 ---
class ConnectionManager:
    def __init__(self):
        # device_id -> {"ws", "name", "type", "joined_at"}
        self.active: Dict[str, dict] = {}

    async def connect(self, ws: WebSocket, device_id: str, name: str, dev_type: str):
        await ws.accept()
        old = self.active.get(device_id)
        if old:
            # 同一设备重连：关闭旧连接
            try:
                await old["ws"].close()
            except Exception:
                pass
        self.active[device_id] = {"ws": ws, "name": name, "type": dev_type, "joined_at": time.time()}
        await self.broadcast_devices()

    async def disconnect(self, device_id: str, ws: WebSocket):
        # 只移除属于这个 ws 的记录，避免把重连后的新连接删掉
        info = self.active.get(device_id)
        if info and info["ws"] is ws:
            del self.active[device_id]
            await self.broadcast_devices()

    def device_list(self) -> List[dict]:
        return [
            {"id": did, "name": i["name"], "type": i["type"], "joined_at": i["joined_at"]}
            for did, i in self.active.items()
        ]

    async def broadcast_devices(self):
        await self.broadcast({"type": "devices:update", "devices": self.device_list()})

    async def broadcast(self, msg: dict, exclude: Optional[str] = None):
        text = json.dumps(msg, ensure_ascii=False)
        for did, info in list(self.active.items()):
            if did == exclude:
                continue
            try:
                await info["ws"].send_text(text)
            except Exception:
                self.active.pop(did, None)

    async def send_to(self, device_id: str, msg: dict) -> bool:
        info = self.active.get(device_id)
        if not info:
            return False
        try:
            await info["ws"].send_text(json.dumps(msg, ensure_ascii=False))
            return True
        except Exception:
            self.active.pop(device_id, None)
            return False


manager = ConnectionManager()


async def publish(text: str, sender: str, sender_id: str) -> Optional[dict]:
    item = store.add(text, sender, sender_id)
    if item:
        await manager.broadcast({"type": "clipboard:sync", "data": item}, exclude=sender_id)
    return item


def ice_servers(ws: WebSocket, device_id: str) -> List[dict]:
    """主机名默认用客户端连进来时使用的地址。

    配了 TURN_SECRET 时附带 TURN：按 coturn 的 use-auth-secret 规则生成 24 小时有效的临时账号，
    WebRTC 会优先直连，只有直连失败才走服务器转发（数据端到端加密，服务器不存储）。
    """
    host = STUN_HOST or ws.headers.get("host", "").rsplit(":", 1)[0]
    servers = []
    if host and TURN_SECRET:
        username = f"{int(time.time()) + TURN_TTL_SECONDS}:{device_id}"
        credential = base64.b64encode(
            hmac.new(TURN_SECRET.encode(), username.encode(), hashlib.sha1).digest()
        ).decode()
        servers.append({"urls": [f"stun:{host}:{TURN_PORT}"]})
        servers.append({
            "urls": [f"turn:{host}:{TURN_PORT}?transport=udp", f"turn:{host}:{TURN_PORT}?transport=tcp"],
            "username": username,
            "credential": credential,
        })
    elif host and STUN_PORT:
        servers.append({"urls": [f"stun:{host}:{STUN_PORT}"]})
    servers += [{"urls": [u]} for u in EXTRA_STUN_SERVERS]
    return servers


# --- 页面 ---
@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


# --- REST 接口（需在请求头带 Authorization: Bearer <token>）---
def require_auth(authorization: Optional[str]):
    token = (authorization or "").removeprefix("Bearer ").strip()
    if not check_token(token):
        raise HTTPException(status_code=401, detail="令牌无效")


@app.get("/api/clipboard")
async def get_clipboard(authorization: Optional[str] = Header(None)):
    require_auth(authorization)
    return {"current": store.current, "history": store.history}


@app.post("/api/clipboard")
async def post_clipboard(data: dict, authorization: Optional[str] = Header(None)):
    require_auth(authorization)
    text = data.get("text", "")
    if not isinstance(text, str) or not text.strip():
        raise HTTPException(status_code=400, detail="内容不能为空")
    try:
        item = await publish(text, data.get("sender", "API"), data.get("sender_id", ""))
    except ValueError as e:
        raise HTTPException(status_code=413, detail=str(e))
    return {"status": "ok", "item": item or store.current}


@app.delete("/api/clipboard")
async def clear_clipboard(authorization: Optional[str] = Header(None)):
    require_auth(authorization)
    store.clear()
    await manager.broadcast({"type": "clipboard:history", "history": []})
    return {"status": "ok"}


# --- WebSocket：剪贴板同步 + P2P 信令 ---
MAX_SIGNAL_BYTES = 64 * 1024  # SDP / ICE 都很小，限制大小防止被拿来传数据
@app.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    device_id: str = Query(...),
    name: str = Query("Unknown"),
    device_type: str = Query("web"),
    token: str = Query(""),
):
    if not check_token(token):
        # 先 accept 再关闭，客户端才能收到 4001 并提示“令牌错误”，而不是无限重连
        await websocket.accept()
        await websocket.close(code=4001, reason="Unauthorized")
        return

    await manager.connect(websocket, device_id, name, device_type)
    try:
        await websocket.send_text(
            json.dumps({"type": "clipboard:history", "history": store.history}, ensure_ascii=False)
        )
        await websocket.send_text(json.dumps({"type": "rtc:config", "ice_servers": ice_servers(websocket, device_id)}))
        while True:
            raw = await websocket.receive_text()
            try:
                data = json.loads(raw)
            except ValueError:
                continue
            mtype = data.get("type")

            if mtype == "clipboard:send":
                text = data.get("text", "")
                if not isinstance(text, str) or not text.strip():
                    continue
                try:
                    await publish(text, name, device_id)
                except ValueError as e:
                    await websocket.send_text(
                        json.dumps({"type": "clipboard:error", "error": str(e)}, ensure_ascii=False)
                    )

            elif mtype == "rtc:signal":
                # 只转发，不解析、不保存
                target = data.get("to")
                payload = data.get("data")
                if not isinstance(target, str) or not isinstance(payload, dict) or len(raw) > MAX_SIGNAL_BYTES:
                    continue
                sent = await manager.send_to(
                    target, {"type": "rtc:signal", "from": device_id, "from_name": name, "data": payload}
                )
                if not sent:
                    await websocket.send_text(json.dumps({
                        "type": "rtc:error",
                        "to": target,
                        "transfer_id": payload.get("transfer_id"),
                        "error": "对方不在线",
                    }, ensure_ascii=False))
    except WebSocketDisconnect:
        pass
    finally:
        await manager.disconnect(device_id, websocket)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("server.app:app", host=HOST, port=PORT)
