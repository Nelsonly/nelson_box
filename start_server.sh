#!/bin/bash
# 启动 NelsonBox 剪贴板中枢
#   NELSON_BOX_TOKEN=你的令牌 ./start_server.sh
cd "$(dirname "$0")"
export NELSON_BOX_PORT=${NELSON_BOX_PORT:-18888}

if [ -z "$NELSON_BOX_TOKEN" ]; then
  echo "❌ 请先设置 NELSON_BOX_TOKEN，例如：NELSON_BOX_TOKEN=\$(openssl rand -hex 16) ./start_server.sh"
  exit 1
fi

echo "🚀 启动 NelsonBox (端口: $NELSON_BOX_PORT)..."
# --no-access-log：不输出每个请求的日志，避免被重定向到文件后占满磁盘
exec python3 -m uvicorn server.app:app --host 0.0.0.0 --port "$NELSON_BOX_PORT" --no-access-log --log-level warning
