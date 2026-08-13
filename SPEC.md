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
| `GET /api/v1/stocks/all?market=M` | 종목 검색용 유니버스(마켓당 1회, 하루 1회) | Bearer | `result[].{symbol,name}` |
| `GET /api/v1/candles?symbol=<clock>&interval=1d&count=1` | 시장 세션일 확인(시장당 60초 캐시) | Bearer | `result.candles[0].timestamp` |
| `GET /api/v1/candles?symbol=X&interval=1d&count=2` | 직전 거래일 식별(종목당 세션당 1회) | Bearer | `result.candles[0..1].{timestamp,closePrice}` |
| `GET /api/v1/candles?symbol=X&interval=1m&count=1&before=<거래일>T06:32:00Z` | 국내 전일 정규장 종가(종목당 세션당 1회) | Bearer | `result.candles[0].closePrice` |

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
- 종목 검색 유니버스: `~/.config/tossstock/universe.json` (런타임 생성, 실측 931KB)
  - 형식: `{ fetchedOn: "yyyy-MM-dd"(KST), stocks: [{symbol, name, market}] }`. 실측 15,176종목.
  - `fetchedOn`이 오늘이 아니면 폐기하고 다시 수집한다. **여기서만 벽시계 날짜 키가 맞다** — 전일종가 캐시가 날짜 키를 금지하는 이유(§3.3)는 세션 롤이 09:00 KST여서인데, 유니버스는 일 배치 데이터라 갱신이 하루 늦어도 신규 상장 종목이 하루 늦게 검색될 뿐이다.
  - 마켓 7개 중 하나라도 수집에 실패하면 저장하지 않는다. 부분 목록을 캐시하면 빠진 종목이 하루 내내 안 잡힌다.
- 토큰 캐시: `~/.config/tossstock/token.json` (`chmod 600`, 런타임 생성)
  - `{ access_token, expires_at(epoch), account_seq }`. (`expires_at`=unix초 number, `account_seq`=string — 과거 셸 플러그인과 호환되던 스키마를 유지한다.)

---

## 3. 동작 사양

### 3.1 메뉴바 타이틀 (회전)

- 후보 목록 우선순위: **보유종목 타이틀 → 관심종목 타이틀 → `📈 종목 없음`**.
- 새로고침마다 한 항목씩 회전한다. 회전 인덱스는 **인메모리**(영속 앱)이며 매 폴링 `(idx+1) % count`로 전진한다.
- 보유종목 타이틀 형식: `종목명 현재가 ±수익률%`. 단, 해당 종목 코드가 관심종목(`symbols.tsv`)에 별칭으로 등록돼 있으면 **종목명 대신 별칭**을 쓴다.
- 관심종목 폴백 타이틀 형식: `별칭 현재가 ▲등락률%` (별칭 없으면 종목명 > 코드, 전일종가 없으면 `별칭 현재가`).
- 메뉴바 타이틀은 **모노크롬**이며, 색은 드롭다운에만 쓴다.

### 3.2 보유종목 섹션

`GET /api/v1/holdings`의 `result.items[]`를 종목별 한 줄로: `표시명  현재가  ±수익률%  평가손익`.

- **표시명**: 종목명. 단, 해당 코드가 관심종목(`symbols.tsv`)에 별칭으로 등록돼 있으면 `종목명 · 별칭`으로 병기한다(§3.3 관심 표시명과 동일 정책). 메뉴바 타이틀은 종목명 대신 별칭만 쓴다(§3.1).

- **현재가**: `lastPrice`를 **종목 통화 그대로** 표시 — `currency=="USD"`면 $, 그 외 ₩. (holdings가 종목별 native 통화로 반환하므로 별도 시세 조회 불필요.)
- **수익률%**: `profitLoss.rate × 100`, 부호 표시 (`+`/`-`, flat은 부호 없음). 매입가 대비 누적.
- **평가손익**: `profitLoss.amount`를 **종목 통화 그대로** 표시 — 국내 `+16,750원`/`-1,000원`/`0원`, 미국 `+$232.00`/`-$53.47`/`$0.00`.
- **색상**: 수익률 > 0 → 빨강, < 0 → 파랑, = 0 → 회색. (토스증권 규약)

