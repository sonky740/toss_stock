# SPEC — tossstock (네이티브 메뉴바 앱)

**토스증권 Open API**로 보유종목 수익률과 관심종목 시세를 macOS 메뉴바에 표시하는 **SwiftUI 앱**이다. 실시간 갱신된다.

> 데이터 소스는 **토스증권 Open API**(`https://openapi.tossinvest.com`, OAuth2 Client Credentials)다. 이 문서는 네이티브 앱(`tossstock-app/`)만 다룬다.

---

## 1. 목적

- 보유종목의 **매입가 대비 누적 수익률**과 평가손익을 한눈에 본다.
- 관심종목의 **당일 등락**을 함께 본다.
- 메뉴바 한 줄을 새로고침마다 회전시켜 여러 종목을 좁은 공간에 노출한다.
- 메뉴 드롭다운에서 관심종목을 실시간으로 추가·삭제한다.

---

## 2. 인터페이스 (외부 의존)

### 2.1 인증 (OAuth2 Client Credentials)

- 토큰 발급: `POST https://openapi.tossinvest.com/oauth2/token`
  - `Content-Type: application/x-www-form-urlencoded`, 본문 `grant_type=client_credentials` + `client_id` + `client_secret`.
  - 응답: `{ access_token, token_type:"Bearer", expires_in }` (`expires_in` 기본 86400초 ≈ 24h).
- **토큰 캐싱이 필수다.** 폴링(10초)마다 재발급하면 안 된다:
  - client당 유효 토큰은 **1개** — 재발급 시 이전 토큰이 **즉시 무효화**된다.
  - `AUTH` rate limit(초당 5회)도 있다.
  - 따라서 `access_token`·만료시각·`accountSeq`를 `token.json`에 캐시하고 만료 전까지 재사용한다. 만료 **5분 전**을 캐시 만료로 두어 선제 재발급한다.
  - 요청이 **401**(만료/무효)이면 1회 강제 재발급 후 재시도한다.
- 계좌 헤더: 계좌·자산 API는 `Authorization: Bearer {token}` 외에 `X-Tossinvest-Account: {accountSeq}`가 필요하다. `accountSeq`는 `GET /api/v1/accounts` 응답의 `result[0].accountSeq`이며 토큰과 함께 캐시한다.

### 2.2 API 엔드포인트

| 엔드포인트 | 용도 | 인증 | 소비하는 필드 |
|---|---|---|---|
| `POST /oauth2/token` | access token 발급 | client_id/secret | `access_token`, `expires_in` |
| `GET /api/v1/accounts` | accountSeq 조회 | Bearer | `result[0].accountSeq`, `result[0].accountNo` |
| `GET /api/v1/holdings` | 보유종목 | Bearer + 계좌헤더 | `items[].{symbol,name,marketCountry,currency,lastPrice,profitLoss.rate,profitLoss.amount}` |
| `GET /api/v1/prices?symbols=a,b,c` | 관심종목 현재가(batch) | Bearer | `result[].{symbol,lastPrice,currency}` |
| `GET /api/v1/stocks?symbols=a,b,c` | 관심종목 종목명(batch) | Bearer | `result[].{symbol,name}` |
| `GET /api/v1/candles?symbol=X&interval=1d&count=2` | 전일종가(종목당 1회) | Bearer | `result.candles[1].closePrice` |

> **수치 필드는 모두 문자열이다** (`"72000"`, `"-0.0418"`). 합성 Decodable이 `decode(Double.self)`로 깨지므로 수동 디코딩으로 흡수한다(§4.3).
>
> **batch 격리**: `/prices`·`/stocks`는 잘못된 코드를 조용히 **누락**(HTTP 200)한다. 결과에 없는 코드만 해당 줄에서 격리 처리하면 된다 — 코드 하나가 잘못돼도 나머지 결과는 정상 반환된다.

### 2.3 설정 파일

