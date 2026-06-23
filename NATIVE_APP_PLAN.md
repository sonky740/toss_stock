# tossstock 네이티브 메뉴바 앱 — 구현 Plan (토스 Open API 버전)

> 개정: 2026-06-23. 데이터 소스가 비공식 CLI `tossctl`(Process+jq)에서 **토스증권 Open API**(`https://openapi.tossinvest.com`, OAuth2 Client Credentials, **REST 전용**)로 전면 교체됨.
> 권위 기준: 재작성된 `SwiftBar/tossstock.10s.sh`(curl+OAuth2 동작 참조) + Open API 스펙 v1.1.1 + `SPEC.md`. tossctl 버전 plan은 `NATIVE_APP_PLAN.tossctl-backup.md`.
> 동기(불변): SwiftBar NSMenu는 펼치면 `.eventTracking` 런루프로 타이머·redraw가 멈춘다. Stats처럼 "펼친 채 실시간 갱신"하려면 NSMenu가 아닌 플로팅 윈도우 네이티브 앱이 필요하다.

## UI 아키텍처 (불변 — tossctl 버전 그대로 유지)

세 렌즈 만장일치로 채택했던 결정은 데이터 소스가 바뀌어도 그대로다:

- **UI 스택**: SwiftUI `MenuBarExtra` + `.menuBarExtraStyle(.window)` 단독. `.window`는 NSMenu가 아닌 플로팅 윈도우 → 메인 런루프 default 유지 → 펼친 채 갱신.
- **갱신 루프**: `Task { while: Task.sleep }` 폴링 10초. RunLoop Timer 금지(`.default` 모드면 팝업 스크롤/드래그 중 `.eventTracking` 진입으로 멈춤 = SwiftBar 부분 동결 재현). `Task+sleep`는 런루프 모드 무관.
  - **이제 폴링이 유일한 옵션이다** — 토스 Open API는 REST 전용, WebSocket/SSE 실시간 스트림이 없다(스펙 v1.1.1 전체 경로 확인). 구 plan의 "SSE 강화" deferred 항목은 영구 폐기.
- **메뉴바 타이틀**: 모노크롬·인메모리 회전 인덱스(영속 앱이라 `/tmp` 파일 불필요). 컬러는 드롭다운 뷰에만.
- **앱 골격**: `@main` + `NSApp.setActivationPolicy(.accessory)`/`LSUIElement`, `@MainActor @Observable` 모델.
- **레이어 경계**: 뷰 → model → service → I/O.

## 데이터 레이어 (전면 교체)

**`URLSession` 직접 호출 + OAuth2 Client Credentials.** `Process`·CLI·jq·PATH 의존 전부 제거.

| | tossctl(구) | 토스 Open API(신) |
|---|---|---|
| 호출 | `Process`+CLI+jq+NDJSON 파싱 | **URLSession** async/await |
| 인증 | playwright 쿠키 세션 | **OAuth2 토큰**(24h, client당 1개) |
| 실시간 | `push listen` SSE(미관측) | **없음 — REST 폴링이 유일** |
| 통화 | positions 전원화, USD 별도조회 | **종목별 native 통화·USD 손익 직접** |
| Rate limit | 없음 | **그룹별 토큰버킷** + `X-RateLimit-*`/429 |
| App Sandbox | OFF 강제(외부 실행) | **ON 가능**(`network.client`만) |
| 데이터 타입 | — | **모든 금액 String** → Codable String→Double |

---

## 확정 파일/모듈 구조

```
tossstock-app/
├── Package.swift                  SwiftPM executableTarget, 의존성 0
├── Sources/TossStock/
│   ├── TossStockApp.swift         @main. MenuBarExtra(.window) Scene. setActivationPolicy(.accessory)   [유지]
│   ├── StockModel.swift           @MainActor @Observable. holdings/watchlist/authState/회전인덱스.
│   │                              Task 폴링 루프 소유. service 결과를 메인에서 '대입만'             [내부변경]
│   ├── TossAPI.swift              service. URLSession 요청계층: Bearer + (holdings만)X-Tossinvest-Account
│   │                              + ApiResponse<T> 봉투 디코드 + 401 1회 재시도 + 429 백오프         [Tossctl.swift 대체]
│   ├── TossAuth.swift  (TokenStore) actor. OAuth2 토큰 캐시·재발급·in-flight 공유·401 단일재발급·accountSeq [신규]
│   ├── TossService.swift          도메인 메서드 + Row 매핑(누락 격리·전일종가 등락·통화 분기)         [신규/분리]
│   ├── Models.swift               ApiResponse 봉투 + DTO + lenient enum + String→Double 변환          [전면교체]
│   ├── Watchlist.swift            symbols.tsv 읽기/쓰기/시드/추가/삭제 + cleanCode/cleanAlias          [유지]
│   ├── PopupView.swift            드롭다운(보유/관심/관리/하단). USD 손익 직접 표시                    [내부변경]
│   └── Format.swift               fmtKRW/fmtUSD/fmtPnlKRW/fmtPnlUSD/comma/등락표시. Foundation만        [유지, fmtPnlUSD 실사용]
└── Packaging/
    ├── Info.plist                 LSUIElement=true, CFBundleIdentifier, CFBundleExecutable
    ├── TossStock.entitlements      app-sandbox=true + network.client=true                              [신규]
    └── build.sh                   swift build -c release → .app 조립 → codesign(+entitlements)
```

