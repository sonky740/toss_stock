# SPEC — tossstock.10s.sh

SwiftBar 플러그인. **토스증권 Open API**로 보유종목 수익률과 관심종목 시세를 macOS 메뉴바에 표시한다.

> 데이터 소스는 **토스증권 Open API**(`https://openapi.tossinvest.com`, OAuth2 Client Credentials)다.

---

## 1. 목적

- 보유종목의 **매입가 대비 누적 수익률**과 평가손익을 한눈에 본다.
- 관심종목의 **당일 등락**을 함께 본다.
- 메뉴바 한 줄을 새로고침마다 회전시켜 여러 종목을 좁은 공간에 노출한다.
- 메뉴 드롭다운에서 관심종목을 실시간으로 추가·삭제한다.

---

## 2. 인터페이스

### 2.1 SwiftBar 출력 계약 (가장 중요)

플러그인은 stdout으로 SwiftBar 포맷을 출력한다. 라인 위치가 곧 의미다.

| 출력 위치 | 의미 |
|---|---|
| 첫 번째 라인 | 메뉴바에 표시되는 **단일 회전 타이틀** |
| `---` | 구분선 (메뉴바 ↔ 드롭다운, 섹션 ↔ 섹션) |
| 이후 라인 | 드롭다운 항목 |

라인 파라미터(`| key=value`):

- `| color=green|red|gray` — 항목 텍스트 색.
- `| refresh=true` — 클릭 시 플러그인 재실행.
- `| bash='<경로>' param1='<arg>' [param2='<arg>'] terminal=false refresh=true` — 클릭 시 외부 명령 실행. 이 플러그인은 **자기 자신**(`$SELF`)을 재호출해 액션을 수행한다.

> 이 표의 라인 위치·파라미터는 동작 계약이다. `color=`/`param1=`/`refresh=` 등을 바꾸는 변경은 본 SPEC 위반 여부를 검토해야 한다.

### 2.2 파일명 = 새로고침 주기

파일명 `tossstock.10s.sh`의 `10s`는 SwiftBar **자동 새로고침 주기(10초)**를 의미한다. 파일명을 바꾸면 주기가 바뀐다 (예: `.30s.`, `.1m.`). 단순 rename이 아니라 인터페이스 변경이다.

### 2.3 자기 재호출 액션

클릭 액션은 렌더링 대신 동작만 수행하고 종료한다.

| 인자 | 동작 |
|---|---|
| `add` | 관심종목 추가 다이얼로그 표시 |
| `remove <code>` | 관심종목에서 해당 코드 행 제거 |
| `authstatus` | 터미널에서 인증 상태(토큰·계좌) 점검 |
| (인자 없음) | 메뉴 전체 렌더링 |

`$SELF` 경로 해석: 환경변수 `SWIFTBAR_PLUGIN_PATH`가 있으면 그것을, 없으면 스크립트 자신의 절대 경로를 사용한다.

### 2.4 인증 (OAuth2 Client Credentials)

- 토큰 발급: `POST https://openapi.tossinvest.com/oauth2/token`
  - `Content-Type: application/x-www-form-urlencoded`, 본문 `grant_type=client_credentials` + `client_id` + `client_secret`.
  - 응답: `{ access_token, token_type:"Bearer", expires_in }` (`expires_in` 기본 86400초 ≈ 24h).
- **토큰 캐싱이 필수다.** SwiftBar는 10초마다 재실행되므로 매번 재발급하면 안 된다:
  - client당 유효 토큰은 **1개** — 재발급 시 이전 토큰이 **즉시 무효화**된다.
  - `AUTH` rate limit(초당 5회)도 있다.
  - 따라서 `access_token`·만료시각·`accountSeq`를 `token.json`에 캐시하고 만료 전까지 재사용한다. 만료 **5분 전**을 캐시 만료로 두어 선제 재발급한다.
  - 요청이 **401**(만료/무효)이면 1회 강제 재발급 후 재시도한다.
- 계좌 헤더: 계좌·자산 API는 `Authorization: Bearer {token}` 외에 `X-Tossinvest-Account: {accountSeq}`가 필요하다. `accountSeq`는 `GET /api/v1/accounts` 응답의 `result[0].accountSeq`이며 토큰과 함께 캐시한다.

### 2.5 외부 의존 (API 엔드포인트 · 명령)