상태별 표시:
- 조회 실패(인증/오류) → `보유종목 조회 실패 (인증 확인)` (회색). stale 유지 안 함 — 섹션 통째 실패 시 해당 표시.
- 보유종목 0건(`items` 빈 배열) → `보유종목 없음` (회색).

- **행 클릭(종목 페이지 열기)**: 행 본문을 클릭하면 기본 브라우저로 토스증권 종목 페이지를 연다.
  - **한국 종목**: `https://www.tossinvest.com/stocks/A{종목코드}`로 직접 딥링크(KRX 표준코드 `A` 접두사, 예 `005930`→`A005930`, `0190C0`→`A0190C0`).
  - **미국 종목**: 토스 웹 URL은 내부 productCode(`US…`/`NAS0…`/`AMX0…`, 상장일+순번 기반)를 쓰는데 Open API가 **티커만 주고 이 코드를 제공하지 않아** 정확한 딥링크가 불가능하다 → **토스 홈(`https://www.tossinvest.com/`)으로 이동**하고, 마우스 호버 시 툴팁으로 상세 페이지 미지원을 안내한다.
  - **KR/US 판별**: `currency=="USD"`면 미국.
  - 좌측 드래그 핸들(아래) 영역은 드래그가 우선 소비하고 클릭은 행 본문에만 걸려 재배치와 충돌하지 않는다.
- **드래그 재배치**: 행을 눌러 위아래로 끌어 놓으면 순서가 바뀌고 `holdings_order.txt`에 즉시 저장된다(§2.3). 놓는 순간 1회만(commit-on-end) 인메모리 행을 재정렬·영속화하므로 네트워크 재요청·10초 폴링과 충돌하지 않는다. 메뉴바 `.window`는 비활성 창이라 AppKit `NSDraggingSession`(SwiftUI `.draggable`)이 시작되지 않아 **수동 `DragGesture`(+`highPriorityGesture`)**로 구현한다 — 버튼 탭과 동일한 이벤트 스트림. macOS는 클릭-드래그로 스크롤하지 않아(휠/투핑거 사용) 스크롤과 충돌하지 않는다.
  - **가장자리 자동 스크롤**: 목록이 뷰포트(최대 520px)를 넘칠 때, 드래그 중 포인터를 상/하단 가장자리(≈44px 밴드, 깊이 비례 속도)로 가져가면 목록이 자동으로 스크롤된다. 포인터가 멈춰 있어도 진행해야 하므로(→ `onChanged`가 안 불림) 독립 `Task.sleep` 루프가 몬다(Timer 금지, §4.1과 동일 이유). 스크롤 델타 `S`(= `NSScrollView.contentView.bounds.origin.y` 변화량)를 `DragGesture(.global)`의 translation 에 실시간 합산해(`유효 = base + S`) 떠 있는 행 위치와 드롭 타깃 인덱스를 정합한다 — 그래서 스크롤 중 재배치 가드(`scrollDisabled`)가 불필요하다. `NSScrollView` 참조는 콘텐츠 서브트리에 심은 뷰의 `enclosingScrollView`(정식 AppKit API)로 얻는다.

### 3.3 관심종목 섹션

각 관심종목 한 줄: `표시명  현재가  ▲등락률% (▲등락액)`.

