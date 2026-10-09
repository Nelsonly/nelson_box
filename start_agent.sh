#!/bin/bash
# 启动剪贴板同步 Agent (Mac / Linux)
#   ./start_agent.sh http://服务器IP:18888 你的令牌 [设备名]
cd "$(dirname "$0")"

SERVER_URL=${1:-$NELSON_SERVER}
TOKEN=${2:-$NELSON_TOKEN}
DEVICE_NAME=${3:-$(hostname -s)}

if [ -z "$SERVER_URL" ] || [ -z "$TOKEN" ]; then
  echo "用法: ./start_agent.sh <服务器地址> <令牌> [设备名]"
  exit 1
fi

exec python3 agent/client.py --server "$SERVER_URL" --token "$TOKEN" --name "$DEVICE_NAME"