| 엔드포인트 | 용도 | 인증 | 소비하는 필드 |
|---|---|---|---|
| `POST /oauth2/token` | access token 발급 | client_id/secret | `access_token`, `expires_in` |
| `GET /api/v1/accounts` | accountSeq 조회 | Bearer | `result[0].accountSeq`, `result[0].accountNo` |
| `GET /api/v1/holdings` | 보유종목 | Bearer + 계좌헤더 | `items[].{symbol,name,marketCountry,currency,lastPrice,profitLoss.rate,profitLoss.amount}` |
| `GET /api/v1/prices?symbols=a,b,c` | 관심종목 현재가(batch) | Bearer | `result[].{symbol,lastPrice,currency}` |
| `GET /api/v1/stocks?symbols=a,b,c` | 관심종목 종목명(batch) | Bearer | `result[].{symbol,name}` |
| `GET /api/v1/candles?symbol=X&interval=1d&count=2` | 전일종가(종목당 1회) | Bearer | `result.candles[1].closePrice` |

| 명령 | 용도 |
|---|---|
| `curl` | HTTP 호출 (시스템 기본 `/usr/bin/curl`) |
| `jq` | JSON 파싱 (`/opt/homebrew/bin/jq`) |

> **수치 필드는 모두 문자열이다** (`"72000"`, `"-0.0418"`). jq/awk 비교·산술 시 `tonumber` 또는 awk 부동소수 계산을 쓴다.
>
> **batch 격리**: `/prices`·`/stocks`는 잘못된 코드를 조용히 **누락**(HTTP 200)한다. 그래서 결과에 없는 코드만 해당 줄에서 격리 처리하면 된다 — 코드 하나가 잘못돼도 나머지 결과는 정상 반환된다.

### 2.6 설정 파일

- 관심종목: `~/.config/tossstock/symbols.tsv`
  - 형식: 한 줄당 `종목코드<TAB>별칭`. 별칭은 비어 있을 수 있다. `#`로 시작하는 줄은 주석.
  - 최초 실행 시 자동 시드: `0190C0\t현피AI`, `0167A0\tSOL탑`.
  - 입력 정제: 코드는 `영숫자·.·-`만(대문자화), 별칭은 탭·개행·파이프 제거 후 트림.
  - **심볼 형식**: 토스 Open API 표준 코드. KR 주식은 6자리 숫자(`005930`), 한국 ETF/ETN은 영문 섞인 코드(`0190C0`), 미국은 티커(`AAPL`)·ETF(`SOXX`).
- 자격증명: `~/.config/tossstock/auth.env` (레포 밖, `chmod 600`)
  - `TOSS_CLIENT_ID` / `TOSS_CLIENT_SECRET`. 토스증권 WTS → 설정 → Open API 에서 발급. **절대 커밋 금지.**
- 토큰 캐시: `~/.config/tossstock/token.json` (`chmod 600`, 런타임 생성)
  - `{ access_token, expires_at(epoch), account_seq }`.

---

## 3. 동작 사양

### 3.1 메뉴바 타이틀 (회전)

- 후보 목록 우선순위: **보유종목 타이틀 → 관심종목 타이틀 → `📈 종목 없음`**.
- 새로고침마다 한 항목씩 회전한다. 인덱스는 `/tmp/tossstock_rotate.idx`에 저장하며 매 실행 `(idx+1) % count`로 전진한다.
- 인덱스 파일이 손상/비정상이면 0으로 리셋한다 (`10#` 사용으로 `08`/`09` 8진수 오류 방지).
- 보유종목 타이틀 형식: `종목명 현재가 ±수익률%`.
- 관심종목 폴백 타이틀 형식: `별칭 현재가 ▲등락률%` (전일종가 없으면 `별칭 현재가`).

### 3.2 보유종목 섹션 (`📊 내 보유종목 비교 (매입가 대비)`)

`GET /api/v1/holdings`의 `result.items[]`를 종목별 한 줄로: `종목명  현재가  ±수익률%  평가손익`.

- **현재가**: `lastPrice`를 **종목 통화 그대로** 표시 — `currency=="USD"`면 $, 그 외 ₩. (holdings가 종목별 native 통화로 반환하므로 별도 시세 조회 불필요.)
- **수익률%**: `profitLoss.rate × 100`, 부호 표시 (`+`/`-`, flat은 부호 없음). 매입가 대비 누적.
- **평가손익**: `profitLoss.amount`를 **종목 통화 그대로** 표시 — 국내 `+16,750원`/`-1,000원`/`0원`, 미국 `+$232.00`/`-$53.47`/`$0.00`.
- **색상**: 수익률 > 0 → green, < 0 → red, = 0 → gray.

상태별 출력:
- 조회 실패(인증/오류) → `보유종목 조회 실패 (인증 확인) | color=gray`
- 보유종목 0건(`items` 빈 배열) → `보유종목 없음 | color=gray`

### 3.3 관심종목 섹션 (`⭐ 관심종목 (당일 등락)`)

각 관심종목 한 줄: `종목명  현재가  ▲등락률% (▲등락액)`.