- **현재가**: `/prices`(batch 1회)의 `lastPrice`. 통화 인식: `currency=="USD"` → $, 그 외 → ₩.
- **표시명**: `/stocks`(batch 1회)의 `name`에 별칭이 있으면 `종목명 · 별칭`으로 병기한다. 별칭이 없으면 종목명, 종목명 조회 실패 시 별칭 > 코드 순으로 폴백한다(§3.4 관리 표시명과 동일 규칙). 단, 조회실패 행은 코드만 표시한다(아래).
- **등락**: 등락액 = `현재가 − 전일종가`, 등락률 = `등락액 / 전일종가`. 전일종가는 **토스 앱·웹과 같은 기준가(직전 거래일 정규장 종가)** 를 쓴다 — 통화별로 구하는 경로가 다르다.
  - **국내(KRW)**: 일봉 종가를 쓸 수 없다. 국내 일봉 `closePrice`는 **NXT 시간외(~20:00) 마감가**여서 정규장 기준가와 어긋난다(실측 005930 2026-07-30: 일봉 213,500 vs 정규장 207,000 → 등락률이 3.8%p 틀어졌다). 그래서 ① `interval=1d&count=2`의 기준 봉(아래 날짜 비교 규칙) `timestamp`로 직전 거래일을 얻고(주말·휴일 자동 처리) ② 그 거래일의 `interval=1m&count=1&before=<거래일>T06:32:00Z`(= 15:32 KST 직전 최신 1분봉 = 대개 15:31 동시호가 체결)의 `closePrice`를 기준가로 쓴다. NXT 시간외 유동성이 없는 종목(ETF 등)은 두 값이 같다. ②의 정규장 봉이 **아예 없으면**(거래정지 등) 일봉 종가로 내려앉되(시간외만큼 어긋나지만 유일한 대안) 그 값은 캐시한다. 반면 ②의 **조회가 실패**했을 뿐이면 캐시하지 않고 다음 폴링에 재시도한다 — 캐시하면 시간외 기준가(최대 3.8%p 오차)가 세션 내내 굳는다.
  - **미국(USD·기타)**: 일봉 `closePrice`가 정규장 종가다(애프터마켓 미포함) → 그대로 쓴다. `/price-limits`도 미국은 `null`이라 역산 경로가 없다.
  - **분자는 정규장 종가가 아니라 `/prices`의 실시간 `lastPrice`** 다. 시간외에는 토스 앱도 같은 조합(시간외 실시간가 ÷ 정규장 기준가)을 보여준다.
  - **기준 봉은 인덱스가 아니라 날짜로 고른다.** 일봉은 체결이 있어야 생기므로 현 세션에 아직 체결이 없는 종목은 `candles[0]`이 이미 직전 거래일이다 → `candles[0].timestamp`가 세션일이면 `candles[1]`, 아니면 `candles[0]`이 기준 봉이다. 무조건 `candles[1]`을 쓰면 09:05에 미거래인 종목이 **두 세션 전** 종가를 세션 내내 분모로 물고 간다.
  - **캐시 키는 벽시계 날짜가 아니라 시장 세션일**이다. 전일종가가 갈리는 경계는 자정이 아니라 **09:00 KST**(국내 개장 / 미국 오버나이트 개장 = 20:00 ET)여서, KST 날짜를 키로 쓰면 00:00~09:00 KST에 채운 값이 그 날 세션 내내 남는다(실측 2026-08-04: NVDA 기준가가 200.75로 굳어 정답 206.64 대비 +2.9%p 어긋남 — 앱을 껐다 켜야 맞았다).
  - 세션일은 **시장 시계 종목**(국내 `005930` / 미국 `SPY`)의 최신 일봉 날짜로 확인하고, 시장별로 **60초 캐시**한다(하루 두 번 바뀌는 값을 10초 폴링마다 다시 물을 이유가 없다 — 캐시 전에는 국내·미국 관심종목이 섞이면 분당 12콜이 여기로만 나갔다). TTL 은 **경과시간**이어야 한다 — 달력 날짜를 키로 쓰면 바로 아래 전일종가 캐시가 피해 간 09:00 KST 롤 문제가 그대로 돌아온다. 조회 실패는 캐시하지 않는다.
    - **알려진 한계(≤60초, 자가치유)**: 세션 롤 직후 최대 60초는 세션일이 한 세션 뒤처질 수 있다. 그 창에서 이미 체결된 종목은 `latest.day != sessionDay`(위 규칙)로 판정돼 **당일 봉**이 기준가가 되고, 그 값이 낡은 세션일 키로 캐시된다. 다만 TTL 만료 후 세션일이 갱신되면 캐시 키가 달라져 그 항목은 고아가 되고 재조회된다 — 앱 재시작 없이 다음 폴링에서 복구된다. TTL 이 없던 시절에도 같은 창이 있었으나(시계 조회와 종목 조회 사이 ~0.25초) 60초로 넓어진 것이다. **벽시계로 롤 시각을 계산하면 안 된다** — 미국 일봉 stamp 는 00:00 ET(`T13:00+09:00`)인데 실제 롤은 그보다 4시간 이른 20:00 ET다. 오버나이트 세션 체결이 **다음 거래일 라벨**의 봉으로 들어가기 때문이다(실측 2026-08-05 09:06 KST = 08-04 20:06 ET에 NVDA 최신 봉 `2026-08-05`, 거래량 14,001). 데이터에서 끌어오면 이 어긋남은 물론 DST·휴장·반휴장까지 계산이 필요 없고, 비거래일엔 새 봉이 없어 직전 거래일 등락이 그대로 유지된다.
  - 시장 시계 조회가 실패하면 그 폴링은 `candles[1]`로 계산하되 **캐시하지 않는다**(틀린 키로 저장하면 세션 내내 굳는다).
  - 전일종가는 세션 안에서 불변이라 **종목당 세션당 1회만** 조회한다(`PrevCloseStore`). 캐시는 관심종목 섹션과 종목 검색(§3.4)이 공유한다 — 같은 종목이 두 곳에서 다른 등락률을 보이지 않아야 한다.
  - candles 호출 사이에 **0.25초** 간격을 둔다. `MARKET_DATA_CHART` 실제 한도는 초당 20회(응답 헤더 `X-RateLimit-Limit` 실측)이며 0.25초는 그보다 보수적인 값이다.
  - 간격 유지는 **슬롯 예약**으로 한다(`PrevCloseStore.reserveCandleSlot()`). 예약은 actor 안에서 중단점 없이 원자적으로 하고 대기는 호출자가 한다 — actor 메서드 안에서 `await Task.sleep`을 하면 그 중단점에서 격리가 풀려 다른 호출자가 같은 슬롯을 받는다(실측: 동시 호출자 2에서 호출 간격 11개 중 5개가 0.000초). 폴링과 검색이 동시에 도는 이상 이 예약이 계약이다.
