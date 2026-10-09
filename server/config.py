import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)
CLIPBOARD_FILE = DATA_DIR / "clipboard.json"

# 访问令牌，必须通过环境变量设置，不提供默认值
AUTH_TOKEN = os.getenv("NELSON_BOX_TOKEN", "")
if not AUTH_TOKEN:
    raise RuntimeError("请先设置环境变量 NELSON_BOX_TOKEN（访问令牌）")

HOST = os.getenv("NELSON_BOX_HOST", "0.0.0.0")
PORT = int(os.getenv("NELSON_BOX_PORT", "18888"))

# 存储上限：最多 50 条 × 64KB ≈ 3.2MB，磁盘占用可控
MAX_CLIPBOARD_HISTORY = 50
MAX_CLIPBOARD_BYTES = 64 * 1024

# P2P 文件传输：优先直连；直连失败时可经 TURN（coturn）实时转发加密数据，不落盘
STUN_PORT = int(os.getenv("NELSON_BOX_STUN_PORT", "3478"))  # 内置 STUN；用 coturn 时设为 0
STUN_HOST = os.getenv("NELSON_BOX_STUN_HOST", "")  # 留空则使用客户端访问时的主机名
TURN_SECRET = os.getenv("NELSON_BOX_TURN_SECRET", "")  # 与 coturn 的 static-auth-secret 相同；留空则不提供中转
TURN_PORT = int(os.getenv("NELSON_BOX_TURN_PORT", "3478"))
TURN_TTL_SECONDS = 24 * 3600
EXTRA_STUN_SERVERS = [
    u for u in os.getenv("NELSON_BOX_EXTRA_STUN", "stun:stun.cloudflare.com:3478").split(",") if u
]