- 관심종목: `~/.config/tossstock/symbols.tsv`
  - 형식: 한 줄당 `종목코드<TAB>별칭`. 별칭은 비어 있을 수 있다. `#`로 시작하는 줄은 주석.
  - **줄 순서 = 관심종목 표시 순서**. 드래그 재배치(§3.3)가 이 줄 순서를 다시 쓴다.
  - 파일이 없으면 **빈 목록**으로 시작한다(자동 시드 없음). 사용자가 패널(§3.4)에서 직접 추가하거나 파일을 만든다. 관심종목 0건 표시는 §3.3.
  - 입력 정제: 코드는 `영숫자·.·-`만(대문자화), 별칭은 탭·개행·파이프 제거 후 트림.
- 보유종목 순서: `~/.config/tossstock/holdings_order.txt`
  - 형식: 한 줄당 종목 심볼. 드래그 재배치(§3.2)가 현재 표시 순서를 통째로 저장한다.
  - `/holdings` 응답은 매 갱신마다 이 순서로 정렬된다. 저장에 없는(새로 매수한) 종목은 뒤에 API 순서로 붙고, 매도해 사라진 종목은 무시된다(다음 재배치 시 자연 정리).
  - **심볼 형식**: 토스 Open API 표준 코드. KR 주식은 6자리 숫자(`005930`), 한국 ETF/ETN은 영문 섞인 코드(`0190C0`), 미국은 티커(`AAPL`)·ETF(`SOXX`).
- 자격증명: `~/.config/tossstock/auth.env` (레포 밖, `chmod 600`)
  - `TOSS_CLIENT_ID` / `TOSS_CLIENT_SECRET`. 토스증권 WTS → 설정 → Open API 에서 발급. **절대 커밋 금지.**
- 토큰 캐시: `~/.config/tossstock/token.json` (`chmod 600`, 런타임 생성)
  - `{ access_token, expires_at(epoch), account_seq }`. (`expires_at`=unix초 number, `account_seq`=string — 과거 셸 플러그인과 호환되던 스키마를 유지한다.)

---

## 3. 동작 사양

### 3.1 메뉴바 타이틀 (회전)

- 후보 목록 우선순위: **보유종목 타이틀 → 관심종목 타이틀 → `📈 종목 없음`**.
- 새로고침마다 한 항목씩 회전한다. 회전 인덱스는 **인메모리**(영속 앱)이며 매 폴링 `(idx+1) % count`로 전진한다.
- 보유종목 타이틀 형식: `종목명 현재가 ±수익률%`.
- 관심종목 폴백 타이틀 형식: `별칭 현재가 ▲등락률%` (전일종가 없으면 `별칭 현재가`).
- 메뉴바 타이틀은 **모노크롬**이며, 색은 드롭다운에만 쓴다.

### 3.2 보유종목 섹션

`GET /api/v1/holdings`의 `result.items[]`를 종목별 한 줄로: `종목명  현재가  ±수익률%  평가손익`.

- **현재가**: `lastPrice`를 **종목 통화 그대로** 표시 — `currency=="USD"`면 $, 그 외 ₩. (holdings가 종목별 native 통화로 반환하므로 별도 시세 조회 불필요.)
- **수익률%**: `profitLoss.rate × 100`, 부호 표시 (`+`/`-`, flat은 부호 없음). 매입가 대비 누적.
- **평가손익**: `profitLoss.amount`를 **종목 통화 그대로** 표시 — 국내 `+16,750원`/`-1,000원`/`0원`, 미국 `+$232.00`/`-$53.47`/`$0.00`.
- **색상**: 수익률 > 0 → 빨강, < 0 → 파랑, = 0 → 회색. (토스증권 규약)

상태별 표시:
- 조회 실패(인증/오류) → `보유종목 조회 실패 (인증 확인)` (회색). stale 유지 안 함 — 섹션 통째 실패 시 해당 표시.
- 보유종목 0건(`items` 빈 배열) → `보유종목 없음` (회색).

