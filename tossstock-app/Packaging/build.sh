#!/bin/bash
# swift build -c release → .app 조립 → ad-hoc codesign.
# App Sandbox OFF(entitlements 없음): 토큰 저장 전략 a안(~/.config/tossstock 공유)이
# 샌드박스 컨테이너 홈과 충돌하므로 미샌드박스로 빌드한다. 미샌드박스 앱은 network.client
# 없이도 네트워크 접근이 가능하다. (App Store 배포 시에만 재검토)
set -euo pipefail

cd "$(dirname "$0")/.."          # → tossstock-app/
ROOT="$(pwd)"
CONFIG=release
APP="$ROOT/build/TossStock.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/TossStock"
[ -x "$BIN" ] || { echo "빌드 산출물 없음: $BIN"; exit 1; }

echo "==> .app 조립: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TossStock"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc codesign (entitlements 없음 = 미샌드박스)"
codesign --force --sign - "$APP"

echo "==> 완료: $APP"
echo "    실행: open \"$APP\"   또는   \"$APP/Contents/MacOS/TossStock\""
