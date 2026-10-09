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