- **드래그 재배치**: 행을 눌러 위아래로 끌어 놓으면 순서가 바뀌고 `holdings_order.txt`에 즉시 저장된다(§2.3). 놓는 순간 1회만(commit-on-end) 인메모리 행을 재정렬·영속화하므로 네트워크 재요청·10초 폴링과 충돌하지 않는다. 메뉴바 `.window`는 비활성 창이라 AppKit `NSDraggingSession`(SwiftUI `.draggable`)이 시작되지 않아 **수동 `DragGesture`(+`highPriorityGesture`)**로 구현한다 — 버튼 탭과 동일한 이벤트 스트림. macOS는 클릭-드래그로 스크롤하지 않아(휠/투핑거 사용) 스크롤과 충돌하지 않는다.

### 3.3 관심종목 섹션

각 관심종목 한 줄: `종목명  현재가  ▲등락률% (▲등락액)`.

- **현재가**: `/prices`(batch 1회)의 `lastPrice`. 통화 인식: `currency=="USD"` → $, 그 외 → ₩.
- **종목명**: `/stocks`(batch 1회)의 `name` (없으면 코드).
- **등락**: 전일종가 = `/candles?interval=1d&count=2`의 **두 번째 봉** `closePrice`(직전 세션 종가). 등락액 = `현재가 − 전일종가`, 등락률 = `등락액 / 전일종가`.
  - candles는 종목당 1회 호출하며 `MARKET_DATA_CHART`(초당 5회) 제한이 있어 **호출 간 0.25초** 간격을 둔다.
- **방향**: 등락액 > 0 → ▲ 빨강, < 0 → ▼ 파랑, = 0 → ▬ 회색 (토스증권 규약). 등락률·등락액은 절댓값 + 화살표로 표시.
- **상태별 표시**:
  - `/prices`에 코드가 없음(오타/상폐/인증) → `<코드>  조회실패 (코드/인증 확인)` (회색), 메뉴바 폴백 타이틀 `<코드> ⚠️`.
  - 전일종가 없음(신규상장 등) → `<종목명>  <현재가>  등락 데이터 없음` (회색).
  - 관심종목 0건 → `관심종목 없음` (회색).
- **드래그 재배치**: 행을 약 0.25초 길게 눌러 들어올린 뒤 위아래로 끌어 놓으면 순서가 바뀌고 `symbols.tsv` 줄 순서가 다시 쓰인다(§2.3). 놓는 순간 1회만 `watchSymbols`와 로드된 행을 재정렬·저장하므로 재요청 없이 즉시 반영된다. 구현은 보유섹션과 동일한 수동 `DragGesture`(§3.2).

### 3.4 관심종목 관리 (인라인)

드롭다운 패널 안에서 직접 추가·삭제한다(osascript 다이얼로그 아님). 헤더 줄 전체를 클릭하면 펼침/접힘.

- **추가**: 코드 입력 TextField + 별칭(선택) TextField + `추가` 버튼. 코드가 비면 버튼 비활성. 이미 등록된 코드면 무시(중복 추가 안 함).
- **삭제**: 등록 종목별 행에 `표시명 (코드)` + `X` 버튼. 클릭 시 즉시 제거.
  - 표시명은 `/stocks`의 실제 종목명을 우선하고, 별칭이 있으면 ` · 별칭`으로 병기한다. 종목명 조회 실패 시 별칭 → 코드 순으로 폴백한다. 코드는 항상 괄호로 병기한다.
- 추가·삭제 후 `symbols.tsv`를 재로딩하고 즉시 갱신한다.

### 3.5 하단 고정 항목

- `새로고침` — 즉시 1회 갱신.
- `인증 점검` — 토큰 발급/계좌 확인 + 만료시각 표시(§4.5). 결과 줄은 상시 노출하지 않고 **누른 뒤 약 6초간만** 보였다가 자동으로 숨는다.
- `마지막 갱신 시각` 표시.
- `종료`.

### 3.6 자격증명 미설정 안내

`auth.env`가 없거나 `TOSS_CLIENT_ID`/`TOSS_CLIENT_SECRET`가 비면 시세 렌더 대신 설정 안내 화면(`🔐 Toss API 설정 필요`)을 표시한다. 폴링은 보류한다(무의미한 401 방지).

### 3.7 표시 포맷 (관측 가능 동작)

