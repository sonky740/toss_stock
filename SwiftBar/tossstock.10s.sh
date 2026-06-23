#!/bin/bash
# <xbar.title>Toss 보유종목·관심종목</xbar.title>
# <xbar.desc>토스증권 Open API로 보유종목 수익률 비교 + 관심종목 시세를 메뉴바에 표시</xbar.desc>
# <xbar.author>sonky</xbar.author>

# SwiftBar는 최소 환경에서 실행되므로 PATH를 직접 잡아준다.
#   curl -> /usr/bin (시스템 기본) , jq -> /opt/homebrew/bin (이 맥 기준, 확인 완료)
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

# ── 이 스크립트 자신의 절대 경로 (메뉴 클릭 액션에서 자기 자신을 재호출) ──
if [ -n "$SWIFTBAR_PLUGIN_PATH" ]; then
  SELF="$SWIFTBAR_PLUGIN_PATH"
else
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi

# ── 설정 디렉터리 ──
CONFIG_DIR="$HOME/.config/tossstock"
SYMBOLS_FILE="$CONFIG_DIR/symbols.tsv"   # 관심종목 ("코드<TAB>별칭")
AUTH_ENV="$CONFIG_DIR/auth.env"          # client_id / client_secret (레포 밖, chmod 600)
TOKEN_FILE="$CONFIG_DIR/token.json"      # access token 캐시 (만료까지 재사용)
API="https://openapi.tossinvest.com"

# 최초 실행 시 기본 관심종목으로 시드 (별칭 포함)
ensure_config() {
  if [ ! -f "$SYMBOLS_FILE" ]; then
    mkdir -p "$CONFIG_DIR"
    printf '0190C0\t현피AI\n0167A0\tSOL탑\n' > "$SYMBOLS_FILE"
  fi
}

# 입력값 정리: 코드는 영숫자·.·- 만(대문자), 별칭은 탭·파이프·개행 제거 후 트림
clean_code()  { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd '[:alnum:].-'; }
clean_alias() { printf '%s' "$1" | tr -d '\t\n|' | sed -e 's/^ *//' -e 's/ *$//'; }

