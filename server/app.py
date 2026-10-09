import os
import json
import time
import uuid
import shutil
from pathlib import Path
from typing import Dict, List, Optional

from fastapi import (
    FastAPI,
    WebSocket,
    WebSocketDisconnect,
    UploadFile,
    File,
    Form,
    HTTPException,
    Depends,
    Query,
    Request,
)
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from .config import (
    BASE_DIR,
    UPLOAD_DIR,
    AUTH_TOKEN,
    HOST,
    PORT,
    MAX_CLIPBOARD_HISTORY,
)

app = FastAPI(title="NelsonBox Hub", version="1.0.0")

# 挂载静态文件与模板
STATIC_DIR = BASE_DIR / "static"
STATIC_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

# 状态存储（内存中，轻量快速）
clipboard_history: List[dict] = []
current_clipboard = {
    "text": "欢迎使用 NelsonBox 多端中枢！",
    "updated_at": time.time(),
    "sender": "System",
}


class ConnectionManager:
    def __init__(self):
        # device_id -> {"ws": WebSocket, "name": str, "type": str, "joined_at": float}
        self.active_connections: Dict[str, dict] = {}

    async def connect(self, ws: WebSocket, device_id: str, name: str, dev_type: str):
        await ws.accept()
        self.active_connections[device_id] = {
            "ws": ws,
            "name": name,
            "type": dev_type,
            "joined_at": time.time(),
        }
        await self.broadcast_device_list()

    def disconnect(self, device_id: str):
        if device_id in self.active_connections:
            del self.active_connections[device_id]

    async def broadcast_device_list(self):
        devices = [
            {
                "id": did,
                "name": info["name"],
                "type": info["type"],
                "joined_at": info["joined_at"],
            }
            for did, info in self.active_connections.items()
        ]
        msg = json.dumps({"type": "devices:update", "devices": devices})
        await self.broadcast(msg)

    async def broadcast(self, message: str, exclude_device_id: Optional[str] = None):
        dead_devices = []
        for did, info in self.active_connections.items():
            if did == exclude_device_id:
                continue
            try:
                await info["ws"].send_text(message)
            except Exception:
                dead_devices.append(did)

        for did in dead_devices:
            self.disconnect(did)

    async def send_to_device(self, target_id: str, message: str) -> bool:
        if target_id in self.active_connections:
            try:
                await self.active_connections[target_id]["ws"].send_text(message)
                return True
            except Exception:
                self.disconnect(target_id)
        return False


manager = ConnectionManager()


def verify_token(token: Optional[str] = Query(None)):
    if token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid auth token")
    return token


# --- Web 页面 ---
@app.get("/", response_class=HTMLResponse)
async def serve_index(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {"request": request, "auth_token": AUTH_TOKEN},
    )


# --- REST 接口 ---
@app.get("/api/clipboard")
async def get_clipboard():
    return {
        "current": current_clipboard,
        "history": clipboard_history[:MAX_CLIPBOARD_HISTORY],
    }


@app.post("/api/clipboard")
async def post_clipboard(data: dict):
    global current_clipboard
    text = data.get("text", "")
    sender = data.get("sender", "Web")
    sender_id = data.get("sender_id", "")

    if not text:
        raise HTTPException(status_code=400, detail="Text cannot be empty")

    item = {
        "id": str(uuid.uuid4())[:8],
        "text": text,
        "sender": sender,
        "sender_id": sender_id,
        "updated_at": time.time(),
    }
    current_clipboard = item
    clipboard_history.insert(0, item)
    if len(clipboard_history) > MAX_CLIPBOARD_HISTORY:
        clipboard_history.pop()

    # 广播给除发送端外的所有设备
    msg = json.dumps({"type": "clipboard:sync", "data": item})
    await manager.broadcast(msg, exclude_device_id=sender_id)

    return {"status": "ok", "item": item}