- **방향**: 등락액 > 0 → ▲ 빨강, < 0 → ▼ 파랑, = 0 → ▬ 회색 (토스증권 규약). 등락률·등락액은 절댓값 + 화살표로 표시.
- **상태별 표시**:
  - `/prices`에 코드가 없음(오타/상폐/인증) → `<코드>  조회실패 (코드/인증 확인)` (회색), 메뉴바 폴백 타이틀 `<코드> ⚠️`.
  - 전일종가 없음(신규상장 등) → `<종목명>  <현재가>  등락 데이터 없음` (회색).
  - 관심종목 0건 → `관심종목 없음` (회색).
- **행 클릭(종목 페이지 열기)**: §3.2와 동일하다(한국 딥링크 / 미국 홈+툴팁, `currency=="USD"` 판별). 단 **조회실패 행**은 종목명·통화 조회가 안 돼 `currency`가 KRW로 강제 채워지므로, 이 경우에만 **종목코드 첫 글자**로 판별한다(숫자면 한국, 아니면 미국).
- **드래그 재배치**: 행을 약 0.25초 길게 눌러 들어올린 뒤 위아래로 끌어 놓으면 순서가 바뀌고 `symbols.tsv` 줄 순서가 다시 쓰인다(§2.3). 놓는 순간 1회만 `watchSymbols`와 로드된 행을 재정렬·저장하므로 재요청 없이 즉시 반영된다. 구현은 보유섹션과 동일한 수동 `DragGesture`(§3.2).

