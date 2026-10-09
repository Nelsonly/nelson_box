import os
import sys
import json
import time
import asyncio
import hashlib
import argparse
from pathlib import Path
import urllib.request
import urllib.parse
import websockets

try:
    import pyperclip
except ImportError:
    pyperclip = None

from ai_runner import AIRunner

# 默认下载目录
DEFAULT_DOWNLOAD_DIR = Path.home() / "Downloads" / "NelsonBox"
DEFAULT_DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)


def send_mac_notification(title: str, text: str):
    """发送 macOS 桌面通知"""
    if sys.platform == "darwin":
        cmd = f'display notification "{text}" with title "{title}"'
        os.system(f"osascript -e '{cmd}' 2>/dev/null")


class NelsonAgent:
    def __init__(
        self,
        server_url: str,
        device_name: str = "Nelson's Mac",
        device_type: str = "mac",
        token: str = "nelson2026",
        auto_download: bool = True,
        clipboard_sync: bool = True,
    ):
        self.server_url = server_url.rstrip("/")
        self.device_name = device_name
        self.device_type = device_type
        self.token = token
        self.auto_download = auto_download
        self.clipboard_sync = clipboard_sync
        self.device_id = f"{device_type}_{hashlib.md5(device_name.encode()).hexdigest()[:8]}"

        self.last_clipboard_hash = ""
        self.ai_runner = AIRunner()
        self.ws = None

    def get_local_clipboard(self) -> str:
        if pyperclip:
            try:
                return pyperclip.paste() or ""
            except Exception:
                pass
        # macOS 兜底使用 pbpaste
        if sys.platform == "darwin":
            try:
                import subprocess
                return subprocess.check_output("pbpaste", universal_newlines=True)
            except Exception:
                pass
        return ""

    def set_local_clipboard(self, text: str):
        if pyperclip:
            try:
                pyperclip.copy(text)
                return
            except Exception:
                pass
        if sys.platform == "darwin":
            try:
                import subprocess
                p = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
                p.communicate(text.encode("utf-8"))
            except Exception:
                pass

    async def start(self):
        ws_scheme = "wss" if self.server_url.startswith("https") else "ws"
        host = self.server_url.split("://")[-1]
        ws_url = (
            f"{ws_scheme}://{host}/ws?"
            f"device_id={self.device_id}&"
            f"name={urllib.parse.quote(self.device_name)}&"
            f"device_type={self.device_type}&"
            f"token={urllib.parse.quote(self.token)}"
        )

        print(f"🚀 NelsonBox Agent 启动中...")
        print(f"📍 本机名称: {self.device_name} (ID: {self.device_id})")
        print(f"🌐 正在连接中枢: {self.server_url}")

        while True:
            try:
                async with websockets.connect(ws_url, ping_interval=20, ping_timeout=10) as ws:
                    self.ws = ws
                    print(f"✅ 成功连接到中枢！监听剪贴板与远程任务...")
                    send_mac_notification("NelsonBox 已连接", f"已接入中枢: {self.server_url}")

                    # 并发运行：剪贴板监听器 + 消息接收器
                    tasks = [
                        asyncio.create_task(self.receive_loop()),
                    ]
                    if self.clipboard_sync:
                        tasks.append(asyncio.create_task(self.clipboard_monitor_loop()))

                    await asyncio.gather(*tasks)
            except (websockets.ConnectionClosed, ConnectionRefusedError, OSError) as e:
                print(f"⚠️ 中枢连接断开 ({e})，3 秒后尝试自动重连...")
                await asyncio.sleep(3)
            except Exception as e:
                print(f"❌ 运行异常: {e}，5 秒后重试...")
                await asyncio.sleep(5)

    async def clipboard_monitor_loop(self):
        """本地剪贴板变化监听轮询"""
        # 初始化哈希，避免首次启动把本机剪贴板盲目推出去
        init_clip = self.get_local_clipboard()
        self.last_clipboard_hash = hashlib.md5(init_clip.encode()).hexdigest()

        while True:
            await asyncio.sleep(0.8)
            try:
                text = self.get_local_clipboard()
                if not text or len(text.strip()) == 0:
                    continue

                curr_hash = hashlib.md5(text.encode()).hexdigest()
                if curr_hash != self.last_clipboard_hash:
                    self.last_clipboard_hash = curr_hash
                    # 推送给云端
                    if self.ws and self.ws.open:
                        payload = {
                            "type": "clipboard:send",
                            "text": text,
                        }
                        await self.ws.send(json.dumps(payload))
                        print(f"📋 [剪贴板出站] 已同步到云端: {text[:30]}...")
            except Exception as e:
                pass

    async def receive_loop(self):
        """接收云端中枢下发的各类指令"""
        async for raw_msg in self.ws:
            try:
                msg = json.loads(raw_msg)
                mtype = msg.get("type")

                if mtype == "clipboard:sync":
                    # 收到远端同步过来的剪贴板
                    data = msg.get("data", {})
                    remote_text = data.get("text", "")
                    sender = data.get("sender", "其他设备")

                    if remote_text:
                        remote_hash = hashlib.md5(remote_text.encode()).hexdigest()
                        if remote_hash != self.last_clipboard_hash:
                            self.last_clipboard_hash = remote_hash
                            self.set_local_clipboard(remote_text)
                            print(f"📥 [剪贴板入站] 收到来自【{sender}】的内容已写入系统剪贴板")

                elif mtype == "file:new":
                    # 收到新文件上传广播
                    file_info = msg.get("data", {})
                    filename = file_info.get("name")
                    file_url = file_info.get("url")
                    sender = file_info.get("sender", "某设备")

                    print(f"📁 [收到文件] 【{sender}】发送了文件: {filename}")
                    send_mac_notification("收到新文件", f"{sender} 发送了 {filename}")

                    if self.auto_download and file_url:
                        await self.download_file_async(file_url, filename)

                elif mtype == "ai:execute":
                    # 手机向本机发起了 AI 问询任务！
                    prompt = msg.get("prompt", "")
                    req_id = msg.get("request_id")
                    requester_id = msg.get("requester_id")

                    print(f"🤖 [远程 AI 任务] 收到问询: {prompt}")
                    asyncio.create_task(self.handle_ai_task(prompt, req_id, requester_id))

            except Exception as e:
                print(f"处理云端消息异常: {e}")

    async def download_file_async(self, file_url: str, filename: str):
        full_url = f"{self.server_url}{file_url}"
        target_path = DEFAULT_DOWNLOAD_DIR / filename
        loop = asyncio.get_event_loop()

        def do_download():
            urllib.request.urlretrieve(full_url, str(target_path))

        try:
            await loop.run_in_executor(None, do_download)
            print(f"💾 [文件已自动保存] {target_path}")
            send_mac_notification("文件下载完成", f"已保存至 Downloads/NelsonBox/{filename}")
        except Exception as e:
            print(f"下载文件失败: {e}")

    async def handle_ai_task(self, prompt: str, req_id: str, requester_id: str):
        """流式执行 AI 问询并实时推回给手机"""
        try:
            async for chunk in self.ai_runner.stream_chat(prompt):
                if self.ws and self.ws.open:
                    await self.ws.send(
                        json.dumps(
                            {
                                "type": "ai:stream_chunk",
                                "request_id": req_id,
                                "requester_id": requester_id,
                                "chunk": chunk,
                            }
                        )
                    )
            # 完成标记
            if self.ws and self.ws.open:
                await self.ws.send(
                    json.dumps(
                        {
                            "type": "ai:done",
                            "request_id": req_id,
                            "requester_id": requester_id,
                        }
                    )
                )
        except Exception as e:
            if self.ws and self.ws.open:
                await self.ws.send(
                    json.dumps(
                        {
                            "type": "ai:error",
                            "request_id": req_id,
                            "requester_id": requester_id,
                            "error": str(e),
                        }
                    )
                )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NelsonBox Desktop Agent")
    parser.add_argument(
        "--server",
        default=os.getenv("NELSON_SERVER", "http://198.44.84.133:18888"),
        help="云端中枢地址 (如 http://198.44.84.133:18888)",
    )
    parser.add_argument(
        "--name",
        default=os.getenv("NELSON_DEVICE_NAME", "Nelson's Mac"),
        help="设备名称",
    )
    parser.add_argument(
        "--token",
        default=os.getenv("NELSON_TOKEN", "nelson2026"),
        help="访问认证令牌",
    )
    args = parser.parse_args()

    agent = NelsonAgent(
        server_url=args.server,
        device_name=args.name,
        token=args.token,
    )
    try:
        asyncio.run(agent.start())
    except KeyboardInterrupt:
        print("\n NelsonBox Agent 已退出")