# ── 관심종목 추가 (osascript 다이얼로그로 코드·별칭 입력) ──
do_add() {
  ensure_config
  local code aliasname
  code=$(osascript 2>/dev/null <<'OSA'
set r to ""
try
  set d to display dialog "추가할 종목코드를 입력하세요 (KR: 005930 / US: AAPL / ETF: 0190C0)" default answer "" with title "관심종목 추가" buttons {"취소", "추가"} default button "추가"
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

# ─────────────────────────────────────────────────────────────
# 토스증권 Open API 인증 (OAuth2 Client Credentials Grant)
#   - access token 은 만료(기본 24h)까지 token.json 에 캐시해 재사용한다.
#   - SwiftBar 는 10초마다 재실행되므로 매번 토큰을 재발급하면 안 된다
#     (client 당 토큰 1개 — 재발급 시 이전 토큰 즉시 무효화 + AUTH rate limit).
#   - 401(만료/무효) 수신 시 1회 강제 재발급 후 재시도한다.
# ─────────────────────────────────────────────────────────────
load_creds() { [ -f "$AUTH_ENV" ] && . "$AUTH_ENV"; }

ACCESS=""   # 현재 access token
SEQ=""      # X-Tossinvest-Account 헤더용 accountSeq

# 토큰을 발급(또는 캐시 로드)해 ACCESS·SEQ 전역에 채운다. 인자 "force" 면 캐시 무시.
ensure_token() {
  local force="$1" now exp tj at ein
  ACCESS=""; SEQ=""

  if [ "$force" != "force" ] && [ -f "$TOKEN_FILE" ]; then
    now=$(date +%s)
    exp=$(jq -r '.expires_at // 0' "$TOKEN_FILE" 2>/dev/null)
    if [ -n "$exp" ] && [ "$exp" -gt "$now" ] 2>/dev/null; then
      ACCESS=$(jq -r '.access_token // empty' "$TOKEN_FILE" 2>/dev/null)
      SEQ=$(jq -r '.account_seq // empty' "$TOKEN_FILE" 2>/dev/null)
    fi
  fi

  # 캐시에 토큰은 있으나 accountSeq 가 비었으면 보강 (계좌 조회 1회)
  if [ -n "$ACCESS" ] && [ -z "$SEQ" ]; then
    SEQ=$(curl -s --max-time 10 "$API/api/v1/accounts" -H "Authorization: Bearer $ACCESS" \
      | jq -r '.result[0].accountSeq // empty' 2>/dev/null)
    [ -n "$SEQ" ] && _write_token_cache "$ACCESS" "$exp" "$SEQ"
  fi

  [ -n "$ACCESS" ] && return 0

  # 신규 발급
  load_creds
  [ -z "$TOSS_CLIENT_ID" ] || [ -z "$TOSS_CLIENT_SECRET" ] && return 1

  tj=$(curl -s --max-time 10 -X POST "$API/oauth2/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_id=$TOSS_CLIENT_ID" \
    --data-urlencode "client_secret=$TOSS_CLIENT_SECRET")
  at=$(echo "$tj" | jq -r '.access_token // empty' 2>/dev/null)
  ein=$(echo "$tj" | jq -r '.expires_in // 0' 2>/dev/null)
  [ -z "$at" ] && return 1
  ACCESS="$at"

  SEQ=$(curl -s --max-time 10 "$API/api/v1/accounts" -H "Authorization: Bearer $ACCESS" \
    | jq -r '.result[0].accountSeq // empty' 2>/dev/null)

  now=$(date +%s)
  exp=$(( now + ein - 300 ))   # 만료 5분 전을 캐시 만료로 (선제 재발급)
  _write_token_cache "$ACCESS" "$exp" "$SEQ"
  return 0
}

_write_token_cache() {
  local at="$1" exp="$2" seq="$3"
  ( umask 077
    jq -n --arg at "$at" --argjson exp "${exp:-0}" --arg seq "$seq" \
      '{access_token:$at, expires_at:$exp, account_seq:$seq}' > "$TOKEN_FILE" )
  chmod 600 "$TOKEN_FILE" 2>/dev/null
}

# 단일 GET 요청. $1=경로(쿼리 포함), $2="acct" 면 X-Tossinvest-Account 헤더 추가.
# 응답 본문 + 마지막 줄에 HTTP 상태코드를 함께 출력한다 (상태코드 판정은 호출부가 한다).
_request() {
  local path="$1" acct="$2"
  local hdr=(-H "Authorization: Bearer $ACCESS")
  [ "$acct" = "acct" ] && hdr+=(-H "X-Tossinvest-Account: $SEQ")
  curl -s --max-time 10 -w $'\n%{http_code}' "${hdr[@]}" "$API$path"
}

# 토큰 확보 후 GET. 401 이면 1회 강제 재발급하여 재시도. 본문을 stdout 으로, HTTP 200 일 때만 종료코드 0.
#   주의: _request 의 출력을 $() 로 받으면 그 서브셸 안에서 설정한 변수는 밖으로 전파되지
#   않는다. 그래서 상태코드는 전역에 두지 말고, raw 응답 끝줄을 호출부(api_get)에서 분리한다.
api_get() {
  ensure_token || return 1
  local raw code body
  raw=$(_request "$1" "$2"); code="${raw##*$'\n'}"; body="${raw%$'\n'*}"
  if [ "$code" = "401" ]; then
    ensure_token force || return 1
    raw=$(_request "$1" "$2"); code="${raw##*$'\n'}"; body="${raw%$'\n'*}"
  fi
  printf '%s' "$body"
  [ "$code" = "200" ]
}

# ── 클릭 액션 처리: 인자가 있으면 렌더 대신 동작 수행 후 종료 ──
case "$1" in
  add)    do_add; exit 0 ;;
  remove) do_remove "$2"; exit 0 ;;
  authstatus)
    # 터미널에서 인증 상태 점검 (토큰 발급/계좌 확인)
    if ensure_token; then
      acc=$(api_get "/api/v1/accounts")
      no=$(echo "$acc" | jq -r '.result[0].accountNo // "?"' 2>/dev/null)
      exp=$(jq -r '.expires_at // 0' "$TOKEN_FILE" 2>/dev/null)
      echo "토스증권 Open API 인증 OK"
      echo "계좌번호 : $no  (accountSeq=$SEQ)"
      [ "$exp" -gt 0 ] 2>/dev/null && echo "토큰 캐시 만료 : $(date -r "$exp" '+%Y-%m-%d %H:%M:%S')"
    else
      echo "인증 실패"
      echo "확인: $AUTH_ENV 의 TOSS_CLIENT_ID / TOSS_CLIENT_SECRET"
    fi
    exit 0 ;;
esac

ensure_config