### 3.4 관심종목 관리 (인라인)

드롭다운 패널 안에서 직접 검색·추가·수정·삭제한다(osascript 다이얼로그 아님). 헤더 줄 전체를 클릭하면 펼침/접힘.

- **검색**: 관심종목을 추가하는 **유일한 경로**다. 종목코드를 몰라도 이름으로 찾아 등록한다. 코드를 직접 입력하는 별도 줄은 없다 — 검색이 심볼도 매칭하므로 `005930`·`AAPL`·`0190C0`을 그대로 입력하면 같은 결과가 나온다.
  - **유니버스**: 토스 Open API에 검색 엔드포인트가 없어 `/stocks/all`로 마켓 7개(`KOSPI·KOSDAQ·NYSE·NASDAQ·AMEX·KR_ETC·US_ETC`) 전체 목록을 받아 로컬에서 찾는다. `STOCK_ALL`이 초당 1회라 호출 사이 1.2초를 두므로 콜드 수집에 약 8초가 들고, 그동안 `종목 목록 준비 중… (n/7)`을 표시한다. 수집은 **관리 섹션을 처음 펼칠 때** 시작한다 — 검색을 안 쓰는 세션에서는 호출이 나가지 않는다. 이후는 `universe.json` 캐시(§2.3)로 즉시 검색된다.
  - **매칭**: 심볼과 종목명 **양쪽**을 본다. 이름만 보면 `AAPL`이 안 걸리고, 심볼만 보면 `삼성전자`가 안 걸린다. 미국 종목도 한글명을 주지만 NASDAQ·AMEX ETF 상당수는 종목명이 심볼과 같다(실측 `AAAP`, `AAA`). 대소문자는 무시한다. 초성 검색은 지원하지 않는다.
  - **정렬·건수**: 심볼 완전일치 → 이름 완전일치 → 심볼 prefix → 이름 prefix → 이름 부분일치 → 심볼 부분일치 순, 동점은 심볼 오름차순. **상위 8건**만 표시한다. 질의는 350ms 디바운스하고, 질의가 바뀌면 진행 중인 시세 조회를 취소한다. 한글은 자모 조합 단계마다 `onChange`가 오므로 디바운스가 짧으면 조합 중간 질의로 시세를 부른다.
  - **행 표시**: `종목명 / 코드 · 마켓` + 현재가 + `▲등락률% 등락액`. 현재가는 `/prices` 배치 1회로 **한 번에** 뜨고, 등락은 종목별로 위에서부터 채워진다(`확인 중…` → 값). 등락 계산은 관심종목 섹션과 **같은 경로**이며 `PrevCloseStore` 캐시도 공유한다(§3.3) — 이미 관심종목으로 조회된 종목은 candles 호출 없이 즉시 채워진다.
  - **행 클릭**: 본문(종목명·코드·시세)을 클릭하면 §3.2와 동일하게 토스증권 종목 페이지를 연다. 한국이면 딥링크, 미국이면 홈 + 안내 툴팁이며, 시세 도착 전에도 판별해야 하므로 `currency`가 아니라 **마켓**으로 가른다(`KOSPI`·`KOSDAQ`·`KR_ETC`가 국내).
  - **추가**: 행 우측에 별칭 입력 TextField와 `+` 버튼을 둔다. 별칭은 상시 노출이며 비워 두면 종목명으로 표시된다. `+` 또는 별칭 필드에서 Enter로 추가한다. 질의가 바뀌면 입력해 둔 별칭은 비운다 — 결과가 갈리면 엉뚱한 종목에 붙는다. 이미 등록된 종목은 입력·버튼 대신 `✓` 배지를 보여준다(행 클릭은 그대로 종목 페이지를 연다).
  - **유니버스에 없는 종목은 추가할 수 없다.** 목록이 하루 1회 갱신이라 당일 신규 상장 종목은 다음 날 검색된다.
  - **상태별 표시**: 유니버스 전량 실패 → `종목 목록을 불러오지 못했어요 (인증 확인)`. 일부 마켓 실패 → `일부 시장 목록을 못 받아 결과가 빠질 수 있어요`(받은 만큼으로 검색은 된다). 결과 없음 → `검색 결과 없음`. `/prices`에 없는 종목 → `시세 없음`.