**레이어 경계:** 뷰 → model → service(`TossAPI`/`TossService`) → I/O(URLSession). service는 토큰 확보를 `TossAuth` actor에 위임. **`/holdings`만 `X-Tossinvest-Account` 헤더 필요**, `/prices`·`/stocks`·`/candles`는 불필요. `TossAuth`만 `actor`, 나머지 service는 nonisolated async + Sendable 반환, 최종 대입만 `@MainActor` hop.

> 과설계 방지: `Candle`은 이제 정식 wired 타입(전일종가 계산 필수)이라 정의. `PushEvent`는 영구 폐기(스트림 부재). overview 합계·`marketValue`·`cost`·미사용 필드는 정의하지 않음. 클라이언트측 토큰버킷 시뮬레이터 만들지 않음(429 reactive 백오프만).

---

## 데이터 모델 (Models.swift — wired 타입만)

모든 200 응답은 `{ "result": <T> }` 봉투. 모든 금액/수량 필드는 **문자열**(`"72000"`, `"-0.0418"`).

```swift
struct ApiResponse<T: Decodable>: Decodable { let result: T }

struct OAuth2TokenResponse: Decodable {            // /oauth2/token (표준 OAuth2 포맷, 봉투 아님)
    let accessToken: String; let expiresIn: Int    // expires_in = 86400 (24h)
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", expiresIn = "expires_in" }
}

// 스펙: 클라이언트는 unknown enum 값을 허용해야 함 → throw 흡수(안 그러면 중첩 디코드라 holdings 통째 블랭크)
enum Currency: Decodable, Sendable { case krw, usd, unknown(String)
    init(from d: Decoder) throws { switch try d.singleValueContainer().decode(String.self) {
        case "KRW": self = .krw; case "USD": self = .usd; case let o: self = .unknown(o) } } }
enum MarketCountry: Decodable, Sendable { case kr, us, unknown(String) /* 동일 패턴 */ }

// String→Double: null·키누락·빈문자열 전부 nil (@propertyWrapper의 optional+키누락 함정 회피)
extension KeyedDecodingContainer {
    func decimal(_ key: Key) -> Double? {
        guard let s = try? decodeIfPresent(String.self, forKey: key), let s, let v = Double(s) else { return nil }
        return v } }

struct Account: Decodable, Sendable { let accountNo: String; let accountSeq: Int; let accountType: String }
struct HoldingsOverview: Decodable, Sendable { let items: [HoldingsItem] }   // 합계는 미사용 → 생략
struct HoldingsItem: Decodable, Sendable {
    let symbol, name: String; let marketCountry: MarketCountry; let currency: Currency
    let lastPrice: Double?            // 거래통화 기준 (KR=KRW, US=USD)
    let profitLoss: ProfitLoss        // 누적 손익 — 보유섹션이 쓰는 것 (dailyProfitLoss는 안 씀)
    // quantity/averagePurchasePrice/marketValue/cost/dailyProfitLoss는 init에서 필요분만
}
struct ProfitLoss: Decodable, Sendable { let amount: Double?; let rate: Double? }  // rate=소수비율 0.1077=10.77%, 통화무관
struct PriceResponse: Decodable, Sendable { let symbol: String; let lastPrice: Double?; let currency: Currency }
struct StockInfo: Decodable, Sendable { let symbol, name: String }                 // name=한글 종목명
struct CandlePageResponse: Decodable, Sendable { let candles: [Candle] }
struct Candle: Decodable, Sendable { let closePrice: Double? }                      // candles[1]=전일종가

// 표시용(service → view). 통화 한계 해소 반영: pnl이 원화전용이 아니라 native 통화 + Currency 동반
enum Direction: Sendable { case up, down, flat }
struct PositionRow: Identifiable, Sendable {
    let id, name: String; let lastPrice: Double; let currency: Currency
    let ratePercent: Double; let pnlAmount: Double; let direction: Direction }
struct WatchRow: Identifiable, Sendable {
    let id, displayName, aliasOrName: String; let currency: Currency; let lastPrice: Double
    let change: WatchChange; let resolvedName: String? }
enum WatchChange: Sendable {
    case priced(changeAmount: Double, ratePercent: Double, direction: Direction)
    case noPrevClose          // 신규상장 등 — 현재가만
    case lookupFailed }       // prices 누락 — "조회실패"
```