| 종류 | 예시 |
|---|---|
| 원화 현재가 | `₩351,500` |
| 달러 현재가 | `$1,234.05` |
| 평가손익(원화) | `+16,750원` / `-1,000원` / `0원` |
| 평가손익(달러) | `+$232.00` / `-$53.47` / `$0.00` |
| 등락 | `▲2.34%` / `▼1.05%` / `▬0.00%` |

---

## 4. 아키텍처 & 구현

### 4.1 존재 이유 (MenuBarExtra `.window`)

NSMenu 드롭다운은 펼치면 런루프가 `.eventTracking` 모드로 전환돼 타이머·redraw가 멈춘다 → 펼친 채로는 시세가 갱신되지 않는다. `MenuBarExtra` + `.menuBarExtraStyle(.window)`는 NSMenu가 아닌 **플로팅 윈도우**라 메인 런루프 default 모드를 유지 → **펼친 채로도 갱신**된다.

### 4.2 구조

- **UI**: SwiftUI `MenuBarExtra(.window)`. `LSUIElement=true` + `setActivationPolicy(.accessory)`로 Dock 미표시. 모노크롬 회전 타이틀, 컬러는 드롭다운에만.
- **폴링**: `Task { while: Task.sleep(10초) }`. RunLoop Timer 금지(`.eventTracking` 진입 시 멈춤). holdings·watch는 rate 그룹이 달라 `async let`로 off-actor 병렬.
- **레이어**: `PopupView`(뷰) → `StockModel`(@MainActor @Observable, 폴링·회전 소유) → `TossService`/`TossAPI`(service) → `URLSession`(I/O). 토큰은 `TossAuth`(actor `TokenStore`)에 위임.
- **빌드**: SwiftPM `executableTarget`(외부 의존성 0, Swift 6 모드). `Packaging/build.sh` → `.app` 조립 + ad-hoc codesign. `--dump` 인자로 GUI 없이 데이터 레이어 헤드리스 검증.
- **App Sandbox OFF**: 토큰 저장(§4.4)이 `~/.config/tossstock` 접근을 요구 → 미샌드박스(entitlements 파일 없음). 미샌드박스 앱은 `network.client` 없이 네트워크 가능.
- **레이아웃 주의**: `ScrollView`는 고유 높이가 0이라 self-sizing 윈도우(`MenuBarExtra .window`)에서 붕괴한다 → 콘텐츠 실측 높이로 ScrollView 높이를 고정(최대 520, 초과 시 스크롤).

### 4.3 데이터 디코딩

- 모든 금액/수량 JSON 필드는 **문자열** → 합성 Decodable이 `decode(Double.self)`로 깨진다. 금액 보유 DTO마다 수동 `init(from:)` + `decimal()` 헬퍼(문자열·숫자·null·키누락·빈문자열 전부 nil/값, 크래시 0).
- `currency`는 **관대한 enum**(unknown 값 흡수). 중첩 디코드라 throw하면 holdings 통째 블랭크가 되기 때문.
- candles: `candles[0]`=당일, `candles[1]`=전일종가. `count < 2` 가드(신규상장 인덱스 크래시 방지).

### 4.4 토큰 저장

- `~/.config/tossstock/token.json` 캐시(atomic write + chmod 600).
- `actor TokenStore`: 캐시 재사용 → 만료 5분 전 선제 재발급 → 동시 만료 감지 시 **재발급 1회**(in-flight 공유 — `refreshTask`를 `await` 이전에 동기 세팅) → 401 시 단일 재발급.
- 401 시 곧장 재발급하지 않고 `token.json`을 **디스크에서 재확인**(`reloadOrMint`)한다 — 같은 `client_id`를 쓰는 다른 클라이언트가 이미 새 토큰을 써뒀으면 채택. 플러그인 제거로 단일 클라이언트가 됐으나, 다른 도구와 `client_id`를 공유할 가능성에 대비한 방어로 유지한다.

### 4.5 인증 점검 (429 캐시 폴백)