- **삭제**: 등록 종목별 행에 `표시명 (코드)` + `X` 버튼. 클릭 시 즉시 제거.
  - 표시명은 `/stocks`의 실제 종목명을 우선하고, 별칭이 있으면 ` · 별칭`으로 병기한다. 종목명 조회 실패 시 별칭 → 코드 순으로 폴백한다. 코드는 항상 괄호로 병기한다.
- **별칭 수정(인라인)**: 등록 종목 행의 표시명을 클릭하면 그 자리에 별칭 입력 TextField(현재 별칭으로 프리필)가 나타난다. `✓`(또는 Enter)로 저장, `✗`로 취소한다. 별칭을 비우고 저장하면 별칭이 제거된다. 코드는 바뀌지 않으며 줄 순서·다른 항목은 보존된다. 별칭이 없던 종목도 클릭해 새로 지정할 수 있다.
- **즉시 반영**: 삭제·별칭 수정은 네트워크 없이 `symbols.tsv` 기록과 동시에 로드된 관심종목 행을 그 자리에서 갱신한다(다음 폴링까지 안 기다림). 추가는 관리 목록에 즉시 나타나고, 새 종목의 시세·등락 행은 즉시 1회 갱신으로 채운다.
- **정합(reconcile)**: 폴링 커밋 시 fetch 결과를 **현재** `symbols.tsv`에 맞춘다 — 삭제된 코드 제거, 별칭 relabel(조회실패 행은 코드 표시 유지), 줄 순서 정렬. 갱신 요청이 진행 중이던 사이 일어난 삭제/수정/재배치가 옛 스냅샷으로 되돌려지는 레이스를 차단한다(보유섹션 순서 재적용과 대칭).

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
- **레이어**: `PopupView`(뷰) → `StockModel`(@MainActor @Observable, 폴링·회전 소유) → `TossService`/`TossAPI`(service) → `URLSession`(I/O). 토큰은 actor `TokenStore`에 위임.
- **빌드**: SwiftPM `executableTarget`(외부 의존성 0, Swift 6 모드). `Packaging/build.sh` → `.app` 조립 + ad-hoc codesign. `--dump` 인자로 GUI 없이 데이터 레이어 헤드리스 검증.
- **App Sandbox OFF**: 토큰 저장(§4.4)이 `~/.config/tossstock` 접근을 요구 → 미샌드박스(entitlements 파일 없음). 미샌드박스 앱은 `network.client` 없이 네트워크 가능.
- **레이아웃 주의**: `ScrollView`는 고유 높이가 0이라 self-sizing 윈도우(`MenuBarExtra .window`)에서 붕괴한다 → 콘텐츠 실측 높이로 ScrollView 높이를 고정(최대 520, 초과 시 스크롤).

### 4.3 데이터 디코딩