@app.post("/api/upload")
async def upload_file(
    file: UploadFile = File(...),
    sender: str = Form("Web"),
    sender_id: str = Form(""),
):
    safe_filename = f"{int(time.time())}_{file.filename}"
    file_path = UPLOAD_DIR / safe_filename

    with open(file_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    file_size = os.path.getsize(file_path)
    file_info = {
        "id": safe_filename,
        "name": file.filename,
        "size": file_size,
        "sender": sender,
        "sender_id": sender_id,
        "uploaded_at": time.time(),
        "url": f"/api/download/{safe_filename}",
    }

    # 广播新文件提醒
    msg = json.dumps({"type": "file:new", "data": file_info})
    await manager.broadcast(msg, exclude_device_id=sender_id)

    return {"status": "ok", "file": file_info}


@app.get("/api/files")
async def list_files():
    files = []
    for p in sorted(UPLOAD_DIR.glob("*"), key=os.path.getmtime, reverse=True):
        if p.is_file():
            # 剥离前缀时间戳展示原名
            raw_name = p.name
            orig_name = raw_name.split("_", 1)[1] if "_" in raw_name else raw_name
            files.append(
                {
                    "id": raw_name,
                    "name": orig_name,
                    "size": p.stat().st_size,
                    "uploaded_at": p.stat().st_mtime,
                    "url": f"/api/download/{raw_name}",
                }
            )
    return {"files": files[:50]}


@app.get("/api/download/{filename}")
async def download_file(filename: str):
    file_path = UPLOAD_DIR / filename
    if not file_path.exists() or not file_path.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    orig_name = filename.split("_", 1)[1] if "_" in filename else filename
    return FileResponse(
        path=file_path,
        filename=orig_name,
        media_type="application/octet-stream",
    )


@app.get("/api/devices")
async def list_devices():
    return {
        "devices": [
            {
                "id": did,
                "name": info["name"],
                "type": info["type"],
                "joined_at": info["joined_at"],
            }
            for did, info in manager.active_connections.items()
        ]
    }


# --- WebSocket 实时总线 ---
@app.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    device_id: str = Query(...),
    name: str = Query("Unknown"),
    device_type: str = Query("web"),  # web | mac | windows | linux | android
    token: str = Query(""),
):
    if token != AUTH_TOKEN:
        await websocket.close(code=4001, reason="Unauthorized")
        return

    await manager.connect(websocket, device_id, name, device_type)

    try:
        # 连接成功后先推当前剪贴板
        await websocket.send_text(
            json.dumps({"type": "clipboard:sync", "data": current_clipboard})
        )

        while True:
            raw_data = await websocket.receive_text()
            data = json.loads(raw_data)
            action = data.get("type")

            if action == "clipboard:send":
                text = data.get("text", "")
                if text:
                    global current_clipboard
                    item = {
                        "id": str(uuid.uuid4())[:8],
                        "text": text,
                        "sender": name,
                        "sender_id": device_id,
                        "updated_at": time.time(),
                    }
                    current_clipboard = item
                    clipboard_history.insert(0, item)
                    if len(clipboard_history) > MAX_CLIPBOARD_HISTORY:
                        clipboard_history.pop()

                    # 广播给其他设备
                    sync_msg = json.dumps({"type": "clipboard:sync", "data": item})
                    await manager.broadcast(sync_msg, exclude_device_id=device_id)

            elif action == "ai:chat_request":
                # 手机端向指定设备（如 Mac / 小主机）发起 AI 问答
                target_device_id = data.get("target_device_id")
                req_id = data.get("request_id") or str(uuid.uuid4())[:8]
                payload = {
                    "type": "ai:execute",
                    "request_id": req_id,
                    "requester_id": device_id,
                    "prompt": data.get("prompt", ""),
                    "model": data.get("model", "auto"),
                }
                # 如果没有指定 target_device_id，自动找一个在线的 mac 或 server
                if not target_device_id:
                    for did, dinfo in manager.active_connections.items():
                        if dinfo["type"] in ("mac", "server", "windows", "linux"):
                            target_device_id = did
                            break

                if target_device_id:
                    sent = await manager.send_to_device(
                        target_device_id, json.dumps(payload)
                    )
                    if not sent:
                        await websocket.send_text(
                            json.dumps(
                                {
                                    "type": "ai:error",
                                    "request_id": req_id,
                                    "error": "目标设备已离线",
                                }
                            )
                        )
                else:
                    await websocket.send_text(
                        json.dumps(
                            {
                                "type": "ai:error",
                                "request_id": req_id,
                                "error": "当前没有在线的算力节点 (Mac 或小主机未连接)",
                            }
                        )
                    )

            elif action in ("ai:stream_chunk", "ai:done", "ai:error"):
                # 算力节点（Mac / 小主机）流式回传数据给最初的发起者手机
                requester_id = data.get("requester_id")
                if requester_id:
                    await manager.send_to_device(requester_id, raw_data)

    except WebSocketDisconnect:
        manager.disconnect(device_id)
        await manager.broadcast_device_list()
    except Exception:
        manager.disconnect(device_id)
        await manager.broadcast_device_list()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("server.app:app", host=HOST, port=PORT, reload=True)