> **혼동 금지:** 보유섹션은 **누적** `profitLoss`(스크립트 패리티). `dailyProfitLoss`는 holdings에 있지만 안 씀. 전일종가 등락(`candlePrevClose`)은 **관심종목 전용**. 셋을 섞지 않는다.
> 디코딩 테스트로 박을 것: 정상 string / `null` / 키누락 / 빈문자열 → 전부 크래시 없이 nil/값. unknown enum → 흡수.

---

## 토큰 · Rate-limit 서브시스템 (TossAuth.swift / TossAPI.swift)

핵심 제약: **client당 토큰 1개**(재발급 시 이전 토큰 즉시 무효화 + AUTH rate limit). → (a) 만료까지 캐시 재사용, (b) 만료 5분 전 선제 재발급, (c) 동시 다수 요청이 만료를 동시 감지해도 **재발급 1회**, (d) 401 시 **단일 재발급**.

```swift
actor TokenStore {
    private var cached: CachedToken?
    private var refreshTask: Task<CachedToken, Error>?     // in-flight 공유 핸들

    func token() async throws -> CachedToken {
        if let c = cached, c.expiresAt > Date() { return c }
        return try await refresh(invalidating: nil) }

    func forceRefresh(used stale: String) async throws -> CachedToken {
        if let c = cached, c.accessToken != stale { return c }   // 그새 다른 caller가 갱신했으면 그것 반환
        return try await refresh(invalidating: stale) }          // → N개 동시 401 → 재발급 1회 (thrashing 방지)

    private func refresh(invalidating: String?) async throws -> CachedToken {
        if let refreshTask { return try await refreshTask.value }    // 진행 중이면 합류
        let task = Task { try await self.fetchAndCache() }
        refreshTask = task                                           // ← load-bearing: await '이전' 동기 세팅
        defer { refreshTask = nil }
        return try await task.value }
    // fetchAndCache: POST /oauth2/token → expiresAt = now + expiresIn - 300, accountSeq 보강, persist.save(atomic)
}
```

`refreshTask = task`를 `await` *이전*에 동기로 세팅하는 게 핵심 — actor 직렬성은 await 경계를 보장하지 않으므로, 이게 in-flight 공유와 401 thundering-herd 둘 다를 잡는다.

**요청 계층(TossAPI.get):** Bearer 부착 → 200이면 `ApiResponse<T>.result` 추출 → **401이면 `forceRefresh(used:)` 후 1회 재시도** → **429면 `retryAfterSeconds`(본문) 또는 `Retry-After` 헤더만큼 1회 백오프 후 재시도**. `needsAccount`면 `X-Tossinvest-Account: accountSeq` 부착.

**한 폴링 주기 호출수 & rate 그룹 (그룹 다르면 버킷 다름 → 직렬화 불필요):**

| 호출 | rate 그룹 | 횟수 | 전략 |
|---|---|---|---|
| accounts | ACCOUNT | 0~1 | 토큰 캐시에 seq 있으면 0 |
| holdings | ASSET | 1 | `async let` 병렬 |
| prices | MARKET_DATA | 1 | `async let` 병렬 |
| stocks | STOCK | 1 | `async let` 병렬 |
| **candles** | **MARKET_DATA_CHART** | **N(종목당 1)** | **직렬 + `Task.sleep(0.25s)`** |

candles만 낮은 별도 한도 → 직렬 페이싱(스크립트의 `sleep 0.25` 대응). `count=2` 요청이라도 신규상장은 1개만 오므로 `candles.count >= 2` 가드(인덱스 크래시 방지).

---

## Phase별 구현 계획