- **현재가**: `/prices`(batch 1회)의 `lastPrice`. 통화 인식: `currency=="USD"` → $, 그 외 → ₩.
- **종목명**: `/stocks`(batch 1회)의 `name` (없으면 코드).
- **등락**: 전일종가 = `/candles?interval=1d&count=2`의 **두 번째 봉** `closePrice`(직전 세션 종가). 등락액 = `현재가 − 전일종가`, 등락률 = `등락액 / 전일종가`.
  - candles는 종목당 1회 호출하며 `MARKET_DATA_CHART`(초당 5회) 제한이 있어 **호출 간 0.25초** 간격을 둔다.
- **방향**: 등락액 > 0 → ▲ green, < 0 → ▼ red, = 0 → ▬ gray. 등락률·등락액은 절댓값 + 화살표로 표시.
- **상태별 출력**:
  - `/prices`에 코드가 없음(오타/상폐/인증) → `<코드>  조회실패 (코드/인증 확인) | color=gray`, 메뉴바 폴백 타이틀 `<코드> ⚠️`.
  - 전일종가 없음(신규상장 등) → `<종목명>  <현재가>  (등락 데이터 없음) | color=gray`.
  - 관심종목 0건 → `관심종목 없음 | color=gray`.

### 3.4 관심종목 관리

- `➕ 종목 추가…` 클릭 → `add` 재호출 → osascript 다이얼로그 2개(코드 입력 → 별칭 입력). 코드가 비면 취소. 이미 등록된 코드면 알림 후 종료.
- `➖ 종목 삭제` 하위에 등록 종목별 `❌ 종목명 · 별칭 (코드)` 항목 → 클릭 시 `remove <code>` 재호출로 해당 행 삭제.
  - 표시명은 `/stocks`의 실제 종목명을 우선하고, 별칭이 있으면 ` · 별칭`으로 병기한다. 종목명 조회 실패 시 별칭 → 코드 순으로 폴백한다. 코드는 항상 괄호로 병기한다.
- 두 액션 모두 `terminal=false refresh=true`로 동작 후 메뉴를 즉시 갱신한다.

### 3.5 하단 고정 항목

- `🔄 새로고침 | refresh=true`
- `인증 상태 확인` → 터미널에서 `$SELF authstatus` 실행 (토큰 발급/계좌 확인, 만료시각 표시).

### 3.6 자격증명 미설정 안내

`auth.env`가 없거나 `TOSS_CLIENT_ID`/`TOSS_CLIENT_SECRET`가 비면 시세 렌더 대신 설정 안내 메뉴(`🔐 Toss API 설정 필요`)를 출력하고 종료한다.

### 3.7 표시 포맷 (관측 가능 동작)

| 종류 | 예시 |
|---|---|
| 원화 현재가 | `₩351,500` |
| 달러 현재가 | `$1,234.05` |
| 평가손익(원화) | `+16,750원` / `-1,000원` / `0원` |
| 평가손익(달러) | `+$232.00` / `-$53.47` / `$0.00` |
| 등락 | `▲2.34%` / `▼1.05%` / `▬0.00%` |

---

## 4. 제약 조건

- **플랫폼**: macOS + SwiftBar 전용. osascript(AppleScript) 다이얼로그에 의존.
- **인증 필수**: 유효한 토스 Open API 자격증명(`auth.env`)이 있어야 한다. 없으면 설정 안내 메뉴를 표시한다.
- **하드코딩된 PATH**: 8번 줄에서 `jq`는 `/opt/homebrew/bin`, `curl`은 시스템 `/usr/bin`을 가정한다. jq 설치 위치가 다르면 PATH 수정 필요.
- **토큰 단일성**: client당 유효 토큰 1개 — 재발급 시 이전 토큰 즉시 무효화. **같은 `client_id`를 쓰는 다른 도구**(별도 앱 등)가 동시에 토큰을 발급하면 서로 무효화한다. 그 경우 한 번의 새로고침이 일시적으로 실패로 렌더될 수 있으나 다음 새로고침에서 자동 복구된다. → 구조적 해법은 retry 가 아니라 **도구별로 다른 `client_id` 발급**이다.
- **통화 표시 (핵심 비자명 동작)**: holdings는 종목별 금액을 **native 통화**로만 반환한다(미국 종목의 원화 환산값은 종목별로 제공되지 않고 전체 합산에만 존재). 따라서 미국 보유종목의 현재가·평가손익은 **달러로 표시**한다.
- **관심종목 등락 = candles 의존**: 등락 계산에 종목당 일봉 1회 호출이 필요하다. 관심종목 N개면 새로고침마다 candles N회(+0.25초 간격 throttle)가 발생해 렌더에 약 `N×0.25초`가 더 든다. `MARKET_DATA_CHART`(초당 5회) 제한 때문이다.
- **회전 상태 전역성**: `/tmp/tossstock_rotate.idx`는 단일 파일이라 동일 플러그인 다중 인스턴스를 가정하지 않는다.
- **새로고침 주기**: 파일명(`10s`)에 종속. 코드로 제어하지 않는다.
