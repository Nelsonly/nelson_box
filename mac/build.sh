#!/bin/bash
# 编译 Mac 菜单栏 App：./mac/build.sh
# 默认服务器和令牌读取自 app/dart_defines.json（与 Android 共用，已被 git 忽略）
set -euo pipefail
cd "$(dirname "$0")"

DEFINES=../app/dart_defines.json
SERVER=""
TOKEN=""
if [ -f "$DEFINES" ]; then
  SERVER=$(python3 -c "import json;print(json.load(open('$DEFINES')).get('NB_SERVER',''))")
  TOKEN=$(python3 -c "import json;print(json.load(open('$DEFINES')).get('NB_TOKEN',''))")
fi

BUILD=build
APP=$BUILD/NelsonBox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$BUILD/gen"

# 生成默认配置（不提交）
cat > "$BUILD/gen/Defaults.swift" <<EOF
let defaultServer = "$SERVER"
let defaultToken = "$TOKEN"
EOF

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/main.swift "$BUILD/gen/Defaults.swift" \
  -o "$APP/Contents/MacOS/NelsonBox"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "✓ 已生成 $APP"