### Phase 0 — 토큰 검증 · 응답 관측 · 스캐폴딩 · 렌더 게이트
- **(a)** ① `auth.env`의 `client_id`/`secret` 확인 → `POST /oauth2/token` 발급 검증 → `GET /api/v1/accounts`로 `accountSeq` 확보. ② `holdings`/`prices`/`stocks`/`candles` 각 `.result` 구조·String 필드 실측 캡처. ③ **실시간 스트림 부재 확정**(REST 전용 → 폴링 확정). ④ **rate-limit 헤더 관측**(`X-RateLimit-*` 실값 + 429 `retryAfterSeconds`, candles N종목 버스트 페이싱 검증). ⑤ 스캐폴딩: `Package.swift` + 더미 `MenuBarExtra`(1초 카운트업) + `Info.plist`(LSUIElement) + `entitlements`(sandbox+network.client) + `build.sh`(.app + ad-hoc codesign).
- **(b)** 캡처된 `.result` JSON 샘플 · rate-limit 헤더 로그 · 빌드되는 `.app` 골격.
- **(c)** **실기에서** Dock 없이 메뉴바 항목 표시 + 더미 카운트업 = **go/no-go 게이트**. 실패 시 폴백 = NSStatusItem + NSPopover(제안 B).
- > 인증은 이미 동작 중(`auth.env`/`token.json` 존재, 토큰 발급됨). 구 plan의 "tossctl 재인증"은 불필요.

### Phase 1 — 데이터 레이어
- **(a)** `Models.swift` + `TossAuth.swift`(토큰 actor) + `TossAPI.swift`(URLSession) + `TossService.swift`.
- **(c)** `swift run` 콘솔 덤프 + **회귀 검증 3종**: (1) prices/stocks에 불량 코드 1개 섞어 **줄단위 격리**(누락 코드만 "조회실패", 나머지 정상), (2) **401 주입 시 1회 재발급 복구**, (3) **candles 페이싱으로 429 미발생**.

### Phase 2 — 모델 + 폴링
- `StockModel`(`Task` 폴링 10초, `async let`로 holdings·watch 병렬) + `Format.swift`. 팝업 펼친 채 갱신 + 스크롤/드래그 중 지속 확인.

### Phase 3 — 뷰 + 회전 타이틀
- `PopupView`(보유/관심) + 인메모리 회전. 셸 플러그인과 나란히 두고 줄·색·포맷·회전 일치 대조.