- "인증 점검" → `GET /api/v1/accounts`로 계좌번호·seq 확인 + 토큰 만료시각 표시.
- `/accounts`는 rate limit이 **분당 1회 수준**(`X-RateLimit-Limit: 1` 실측)이라 직전에 호출됐으면 429가 날 수 있다 → 실패로 보지 않고 **캐시된 seq·만료시각**으로 폴백 표시.
- 폴링은 `accountSeq`를 토큰과 함께 캐시해 `/accounts`를 호출하지 않으므로 영향 없다.
- 결과 표시는 **전이적(transient)**이다 — 결과가 정해지면 약 6초 후 `authDismissTask`가 표시를 `.none`으로 되돌린다. 점검을 다시 누르면 이전 숨김 타이머를 취소한다.

### 4.6 파일 구성

```
tossstock-app/
├── Package.swift                  SwiftPM executableTarget, 의존성 0, Swift 6 모드
├── Sources/TossStock/
│   ├── TossStockApp.swift         @main 진입(--dump 분기) + MenuBarExtra(.window) Scene + AppDelegate
│   ├── StockModel.swift           @MainActor @Observable. 폴링 루프·회전·인증상태
│   ├── PopupView.swift            드롭다운(보유/관심/관리/하단/설정안내) — 다크 'Color pill' 디자인
│   ├── TossService.swift          도메인 메서드(positionRows/watchRows/authStatus) + Dump
│   ├── TossAPI.swift              URLSession 요청계층(Bearer·계좌헤더·401/429 재시도) + TossHTTP
│   ├── TossAuth.swift             actor TokenStore(토큰 캐시·in-flight·디스크 재확인) + ConfigPaths
│   ├── Models.swift               DTO(수동 init + decimal) + 표시 Row 타입
│   ├── Watchlist.swift            symbols.tsv 읽기/추가/삭제/순서저장 + 정제
│   ├── HoldingsOrder.swift        holdings_order.txt 읽기/쓰기 + 저장 순서로 정렬(드래그 재배치)
│   └── Format.swift               ₩/$/원/달러·등락·화살표 포맷(§3.7)
└── Packaging/
    ├── Info.plist                 LSUIElement, 번들 식별자, 앱 아이콘(CFBundleIconFile)
    ├── build.sh                   swift build → .app 조립(아이콘 포함) → ad-hoc codesign
    ├── deploy.sh                  재빌드 → 실행 인스턴스 종료 → /Applications 제자리 교체 → 재실행
    ├── make-icon.swift            AppIcon.iconset/.icns 생성 스크립트
    └── AppIcon.icns               앱 아이콘(make-icon.swift로 재생성, 커밋 대상)
```

---

## 5. 제약 조건

- **플랫폼**: macOS 14+ / Swift 6 툴체인. SwiftPM(외부 의존성 0).
- **인증 필수**: 유효한 토스 Open API 자격증명(`auth.env`)이 있어야 한다. 없으면 설정 안내 화면을 표시한다.
- **토큰 단일성**: client당 유효 토큰 1개 — 재발급 시 이전 토큰 즉시 무효화. **같은 `client_id`를 쓰는 다른 도구**가 동시에 토큰을 발급하면 서로 무효화한다. 그 경우 한 번의 새로고침이 일시적으로 실패로 렌더될 수 있으나 다음 새로고침에서 자동 복구된다. → 구조적 해법은 **도구별로 다른 `client_id` 발급**이다.
- **통화 표시 (핵심 비자명 동작)**: holdings는 종목별 금액을 **native 통화**로만 반환한다(미국 종목의 원화 환산값은 종목별로 제공되지 않고 전체 합산에만 존재). 따라서 미국 보유종목의 현재가·평가손익은 **달러로 표시**한다.
- **관심종목 등락 = candles 의존**: 등락 계산에 종목당 일봉 1회 호출이 필요하다. 관심종목 N개면 새로고침마다 candles N회(+0.25초 간격 throttle)가 발생해 렌더에 약 `N×0.25초`가 더 든다. `MARKET_DATA_CHART`(초당 5회) 제한 때문이다.
- **새로고침 주기**: 폴링 간격 10초(코드 상수). `RunLoop` Timer가 아닌 `Task.sleep`이라 팝업을 펼친 채로도 동작한다.
