import argparse
import asyncio
import hashlib
import json
import os
import platform
import socket
import subprocess
import sys
import urllib.parse

import websockets

try:
    import pyperclip
except ImportError:
    pyperclip = None

MAX_CLIPBOARD_BYTES = 64 * 1024  # 与服务端上限保持一致
POLL_INTERVAL = 0.8


def text_hash(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def read_clipboard() -> str:
    if pyperclip:
        try:
            return pyperclip.paste() or ""
        except Exception:
            pass
    if sys.platform == "darwin":
        try:
            return subprocess.check_output(["pbpaste"], text=True)
        except Exception:
            pass
    return ""


def write_clipboard(text: str):
    if pyperclip:
        try:
            pyperclip.copy(text)
            return
        except Exception:
            pass
    if sys.platform == "darwin":
        subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=False)


class ClipboardAgent:
    def __init__(self, server_url: str, token: str, device_name: str, device_type: str):
        self.server_url = server_url.rstrip("/")
        self.token = token
        self.device_name = device_name
        self.device_type = device_type
        self.device_id = f"{device_type}_{text_hash(device_name)[:8]}"
        self.last_hash = ""

    def ws_url(self) -> str:
        scheme = "wss" if self.server_url.startswith("https") else "ws"
        host = self.server_url.split("://", 1)[-1]
        query = urllib.parse.urlencode(
            {
                "device_id": self.device_id,
                "name": self.device_name,
                "device_type": self.device_type,
                "token": self.token,
            }
        )
        return f"{scheme}://{host}/ws?{query}"

    async def run(self):
        print(f"📍 本机: {self.device_name} (ID: {self.device_id})")
        print(f"🌐 中枢: {self.server_url}")
        # 启动时记下本机当前剪贴板，避免把旧内容推出去
        self.last_hash = text_hash(await asyncio.to_thread(read_clipboard))

        while True:
            try:
                async with websockets.connect(self.ws_url(), ping_interval=20, ping_timeout=10) as ws:
                    print("✅ 已连接，开始同步剪贴板")
                    tasks = [
                        asyncio.create_task(self.receive_loop(ws)),
                        asyncio.create_task(self.watch_loop(ws)),
                    ]
                    # 任一任务结束（通常是连接断开）就取消另一个，然后重连
                    done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                    for t in pending:
                        t.cancel()
                    for t in done:
                        if t.exception():
                            raise t.exception()
            except websockets.InvalidStatus as e:
                print(f"❌ 连接被拒绝: {e}")
            except (websockets.ConnectionClosed, OSError) as e:
                if isinstance(e, websockets.ConnectionClosed) and e.rcvd and e.rcvd.code == 4001:
                    print("❌ 令牌错误，请检查 --token")
                    return
                print(f"⚠️ 连接断开 ({e})")
            print("3 秒后重连...")
            await asyncio.sleep(3)

    async def watch_loop(self, ws):
        """轮询本机剪贴板，变化时推送到中枢"""
        while True:
            await asyncio.sleep(POLL_INTERVAL)
            text = await asyncio.to_thread(read_clipboard)
            if not text.strip():
                continue
            h = text_hash(text)
            if h == self.last_hash:
                continue
            self.last_hash = h
            if len(text.encode("utf-8")) > MAX_CLIPBOARD_BYTES:
                print(f"⏭️ 内容超过 {MAX_CLIPBOARD_BYTES // 1024}KB，跳过同步")
                continue
            await ws.send(json.dumps({"type": "clipboard:send", "text": text}))
            print(f"📤 已发送: {preview(text)}")

    async def receive_loop(self, ws):
        """接收其他设备同步过来的剪贴板"""
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            mtype = msg.get("type")
            if mtype == "clipboard:sync":
                await self.apply_remote(msg.get("data") or {})
            elif mtype == "clipboard:error":
                print(f"⚠️ 中枢拒绝: {msg.get('error')}")

    async def apply_remote(self, item: dict):
        text = item.get("text", "")
        if not text or item.get("sender_id") == self.device_id:
            return
        h = text_hash(text)
        if h == self.last_hash:
            return
        self.last_hash = h  # 先更新哈希，防止写入后又被当成本地变化推回去
        await asyncio.to_thread(write_clipboard, text)
        print(f"📥 来自【{item.get('sender', '其他设备')}】: {preview(text)}")


def preview(text: str, n: int = 30) -> str:
    s = text.replace("\n", " ")
    return s[:n] + ("..." if len(s) > n else "")


def default_device_type() -> str:
    return {"darwin": "mac", "win32": "windows"}.get(sys.platform, "linux")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NelsonBox 剪贴板同步 Agent")
    parser.add_argument("--server", default=os.getenv("NELSON_SERVER"), help="中枢地址，如 http://1.2.3.4:18888")
    parser.add_argument("--token", default=os.getenv("NELSON_TOKEN"), help="访问令牌")
    parser.add_argument("--name", default=os.getenv("NELSON_DEVICE_NAME") or socket.gethostname(), help="设备名称")
    args = parser.parse_args()

    if not args.server or not args.token:
        parser.error("必须提供 --server 和 --token（或设置 NELSON_SERVER / NELSON_TOKEN 环境变量）")
    if pyperclip is None and sys.platform != "darwin":
        print(f"⚠️ 未安装 pyperclip，{platform.system()} 上无法读写剪贴板: pip install pyperclip")

    agent = ClipboardAgent(args.server, args.token, args.name, default_device_type())
    try:
        asyncio.run(agent.run())
    except KeyboardInterrupt:
        print("\n已退出")