### Phase 4 — 관심종목 관리
- `Watchlist`(추가/삭제/정제/시드) + UI(결정 #1). symbols.tsv 동일 형식 갱신 확인.

### Phase 5 — 인증/하단
- authState 분기 + 새로고침 + **앱 내 인증 점검**(토큰 발급 + accounts 조회 결과 표시). 토큰 만료·자격증명 누락 상태 렌더.

### Phase 6 (선택) — 배포
- App Sandbox ON + Hardened Runtime ON → Developer ID 서명 → `notarytool` 공증 → `stapler`. (유료 계정 $99/년, 결정 #6)

### deferred — 그래프, 자동시작
`candles` 다봉 스파크라인·SMAppService 자동시작은 SPEC 너머. **SSE 강화 항목은 폐기**(스트림 부재).

---

## 현재 플러그인 6기능 → 네이티브 매핑 (누락 0)

| # | 기능 | 매핑 |
|---|---|---|
| 1 | 회전 타이틀 | **변경 없음**. 후보 우선순위(보유→관심→`📈 종목 없음`)·형식·인메모리 인덱스 동일, 데이터 소스만 신규 |
| 2 | 보유섹션 | `TossService.positionRows()`←`holdings()`(계좌헤더). `profitLoss.rate×100` 부호(flat 무부호). **현재가·평가손익을 종목 native 통화로 직접** — US는 `lastPrice`/`profitLoss.amount` USD 그대로(`fmtUsd`/`fmtPnlUsd`), KR은 ₩/원. **구 plan의 "US만 quote batch USD 별도조회" 제거**(holdings가 통화별 직접 제공 → 호출 1회 감소) |
| 3 | 관심섹션 | `watchRows()` = `prices`(현재가+통화, batch1) + `stocks`(종목명, batch1) + `candles`(종목당1, 1d/2 → `candles[1].closePrice`=전일종가). 등락=현재가−전일종가. 전일종가 없으면 현재가만. **prices/stocks 누락 코드 줄단위 "조회실패" 격리** |
| 4 | 추가/삭제 | **변경 없음**. `Watchlist` 그대로. 삭제 라벨 종목명 소스만 `stocks.name` |
| 5 | 하단 | 새로고침=`model.refreshNow()`. "인증 상태 확인"=앱 내 토큰 발급+accounts 조회 결과 표시(터미널 tossctl 대체) |
| **6** | **통화 한계 → 해소** | **"평가손익 원화 전용" 완화책 폐기.** holdings가 종목별 native 통화로 `lastPrice`·`profitLoss.amount`·`profitLoss.rate`(통화무관 비율) 직접 반환 → **미국주식 USD 평가손익 직접 표시**. 환율 역산·원화 환산 불필요 |

---

## 위험·미지수 + 완화책

**소멸(구 plan에서 제거):** ~~GUI 앱 PATH~~(외부 프로세스 0) · ~~SSE 스키마~~(스트림 부재) · ~~NDJSON vs 단일배열~~(ApiResponse 봉투) · ~~App Sandbox OFF~~(ON 가능) · ~~통화/원화환산 부정확~~(해소).

| 항목 | 리스크 | 완화책 |
|---|---|---|
| **이중 클라이언트 토큰 thrashing (신규 최대)** | 같은 `client_id`로 플러그인+앱이 동시에 `/oauth2/token` → 서로 토큰 즉시 무효화 → 401 thrashing | 결정 #토큰저장: 토큰 캐시 **파일 공유** 또는 **별도 client_id**. 한쪽만 운영하면 무위험 |
| **메뉴바 실제 렌더 (최대)** | macOS 26 실제 렌더 미검증 | **Phase 0 go/no-go 게이트**. 실패 시 NSStatusItem+NSPopover 피벗 |
| **Rate-limit / 429** | 그룹별 토큰버킷, 스펙에 수치 없음(런타임 헤더) | `X-RateLimit-Remaining` 인지 + 429 `retryAfterSeconds` 1회 백오프 |
| **candles N종목 버스트** | `MARKET_DATA_CHART` 별도·낮은 한도, 관심 N개=candles N회 | 호출 간 0.25s 페이싱. 렌더에 ~N×0.25s 추가 |
| **String 디코딩** | 모든 금액 문자열 + null/키누락 | `decimal()` 헬퍼(null·누락·빈문자열 nil), unknown enum 흡수 — 테스트로 박음 |
| **accountSeq 누락** | `/holdings` 계좌헤더 필수 | 토큰과 함께 캐시, 빔이면 1회 재조회 |
| **자격증명 보관** | `auth.env`/`token.json` | `chmod 600`. 저장 위치 결정 #토큰저장 |
| `.window` 팝오버 닫기 | osascript 다이얼로그 dismiss 충돌 | 결정 #1 |
| 서명/공증·Xcode 미설치 | — | SwiftPM 우회, ad-hoc 로컬 |

---

## 사용자에게 받아야 할 결정사항

**이미 확정:** symbols.tsv 재사용 · `Task+sleep` 10초 폴링 · UI 스택(MenuBarExtra(.window)).

**열린 결정:**
1. **토큰 저장 전략 (신규·thrashing과 결합)** — (a) 플러그인 `~/.config/tossstock/token.json` **캐시 공유**(이중 클라이언트 thrashing 동시 해소, 마이그레이션 0, atomic write) / (b) **Keychain 단독**(표준·암호화·Sandbox 친화, 단 플러그인과 토큰 분리→충돌 잔존) / (c) **별도 client_id**(완전 격리, 키 2개 관리). → 플러그인 병행 유지 시 **(a) 유력**, 폐기 확정 시 (b). => a안
2. **SwiftBar 플러그인 병행 유지 여부** — 토큰 결정과 직결. 제거하면 thrashing 위험 소멸. => 새로운게 완성되고 정상작동되면 SwiftBar는 삭제
3. **App Sandbox** — 구 plan OFF → **이제 ON 권장**(외부 프로세스 0, `network.client`만). 토큰 파일 공유 택하면 `~/.config` 접근 고려.
4. **섹션 throw 시 동작 (신규)** — `holdings`/`prices`가 401·네트워크로 통째 throw할 때: 섹션 전체 "조회 실패"(스크립트 동작) vs **직전 폴링 값 유지(stale)**. 영속 앱이라 stale이 더 나을 수 있음.
5. **unknown 통화/마켓 처리 (신규)** — 스펙상 가능. 해당 행: KRW 취급 폴백 vs "지원 안 함" 회색 처리.
6. **유지**: 추가/삭제 UI(osascript vs 인라인 vs NSWindow) · 빌드 타깃(SwiftPM vs Xcode) · 회전 cadence · 최소 macOS · 배포 범위($99 공증).
