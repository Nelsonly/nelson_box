import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

# 安全令牌（默认值可在部署时通过环境变量覆盖）
AUTH_TOKEN = os.getenv("NELSON_BOX_TOKEN", "nelson2026")

HOST = os.getenv("NELSON_BOX_HOST", "0.0.0.0")
PORT = int(os.getenv("NELSON_BOX_PORT", "18888"))

MAX_CLIPBOARD_HISTORY = 30
MAX_UPLOAD_SIZE_MB = 500
