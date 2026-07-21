#!/bin/bash
# 재빌드 → 실행 중 인스턴스 종료 → /Applications 제자리 교체 → 재실행.
# build.sh(release 빌드 + .app 조립 + ad-hoc 서명)를 그대로 재사용하고,
# 그 산출물을 /Applications 에 "같은 경로"로 덮어써서 설치본을 갱신한다.
# 로그인 항목은 경로 기반(구형 System Events)이라 같은 경로에 교체하면
# 재등록 없이 다음 로그인부터 새 버전이 뜬다. (없으면 자동 등록만 시도)
set -euo pipefail

cd "$(dirname "$0")/.."          # → tossstock-app/
ROOT="$(pwd)"
NEW="$ROOT/build/TossStock.app"
DEST="/Applications/TossStock.app"
EXEC_PAT="TossStock.app/Contents/MacOS/TossStock"

echo "==> [1/4] 재빌드 (Packaging/build.sh)"
bash "$ROOT/Packaging/build.sh"
[ -d "$NEW" ] || { echo "빌드 산출물 없음: $NEW"; exit 1; }

echo "==> [2/4] 실행 중 인스턴스 종료"
if pkill -f "$EXEC_PAT" 2>/dev/null; then
  echo "   종료 신호 전송 — 프로세스 내려갈 때까지 대기"
  for _ in $(seq 1 25); do
    pgrep -f "$EXEC_PAT" >/dev/null || break
    sleep 0.2
  done
  pgrep -f "$EXEC_PAT" >/dev/null && { echo "   강제 종료(SIGKILL)"; pkill -9 -f "$EXEC_PAT" || true; sleep 0.5; }
  echo "   종료 확인"
else
  echo "   (실행 중 프로세스 없음)"
fi

echo "==> [3/4] /Applications 제자리 교체"
rm -rf "$DEST"
ditto "$NEW" "$DEST"
codesign --verify --verbose "$DEST" 2>&1 | tail -1 || true
echo "   교체 완료: $DEST"

# 로그인 항목 보증 — 없을 때만 등록(경로 기반). 자동화 권한 없으면 조용히 건너뜀.
if osascript -e 'tell application "System Events" to exists login item "TossStock"' 2>/dev/null | grep -q true; then
  echo "   로그인 항목 이미 등록됨(경로 유지 → 새 버전 반영)"
else
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$DEST\", hidden:false, name:\"TossStock\"}" 2>/dev/null \
    && echo "   로그인 항목 신규 등록" \
    || echo "   (로그인 항목 등록 건너뜀 — 자동화 권한 필요 시 시스템 설정에서 수동 추가)"
fi

echo "==> [4/4] 재실행"
open "$DEST"
sleep 1
if pgrep -f "$EXEC_PAT" >/dev/null; then
  echo "   실행 확인 (PID $(pgrep -f "$EXEC_PAT" | head -1))"
else
  echo "   경고: 실행 확인 실패 — 수동으로 open \"$DEST\" 시도"
fi
echo "==> 완료"
