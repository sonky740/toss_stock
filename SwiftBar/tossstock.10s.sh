#!/bin/bash
# <xbar.title>Toss 보유종목·관심종목</xbar.title>
# <xbar.desc>tossctl로 보유종목 수익률 비교 + 관심종목 시세를 메뉴바에 표시</xbar.desc>
# <xbar.author>sonky</xbar.author>

# SwiftBar는 최소 환경에서 실행되므로 PATH를 직접 잡아준다.
#   tossctl -> /usr/local/bin , jq -> /opt/homebrew/bin (이 맥 기준, 확인 완료)
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:$PATH"

# ── 이 스크립트 자신의 절대 경로 (메뉴 클릭 액션에서 자기 자신을 재호출) ──
if [ -n "$SWIFTBAR_PLUGIN_PATH" ]; then
  SELF="$SWIFTBAR_PLUGIN_PATH"
else
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi

# ── 관심종목 설정 파일 (한 줄에 "코드<TAB>별칭") ──
CONFIG_DIR="$HOME/.config/tossstock"
SYMBOLS_FILE="$CONFIG_DIR/symbols.tsv"

# 최초 실행 시 기본 관심종목으로 시드 (별칭 포함)
ensure_config() {
  if [ ! -f "$SYMBOLS_FILE" ]; then
    mkdir -p "$CONFIG_DIR"
    printf '0190C0\t현피AI\n0167A0\tSOL탑\n' > "$SYMBOLS_FILE"
  fi
}

# 입력값 정리: 코드는 영숫자만(대문자), 별칭은 탭·파이프·개행 제거 후 트림
clean_code()  { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd '[:alnum:]'; }
clean_alias() { printf '%s' "$1" | tr -d '\t\n|' | sed -e 's/^ *//' -e 's/ *$//'; }

# ── 관심종목 추가 (osascript 다이얼로그로 코드·별칭 입력) ──
do_add() {
  ensure_config
  local code aliasname
  code=$(osascript 2>/dev/null <<'OSA'
set r to ""
try
  set d to display dialog "추가할 종목코드를 입력하세요 (예: 0190C0)" default answer "" with title "관심종목 추가" buttons {"취소", "추가"} default button "추가"
  set r to text returned of d
end try
return r
OSA
)
  code=$(clean_code "$code")
  [ -z "$code" ] && return 0

  # 이미 등록된 코드면 알림 후 종료
  if awk -F'\t' -v c="$code" '$1==c{f=1} END{exit !f}' "$SYMBOLS_FILE"; then
    osascript 2>/dev/null -e "display dialog \"이미 등록된 종목입니다: $code\" with title \"관심종목 추가\" buttons {\"확인\"} default button \"확인\""
    return 0
  fi

  aliasname=$(osascript 2>/dev/null <<'OSA'
set r to ""
try
  set d to display dialog "메뉴바에 표시할 별칭 (선택 — 비우면 종목명 사용)" default answer "" with title "별칭 설정" buttons {"건너뛰기", "저장"} default button "저장"
  set r to text returned of d
end try
return r
OSA
)
  aliasname=$(clean_alias "$aliasname")
  printf '%s\t%s\n' "$code" "$aliasname" >> "$SYMBOLS_FILE"
}

# ── 관심종목 삭제 (코드 일치 행 제거) ──
do_remove() {
  ensure_config
  local target tmp
  target=$(clean_code "$1")
  [ -z "$target" ] && return 0
  tmp=$(mktemp)
  awk -F'\t' -v c="$target" '$1!=c' "$SYMBOLS_FILE" > "$tmp" && mv "$tmp" "$SYMBOLS_FILE"
}

# ── 클릭 액션 처리: 인자가 있으면 렌더 대신 동작 수행 후 종료 ──
case "$1" in
  add)    do_add; exit 0 ;;
  remove) do_remove "$2"; exit 0 ;;
esac

ensure_config

