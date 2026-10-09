import json
import urllib.request
import urllib.error
import subprocess
import shutil
import asyncio
from typing import AsyncGenerator


class AIRunner:
    def __init__(self, ollama_url: str = "http://127.0.0.1:11434"):
        self.ollama_url = ollama_url

    async def get_available_engine(self) -> str:
        """检测当前机器可用的 AI 引擎"""
        # 1. 检测本地 Ollama 是否在线
        try:
            req = urllib.request.Request(f"{self.ollama_url}/api/tags")
            with urllib.request.urlopen(req, timeout=1) as response:
                if response.status == 200:
                    data = json.loads(response.read().decode())
                    models = [m["name"] for m in data.get("models", [])]
                    if models:
                        return f"ollama:{models[0]}"
        except Exception:
            pass

        # 2. 检测本地是否有 claude CLI
        if shutil.which("claude"):
            return "claude_cli"

        return "system_agent"

    async def stream_chat(
        self, prompt: str, model: str = "auto"
    ) -> AsyncGenerator[str, None]:
        """流式生成回答"""
        engine = await self.get_available_engine()

        if engine.startswith("ollama:"):
            # 使用本地 Ollama 大模型推理
            model_name = engine.split(":", 1)[1] if model == "auto" else model
            req_data = json.dumps({"model": model_name, "prompt": prompt, "stream": True}).encode()
            req = urllib.request.Request(
                f"{self.ollama_url}/api/generate",
                data=req_data,
                headers={"Content-Type": "application/json"},
            )

            try:
                loop = asyncio.get_event_loop()
                # 包装为异步读取
                def fetch_stream():
                    return urllib.request.urlopen(req, timeout=60)

                resp = await loop.run_in_executor(None, fetch_stream)
                for line in resp:
                    if line:
                        chunk_obj = json.loads(line.decode())
                        token = chunk_obj.get("response", "")
                        if token:
                            yield token
            except Exception as e:
                yield f"\n[Ollama 错误: {e}]"

        elif engine == "claude_cli":
            # 调用本地 Claude CLI
            yield f"[正在通过本地 Claude 执行...]\n"
            proc = await asyncio.create_subprocess_exec(
                "claude",
                "-p",
                prompt,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                yield line.decode()
            await proc.wait()

        else:
            # 基础内置调度助手 (System Agent)
            yield f"### 💻 来自 Mac 本地中枢的回复\n\n"
            yield f"**收到远程问询**：`{prompt}`\n\n"
            yield f"- **算力节点状态**：Mac 正常运行中\n"
            yield f"- **提示**：如果本机或小主机已安装并启动 **Ollama**（如 `ollama run qwen2.5:7b` 或 `deepseek-r1:7b`），将自动无缝接管并流式输出完整的深度大模型思考与回答！\n"