# ── 자격증명 미설정 시: 설정 안내 메뉴만 출력하고 종료 ──
load_creds
if [ -z "$TOSS_CLIENT_ID" ] || [ -z "$TOSS_CLIENT_SECRET" ]; then
  echo "🔐 Toss API 설정 필요"
  echo "---"
  echo "client_id / client_secret 미설정 | color=gray"
  echo "$AUTH_ENV 에 다음을 작성하세요 | color=gray"
  echo "-- TOSS_CLIENT_ID='...' | font=Menlo"
  echo "-- TOSS_CLIENT_SECRET='...' | font=Menlo"
  echo "토스증권 WTS → 설정 → Open API 에서 발급 | href=https://developers.tossinvest.com/docs"
  echo "---"
  echo "🔄 새로고침 | refresh=true"
  exit 0
fi

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
fmt_pnl_krw() {  # 평가손익(원화): +16,750원 / -1,000원 / 0원
  local n sign abs
  n=$(printf '%.0f' "$1")
  case "$n" in
    -*) sign="-"; abs="${n#-}" ;;
    *)  sign="+"; abs="$n" ;;
  esac
  [ "$abs" = "0" ] && { printf '0원'; return; }
  printf '%s%s원' "$sign" "$(comma "$abs")"
}
fmt_pnl_usd() {  # 평가손익(달러): +$232.00 / -$53.47 / $0.00
  local f sign int dec
  f=$(printf '%.2f' "$1")
  case "$f" in -*) sign="-"; f="${f#-}" ;; *) sign="+" ;; esac
  [ "$f" = "0.00" ] && { printf '$0.00'; return; }
  int="${f%.*}"; dec="${f#*.}"
  printf '%s$%s.%s' "$sign" "$(comma "$int")" "$dec"
}

# ─────────────────────────────────────────────────────────────
# 1) 보유종목 비교 (GET /api/v1/holdings — 매입가 대비 누적 수익률)
#    종목별로 native 통화(KR=KRW, US=USD)의 현재가·손익률·손익액을 그대로 받는다.
# ─────────────────────────────────────────────────────────────
port_titles=()   # 메뉴바 회전 후보 (보유종목)
port_lines=()    # 드롭다운 비교 리스트

HOLD=$(api_get "/api/v1/holdings" acct)
hold_ok=$?
items_len=$(echo "$HOLD" | jq -r '.result.items | length' 2>/dev/null)

if [ "$hold_ok" -ne 0 ] || [ -z "$items_len" ] || ! [ "$items_len" -ge 0 ] 2>/dev/null; then
  port_lines+=("보유종목 조회 실패 (인증 확인) | color=gray")
elif [ "$items_len" -eq 0 ]; then
  port_lines+=("보유종목 없음 | color=gray")