# ── 1000 단위 콤마 (양의 정수 문자열 입력) ──
comma() { echo "$1" | sed -e ':a' -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'; }

# ── 표시 포맷 헬퍼 ──
fmt_krw() {  # 원화 현재가: ₩351,500
  printf '₩%s' "$(comma "$(printf '%.0f' "$1")")"
}
fmt_usd() {  # 달러 현재가: $1,234.05
  local f int dec
  f=$(printf '%.2f' "$1"); int="${f%.*}"; dec="${f#*.}"
  printf '$%s.%s' "$(comma "$int")" "$dec"
}
fmt_pnl() {  # 평가손익(원화): +16,750원 / -1,000원 / 0원
  local n sign abs
  n=$(printf '%.0f' "$1")
  case "$n" in
    -*) sign="-"; abs="${n#-}" ;;
    *)  sign="+"; abs="$n" ;;
  esac
  [ "$abs" = "0" ] && { printf '0원'; return; }
  printf '%s%s원' "$sign" "$(comma "$abs")"
}

# ─────────────────────────────────────────────────────────────
# 1) 보유종목 비교 (portfolio positions — 매입가 대비 누적 수익률)
# ─────────────────────────────────────────────────────────────
port_titles=()   # 메뉴바 회전 후보 (보유종목)
port_lines=()    # 드롭다운 비교 리스트

POS=$(tossctl portfolio positions --output json 2>/dev/null | jq -s '.[0]')

if [ -z "$POS" ] || [ "$POS" = "null" ] || [ "$(echo "$POS" | jq -r 'type' 2>/dev/null)" != "array" ]; then
  port_lines+=("보유종목 조회 실패 (인증 확인) | color=gray")
elif [ "$(echo "$POS" | jq -r 'length')" -eq 0 ]; then
  port_lines+=("보유종목 없음 | color=gray")