- 모든 금액/수량 JSON 필드는 **문자열** → 합성 Decodable이 `decode(Double.self)`로 깨진다. 금액 보유 DTO마다 수동 `init(from:)` + `decimal()` 헬퍼(문자열·숫자·null·키누락·빈문자열 전부 nil/값, 크래시 0).
- `currency`는 **관대한 enum**(unknown 값 흡수). 중첩 디코드라 throw하면 holdings 통째 블랭크가 되기 때문.
- candles: **최신 봉부터 역순**. `interval=1d`면 `candles[0]`=당일(진행 중), `candles[1]`=직전 거래일. `count < 2` 가드(신규상장 인덱스 크래시 방지). 국내 일봉 `timestamp`는 KST 자정이라 앞 10자가 곧 거래일(`Candle.day`). 국내 일봉 종가를 그대로 전일종가로 쓰면 안 되는 이유는 §3.3.

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
│   ├── Format.swift               ₩/$/원/달러·등락·화살표 포맷(§3.7) — 전 레이어 공용
│   ├── ConfigPaths.swift          ~/.config/tossstock 경로 묶음(§2.3) — 전 레이어 공용
│   ├── Popup/                     화면 레이어
│   │   ├── PopupView.swift        드롭다운(보유/관심/관리/하단/설정안내) — 다크 'Color pill' 디자인
│   │   ├── SearchSection.swift    관심종목 관리 안의 종목 검색 UI(§3.4)
│   │   ├── StockModel.swift       @MainActor @Observable. 폴링 루프·회전·인증상태·검색상태
│   │   ├── ReorderController.swift 드래그 재배치(DragSession·Reorderable·edge 자동 스크롤, §3.2)
│   │   └── Palette.swift          다크 'Color pill' 색 토큰
│   ├── Toss/                      토스 Open API 연동 레이어
│   │   ├── TossService.swift      도메인 메서드(positionRows/watchRows/authStatus) + Dump
│   │   ├── TossAPI.swift          URLSession 요청계층(Bearer·계좌헤더·401/429 재시도) + TossHTTP
│   │   ├── TokenStore.swift       actor TokenStore(토큰 캐시·in-flight·디스크 재확인) + TossAuthError
│   │   ├── PrevCloseStore.swift   actor. 전일종가 세션별 캐시 + candles 슬롯 예약(§3.3)
│   │   ├── StockUniverse.swift    actor. 검색용 전체 종목 수집·캐시·로컬 검색(§3.4)
│   │   ├── TossDTO.swift          API 응답 DTO(수동 init + decimal 헬퍼)
│   │   └── DisplayRow.swift       service → view 표시용 Row(PositionRow·WatchRow·Direction·AuthStatus)
│   └── Storage/                   설정 파일 I/O 레이어(§2.3)
│       ├── Watchlist.swift        symbols.tsv 읽기/추가/삭제/순서저장 + 정제
│       └── HoldingsOrder.swift    holdings_order.txt 읽기/쓰기 + 저장 순서로 정렬(드래그 재배치)
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
- **관심종목·검색 등락 = candles 의존**: 전일종가 조회에 candles 호출이 필요하다(국내 2회 + 미국 1회, §3.3). 호출 간 0.25초를 두므로 **거래일 첫 새로고침**만 `(국내×2 + 미국)×0.25초` + 429 재시도가 든다(국내 11 + 미국 6 실측 ≈12초, 폴링 주기 10초보다 길지만 `refresh()`가 순차라 겹치지 않는다). 그 뒤 폴링은 캐시 히트라 `/prices`·`/stocks`·`/holdings` 배치 호출만 남고(실측 0.1초), 세션일 확인이 60초마다 시장별 1콜 얹힌다. 세션이 넘어가면 캐시가 만료돼 다시 한 번 든다.
  - 검색은 같은 페이서와 캐시를 쓴다. 관심종목에 없는 종목 8건을 검색하면 종목별 1~2회로 국내 기준 최대 16콜 ≈ 4초가 걸리고(세션일은 폴링이 이미 캐시해 둔다), 그동안 폴링의 전일종가 조회와 슬롯을 나눠 쓴다. 같은 종목을 다시 검색하면 캐시 히트라 `/prices` 1콜로 끝난다.
- **종목 검색 = 유니버스 수집 의존**: 검색 엔드포인트가 없어 `/stocks/all`로 마켓 7개를 받는다(§3.4). `STOCK_ALL`이 초당 1회라 콜드 수집에 약 8초, 그 뒤 하루 동안은 `universe.json` 캐시로 네트워크 0이다. `MARKET_DATA`(폴링)와 다른 rate 그룹이라 폴링과 예산을 다투지 않는다.
- **새로고침 주기**: 폴링 간격 10초(코드 상수). `RunLoop` Timer가 아닌 `Task.sleep`이라 팝업을 펼친 채로도 동작한다.
