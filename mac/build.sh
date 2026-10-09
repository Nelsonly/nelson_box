#!/bin/bash
# 编译 Mac App：./mac/build.sh
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

# 生成默认配置（已被 git 忽略）
mkdir -p Sources/Generated
cat > Sources/Generated/Defaults.swift <<EOF
let defaultServer = "$SERVER"
let defaultToken = "$TOKEN"
EOF

swift build -c release

BIN=$(swift build -c release --show-bin-path)
APP=build/NelsonBox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/NelsonBox" "$APP/Contents/MacOS/NelsonBox"
cp -R "$BIN/WebRTC.framework" "$APP/Contents/Frameworks/"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/NelsonBox.icns "$APP/Contents/Resources/NelsonBox.icns"
codesign --force --deep --sign - "$APP"
echo "✓ 已生成 $APP ($(du -sh "$APP" | cut -f1))"