else
  # 미국주식 USD 현재가 일괄 조회 (현재가만 달러; 손익은 원화)
  US_SYMS=$(echo "$POS" | jq -r '.[] | select(.market_type=="US_STOCK") | .symbol' | tr '\n' ',' | sed 's/,$//')
  US_Q="[]"
  if [ -n "$US_SYMS" ]; then
    US_Q=$(tossctl quote batch "$US_SYMS" --output json 2>/dev/null | jq -s '.[0]')
    if [ -z "$US_Q" ] || [ "$US_Q" = "null" ]; then US_Q="[]"; fi
  fi

  TSV=$(echo "$POS" | jq -r '
    .[] | [
      .symbol,
      .market_type,
      (.name | gsub("[\t\n|]"; "")),
      (.current_price // 0),
      ((.profit_rate // 0) * 100),
      (.unrealized_pnl // 0),
      (if (.profit_rate // 0) > 0 then "up" elif (.profit_rate // 0) < 0 then "down" else "flat" end)
    ] | @tsv')

  while IFS=$'\t' read -r sym mtype name cur pr100 pnl dir; do
    [ -z "$sym" ] && continue

    # 현재가: 국내 ₩, 미국 $ (quote 실패 시 ₩ 폴백)
    if [ "$mtype" = "US_STOCK" ]; then
      usd=$(echo "$US_Q" | jq -r --arg s "$sym" '(.[] | select(.symbol==$s) | .last) // empty' 2>/dev/null)
      if [ -n "$usd" ] && [ "$usd" != "null" ]; then
        price_disp=$(fmt_usd "$usd")
      else
        price_disp=$(fmt_krw "$cur")
      fi
    else
      price_disp=$(fmt_krw "$cur")
    fi

    # 수익률% (매입가 대비, 부호 표시)
    if [ "$dir" = "flat" ]; then
      pct_disp=$(printf '%.2f%%' "$pr100")
    else
      pct_disp=$(printf '%+.2f%%' "$pr100")
    fi

    case "$dir" in
      up)   color="green" ;;
      down) color="red" ;;
      *)    color="gray" ;;
    esac

    port_titles+=("$name $price_disp $pct_disp")
    port_lines+=("$name  $price_disp  $pct_disp  $(fmt_pnl "$pnl") | color=$color")
  done <<< "$TSV"
fi

# ─────────────────────────────────────────────────────────────
# 2) 관심종목 (symbols.tsv — 당일 등락 시세)
# ─────────────────────────────────────────────────────────────
SYMBOLS=()
ALIASES=()
while IFS=$'\t' read -r code aliasname || [ -n "$code" ]; do
  [ -z "$code" ] && continue
  case "$code" in \#*) continue ;; esac
  SYMBOLS+=("$code")
  ALIASES+=("$aliasname")
done < "$SYMBOLS_FILE"

watch_titles=()  # 보유종목이 없을 때 메뉴바 폴백용
watch_lines=()   # 드롭다운 관심종목 리스트

for i in "${!SYMBOLS[@]}"; do
  sym="${SYMBOLS[$i]}"
  short="${ALIASES[$i]}"

  data=$(tossctl quote get "$sym" --output json 2>/dev/null | jq -s '.[0]')

  if [ -z "$data" ] || [ "$data" = "null" ]; then
    watch_lines+=("$sym  조회실패 (코드/인증 확인) | color=gray")
    watch_titles+=("$sym ⚠️")
    continue
  fi

  full=$(echo "$data" | jq -r '.name // .symbol')   # 전체 종목명 (드롭다운용)
  [ -z "$short" ] && short="$full"                  # 별칭 없으면 종목명 사용
  last=$(echo "$data" | jq -r '.last')
  ccy=$(echo "$data" | jq -r '.currency // "KRW"')
  # 등락률(%) 절댓값, 소수점 2자리
  rate=$(echo "$data" | jq -r '(((.change_rate|fabs)*10000)|round)/100')
  # 등락액 절댓값
  chg=$(echo "$data" | jq -r '(.change|fabs)')
  # 방향: up / down / flat
  dir=$(echo "$data" | jq -r 'if .change_rate>0 then "up" elif .change_rate<0 then "down" else "flat" end')

  case "$dir" in
    up)   arrow="▲"; color="green" ;;
    down) arrow="▼"; color="red" ;;
    *)    arrow="▬"; color="gray" ;;
  esac

  # 통화 인식: 미국주식($)·국내(₩) — 보유종목 섹션과 동일하게 현재가·등락액 통화 표시
  if [ "$ccy" = "USD" ]; then
    price_disp=$(fmt_usd "$last")
    chg_disp=$(fmt_usd "$chg")
  else
    price_disp=$(fmt_krw "$last")
    chg_disp=$(comma "$chg")
  fi

  watch_titles+=("$short $price_disp ${arrow}${rate}%")
  watch_lines+=("$full  $price_disp  ${arrow}${rate}% (${arrow}${chg_disp}) | color=$color")
done

# ─────────────────────────────────────────────────────────────
# 메뉴바 제목: 보유종목을 번갈아 표시 (없으면 관심종목으로 폴백)
# ─────────────────────────────────────────────────────────────
titles=("${port_titles[@]}")
if [ "${#titles[@]}" -eq 0 ]; then
  titles=("${watch_titles[@]}")
fi

if [ "${#titles[@]}" -eq 0 ]; then
  echo "📈 종목 없음"
else
  STATE_FILE="/tmp/tossstock_rotate.idx"
  idx=$(cat "$STATE_FILE" 2>/dev/null)
  case "$idx" in ""|*[!0-9]*) idx=0 ;; esac
  count=${#titles[@]}
  cur_i=$(( 10#$idx % count ))           # 10#: 외부 손상으로 08/09 같은 값이 와도 8진수 오류 방지
  echo $(( (10#$idx + 1) % count )) > "$STATE_FILE"
  echo "${titles[$cur_i]}"
fi

# ── 드롭다운: 보유종목 비교 ──
echo "---"
echo "📊 내 보유종목 비교 (매입가 대비)"
for line in "${port_lines[@]}"; do
  echo "$line"
done

# ── 드롭다운: 관심종목 시세 ──
echo "---"
echo "⭐ 관심종목 (당일 등락)"
if [ "${#watch_lines[@]}" -gt 0 ]; then
  for line in "${watch_lines[@]}"; do
    echo "$line"
  done
else
  echo "관심종목 없음 | color=gray"
fi

# ── 관심종목 관리 (메뉴바에서 실시간 추가·삭제) ──
echo "관심종목 관리"
echo "➕ 종목 추가… | bash='$SELF' param1='add' terminal=false refresh=true"
if [ "${#SYMBOLS[@]}" -gt 0 ]; then
  echo "➖ 종목 삭제"
  for i in "${!SYMBOLS[@]}"; do
    sym="${SYMBOLS[$i]}"
    label="${ALIASES[$i]}"
    [ -z "$label" ] && label="$sym"
    echo "-- ❌ ${label} (${sym}) | bash='$SELF' param1='remove' param2='$sym' terminal=false refresh=true"
  done
fi

echo "---"
echo "🔄 새로고침 | refresh=true"
echo "인증 상태 확인 | bash='/usr/local/bin/tossctl' param1='auth' param2='status' terminal=true"