else
  TSV=$(echo "$HOLD" | jq -r '
    .result.items[] | [
      .symbol,
      .currency,
      (.name | gsub("[\t\n|]"; "")),
      (.lastPrice // "0"),
      ((.profitLoss.rate | tonumber) * 100),
      (.profitLoss.amount // "0"),
      (if (.profitLoss.rate | tonumber) > 0 then "up"
       elif (.profitLoss.rate | tonumber) < 0 then "down"
       else "flat" end)
    ] | @tsv')

  while IFS=$'\t' read -r sym ccy name last pr100 pnl dir; do
    [ -z "$sym" ] && continue

    # 현재가·평가손익: 통화별 표기 (KRW=₩/원, USD=$)
    if [ "$ccy" = "USD" ]; then
      price_disp=$(fmt_usd "$last")
      pnl_disp=$(fmt_pnl_usd "$pnl")
    else
      price_disp=$(fmt_krw "$last")
      pnl_disp=$(fmt_pnl_krw "$pnl")
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
    port_lines+=("$name  $price_disp  $pct_disp  $pnl_disp | color=$color")
  done <<< "$TSV"
fi

# ─────────────────────────────────────────────────────────────
# 2) 관심종목 (symbols.tsv — 당일 등락 시세)
#    현재가는 /prices(batch), 종목명은 /stocks(batch), 전일종가는
#    /candles(종목당 1회, interval=1d count=2 의 두 번째 봉)로 구해 등락을 계산.
#    /prices·/stocks 는 잘못된 코드를 조용히 누락(200)하므로 줄 단위로 격리된다.
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
NAMES=()         # SYMBOLS와 인덱스 정렬된 실제 종목명 (삭제 메뉴용; 조회 실패면 미설정)

PRICES='{}'
STOCKS='{}'
if [ "${#SYMBOLS[@]}" -gt 0 ]; then
  csv=$(printf '%s,' "${SYMBOLS[@]}"); csv="${csv%,}"
  PRICES=$(api_get "/api/v1/prices?symbols=$csv") || PRICES='{}'
  STOCKS=$(api_get "/api/v1/stocks?symbols=$csv") || STOCKS='{}'
fi

for i in "${!SYMBOLS[@]}"; do
  sym="${SYMBOLS[$i]}"
  short="${ALIASES[$i]}"

  last=$(echo "$PRICES" | jq -r --arg s "$sym" '(.result[]? | select(.symbol==$s) | .lastPrice) // empty' 2>/dev/null)
  ccy=$(echo "$PRICES" | jq -r --arg s "$sym" '(.result[]? | select(.symbol==$s) | .currency) // "KRW"' 2>/dev/null)
  full=$(echo "$STOCKS" | jq -r --arg s "$sym" '(.result[]? | select(.symbol==$s) | .name) // empty' 2>/dev/null)

  if [ -z "$last" ]; then
    watch_lines+=("$sym  조회실패 (코드/인증 확인) | color=gray")
    watch_titles+=("$sym ⚠️")
    continue
  fi

  [ -n "$full" ] && NAMES[$i]="$full"   # 실제 종목명만 보관 (코드 폴백은 제외)
  [ -z "$full" ] && full="$sym"         # 종목명 조회 실패 시 코드
  [ -z "$short" ] && short="$full"      # 별칭 없으면 종목명 사용

  # 전일종가: 일봉 2개 중 두 번째(직전 세션 종가).
  # candles 는 MARKET_DATA_CHART(초당 5회) 제한 — 종목당 1회씩 연속 호출하므로
  # 호출 간 0.25초 간격을 둬 버스트로 429 가 나는 것을 막는다.
  cand=$(api_get "/api/v1/candles?symbol=$sym&interval=1d&count=2")
  prev=$(echo "$cand" | jq -r '.result.candles[1].closePrice // empty' 2>/dev/null)
  sleep 0.25

  if [ -n "$prev" ] && awk -v p="$prev" 'BEGIN{exit !(p+0>0)}'; then
    # 등락 = 현재가 - 전일종가 (문자열/소수 안전하게 awk 로 계산)
    read -r dir rate_disp chg_abs < <(awk -v l="$last" -v p="$prev" 'BEGIN{
      c=l-p; r=(p!=0)?(c/p*100):0;
      ca=(c<0)?-c:c; ra=(r<0)?-r:r;
      d=(c>0)?"up":((c<0)?"down":"flat");
      printf "%s %.2f %.4f", d, ra, ca
    }')
    case "$dir" in
      up)   arrow="▲"; color="green" ;;
      down) arrow="▼"; color="red" ;;
      *)    arrow="▬"; color="gray" ;;
    esac
    if [ "$ccy" = "USD" ]; then
      price_disp=$(fmt_usd "$last"); chg_disp=$(fmt_usd "$chg_abs")
    else
      price_disp=$(fmt_krw "$last"); chg_disp=$(comma "$(printf '%.0f' "$chg_abs")")
    fi
    watch_titles+=("$short $price_disp ${arrow}${rate_disp}%")
    watch_lines+=("$full  $price_disp  ${arrow}${rate_disp}% (${arrow}${chg_disp}) | color=$color")
  else
    # 전일종가 없음(신규상장 등) → 현재가만 표시
    if [ "$ccy" = "USD" ]; then price_disp=$(fmt_usd "$last"); else price_disp=$(fmt_krw "$last"); fi
    watch_titles+=("$short $price_disp")
    watch_lines+=("$full  $price_disp  (등락 데이터 없음) | color=gray")
  fi
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
    aliasname="${ALIASES[$i]}"
    name="${NAMES[$i]}"
    # 표시명: 종목명 우선, 별칭이 있으면 병기. 종목명 조회 실패 시 별칭 → 코드 폴백
    if [ -n "$name" ] && [ -n "$aliasname" ]; then
      label="${name} · ${aliasname}"
    elif [ -n "$name" ]; then
      label="$name"
    elif [ -n "$aliasname" ]; then
      label="$aliasname"
    else
      label="$sym"
    fi
    echo "-- ❌ ${label} (${sym}) | bash='$SELF' param1='remove' param2='$sym' terminal=false refresh=true"
  done
fi

echo "---"
echo "🔄 새로고침 | refresh=true"
echo "인증 상태 확인 | bash='$SELF' param1='authstatus' terminal=true"
