#!/bin/bash
# 启动 NelsonBox 云端中枢服务
cd "$(dirname "$0")"
export NELSON_BOX_PORT=${NELSON_BOX_PORT:-18888}
export NELSON_BOX_TOKEN=${NELSON_BOX_TOKEN:-"nelson2026"}

echo "🚀 启动 NelsonBox Hub (端口: $NELSON_BOX_PORT)..."
python3 -m uvicorn server.app:app --host 0.0.0.0 --port $NELSON_BOX_PORT
