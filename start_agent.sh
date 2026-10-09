#!/bin/bash
# 启动 NelsonBox 桌面守护 Agent (Mac / Linux)
cd "$(dirname "$0")"

SERVER_URL=${1:-"http://198.44.84.133:18888"}
DEVICE_NAME=${2:-"Nelson's Mac"}
TOKEN=${3:-"nelson2026"}

echo "💻 启动 NelsonBox Agent，连接至: $SERVER_URL ..."
python3 agent/client.py --server "$SERVER_URL" --name "$DEVICE_NAME" --token "$TOKEN"
