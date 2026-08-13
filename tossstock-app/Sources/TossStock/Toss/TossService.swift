import Foundation

// ─────────────────────────────────────────────────────────────
// TossService — 도메인 메서드 + Row 매핑.
//   positionRows: /holdings → 보유섹션(종목별 native 통화 손익)
//   watchRows   : /prices(batch) + /stocks(batch) + /candles(전일종가, 종목당 세션당 1회)
//                 → 관심섹션(현재가-전일종가 등락). prices 누락 코드는 줄단위 "조회실패" 격리.
//   authStatus  : 앱 내 인증 점검(토큰 발급 + accounts 조회)
// ─────────────────────────────────────────────────────────────

/// 전일종가가 갈리는 단위. 롤 시각은 벽시계로 못 맞힌다 — 미국 일봉 stamp 는 00:00 ET(`T13:00+09:00`)
/// 인데 실제 롤은 오버나이트 개장(20:00 ET = 09:00 KST)이라 라벨보다 4시간 이르다(§3.3 실측).
enum Market: Sendable {
  case kr, us

  /// 시장 시계 — 이 종목의 최신 일봉 날짜가 곧 그 시장의 현재 세션일.
  /// 유동성이 높아 세션이 열리는 즉시 봉이 생기고, 비거래일엔 생기지 않는다.
  var clockSymbol: String { self == .us ? "SPY" : "005930" }
}

struct TossService: Sendable {
  let api: TossAPI
  let prevCloses = PrevCloseStore()

  func positionRows() async throws -> [PositionRow] {
    let overview = try await api.get("/api/v1/holdings", needsAccount: true, as: HoldingsOverview.self)
    return overview.items.map { item in
      let rate = item.profitLoss.rate ?? 0  // 셸 패리티: 누락은 0 취급(행 유지)
      let dir: Direction = rate > 0 ? .up : (rate < 0 ? .down : .flat)
      return PositionRow(
        id: item.symbol,
        name: Self.clean(item.name),
        lastPrice: item.lastPrice ?? 0,
        currency: item.currency,
        ratePercent: rate * 100,
        pnlAmount: item.profitLoss.amount ?? 0,
        direction: dir
      )
    }
  }

  func watchRows(_ symbols: [WatchSymbol]) async throws -> [WatchRow] {
    guard !symbols.isEmpty else { return [] }
    let csv = symbols.map(\.code).joined(separator: ",")

    // 서로 다른 rate 그룹(MARKET_DATA / STOCK) → 병렬. 누락은 빈 배열로 흡수(줄단위 격리는 아래 dict 조회에서).
    async let pricesT = api.get("/api/v1/prices?symbols=\(csv)", as: [PriceResponse].self)
    async let stocksT = api.get("/api/v1/stocks?symbols=\(csv)", as: [StockInfo].self)
    let prices = (try? await pricesT) ?? []
    let stocks = (try? await stocksT) ?? []
    let priceBy = Dictionary(prices.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
    let nameBy = Dictionary(stocks.map { ($0.symbol, $0.name) }, uniquingKeysWith: { a, _ in a })

    // 전일종가 캐시의 유효 범위 = 시장의 현재 세션일. 폴링마다 시장별 1회만 확인한다.
    var sessionDays: [Market: String] = [:]
    for market in Set(symbols.compactMap { priceBy[$0.code].map { Self.market($0.currency) } }) {
      sessionDays[market] = await sessionDay(market)
    }

    var rows: [WatchRow] = []
    for sym in symbols {
      guard let price = priceBy[sym.code], let last = price.lastPrice else {
        rows.append(
          WatchRow(
            id: sym.code, rowName: sym.code, titleName: sym.code,
            currency: .krw, lastPrice: 0, change: .lookupFailed, resolvedName: nil))
        continue
      }
      let resolved = nameBy[sym.code]
      let (row, title) = WatchRow.displayNames(code: sym.code, resolvedName: resolved, alias: sym.alias)

      let market = Self.market(price.currency)
      let prev = await prevClose(sym.code, market: market, sessionDay: sessionDays[market])
      let change = Self.change(last: last, prevClose: prev)
      rows.append(
        WatchRow(
          id: sym.code, rowName: row, titleName: title,
          currency: price.currency, lastPrice: last, change: change, resolvedName: resolved))
    }
    return rows
  }

  /// 검색 결과 시세. 가격을 배치 1회로 먼저 흘리고, 등락은 종목별로 완성되는 대로 흘린다.
  ///
  /// 등락률·등락액을 주는 엔드포인트가 없어(`/prices`는 현재가만) 관심종목과 **같은 경로**로 계산한다.
  /// 여기서 일봉 종가를 직접 쓰면 국내 종목이 NXT 시간외 마감가를 기준가로 잡아 관심종목 섹션과
  /// 다른 등락률을 보이게 된다(§3.3). 그래서 `prevClose`를 그대로 탄다 — 캐시도 함께 공유한다.
  func quotes(for codes: [String]) -> AsyncStream<QuoteUpdate> {
    AsyncStream { continuation in
      let task = Task { await stream(codes, into: continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func stream(_ codes: [String], into continuation: AsyncStream<QuoteUpdate>.Continuation) async {
    guard !codes.isEmpty else {
      continuation.finish()
      return
    }
    let csv = codes.joined(separator: ",")
    let prices = (try? await api.get("/api/v1/prices?symbols=\(csv)", as: [PriceResponse].self)) ?? []
    let priceBy = Dictionary(prices.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })

    var priced: [(code: String, last: Double, market: Market)] = []
    for code in codes {
      guard let price = priceBy[code], let last = price.lastPrice else {
        continuation.yield(.unavailable(symbol: code))
        continue
      }
      continuation.yield(.priced(symbol: code, lastPrice: last, currency: price.currency))
      priced.append((code, last, Self.market(price.currency)))
    }

    var sessionDays: [Market: String] = [:]
    for market in Set(priced.map(\.market)) {
      if Task.isCancelled { break }
      sessionDays[market] = await sessionDay(market)
    }

    for item in priced {
      if Task.isCancelled { break }  // 질의가 바뀌면 남은 candles 호출을 낭비하지 않는다
      let prev = await prevClose(item.code, market: item.market, sessionDay: sessionDays[item.market])
      continuation.yield(.changed(symbol: item.code, change: Self.change(last: item.last, prevClose: prev)))
    }
    continuation.finish()
  }

  func authStatus() async throws -> AuthStatus {
    let accounts = try await api.get("/api/v1/accounts", as: [Account].self)
    guard let first = accounts.first else { throw TossAuthError.noAccount }
    return AuthStatus(
      accountNo: first.accountNo, accountSeq: first.accountSeq,
      expiresAt: await api.tokens.currentExpiry())
  }

  /// 인증 점검이 429(accounts limit=1)로 막힐 때 캐시 폴백용.
  func cachedAuthInfo() async -> (seq: Int?, expiry: Date?) {
    let seq = await api.tokens.cachedSeq()
    let expiry = await api.tokens.currentExpiry()
    return (seq, expiry)
  }

  /// 전일종가(등락 계산의 분모). 세션 안에서 불변이므로 종목당 세션당 1회만 조회한다.
  /// `sessionDay`가 nil(시장 시계 조회 실패)이면 캐시하지 않는다 — 틀린 키로 저장하면 세션 내내 물고 간다.
  private func prevClose(_ code: String, market: Market, sessionDay: String?) async -> Double? {
    if let sessionDay, let cached = await prevCloses.cached(code, on: sessionDay) { return cached }

    await awaitCandleSlot()
    guard
      let page = try? await api.get(
        "/api/v1/candles?symbol=\(code)&interval=1d&count=2",
        as: CandlePageResponse.self),
      let latest = page.candles.first
    else { return nil }

    // 봉은 체결이 있어야 생긴다 → 현 세션에 아직 안 뛴 종목은 최신 봉이 곧 전일종가다.
    // 무조건 candles[1]로 고정하면 09:05에 미거래인 종목이 두 세션 전 종가를 세션 내내 분모로 쓴다.
    let previous: Candle
    if let sessionDay, latest.day != sessionDay {
      previous = latest
    } else {
      guard page.candles.count >= 2 else { return nil }  // 신규상장 등 count<2 인덱스 가드
      previous = page.candles[1]
    }

    // 국내는 일봉 종가가 NXT 시간외(~20:00) 마감가라 정규장 기준가와 다르다 — 실측(005930,
    // 2026-07-30): 일봉 213,500 vs 정규장 207,000. 토스 앱·웹 등락률은 정규장 기준가를 쓴다.
    var value = previous.closePrice
    var cacheable = true
    if market == .kr {
      switch await regularClose(code, on: previous.day) {
      case .value(let regular): value = regular
      case .absent: break  // 정규장 봉 자체가 없다(거래정지 등) → 일봉 종가가 유일한 대안, 캐시해도 된다
      case .failed: cacheable = false  // 일시 실패 → 시간외 값(최대 3.8%p 오차)을 세션 내내 굳히지 않는다
      }
    }
    guard let value else { return nil }
    if let sessionDay, cacheable { await prevCloses.store(value, for: code, on: sessionDay) }
    return value
  }

  /// 시장의 현재 세션일. clock 종목의 최신 일봉 날짜를 그대로 쓴다 — 종목 일봉과 같은 stamp
  /// 공간이라 DST·휴장·반휴장을 계산할 필요가 없고, 벽시계 날짜와 달리 롤 시각이 저절로 맞는다.
  /// 60초 캐시(`PrevCloseStore`) — 조회 실패는 캐시하지 않는다(다음 폴링에 재시도).
  private func sessionDay(_ market: Market) async -> String? {
    if let cached = await prevCloses.cachedSessionDay(market) { return cached }
    await awaitCandleSlot()
    let page = try? await api.get(
      "/api/v1/candles?symbol=\(market.clockSymbol)&interval=1d&count=1",
      as: CandlePageResponse.self)
    guard let day = page?.candles.first?.day else { return nil }
    await prevCloses.storeSessionDay(day, for: market)
    return day
  }

  /// 국내 정규장(15:30) 마감 체결가. `day`는 대상 거래일(`yyyy-MM-dd`, KST).
  /// 조회 실패(`failed`)와 봉 부재(`absent`)를 가른다 — 전자는 재시도해야 하고 후자는 확정이다.
  ///
  /// 그 날 정규장 봉이 없으면 API가 **직전 거래일의 시간외 봉**을 대신 준다(실측: 비거래일
  /// 2026-07-17 조회 → 07-16T20:00 봉). 그게 바로 이 메서드가 피하려는 값이라 날짜로 걸러낸다.
  private func regularClose(_ code: String, on day: String) async -> RegularClose {
    await awaitCandleSlot()
    // 15:32 KST = 같은 날 06:32Z. 그 이전 최신 1분봉 = 정규장 마감 체결(대개 15:31 동시호가).
    guard
      let page = try? await api.get(
        "/api/v1/candles?symbol=\(code)&interval=1m&count=1&before=\(day)T06:32:00Z",
        as: CandlePageResponse.self)
    else { return .failed }
    guard let bar = page.candles.first, bar.day == day, let close = bar.closePrice else { return .absent }
    return .value(close)
  }

  private enum RegularClose {
    case value(Double)
    case absent
    case failed
  }

  /// 등락 계산 단일 지점. 관심종목 행과 검색 결과가 같은 종목에서 다른 숫자를 내지 않게 여기로 모은다.
  private static func change(last: Double, prevClose prev: Double?) -> WatchChange {
    guard let prev, prev > 0 else { return .noPrevClose }
    let delta = last - prev
    let direction: Direction = delta > 0 ? .up : (delta < 0 ? .down : .flat)
    return .priced(changeAmount: abs(delta), ratePercent: abs(delta / prev * 100), direction: direction)
  }

  /// candles 호출 직전 페이싱. 슬롯 예약은 actor 안에서 원자적으로, 대기는 여기 밖에서 한다(`PrevCloseStore`).
  private func awaitCandleSlot() async {
    let delay = await prevCloses.reserveCandleSlot()
    // 취소되면 그대로 진행 — 페이싱 실패의 유일한 결과는 429이고 요청계층이 재시도한다.
    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
  }

  /// 전일종가 경로를 가르는 단일 술어 — 세션일 조회와 정규장 보정이 갈라지지 않게 한 곳에 둔다.
  private static func market(_ currency: Currency) -> Market { currency.isUSD ? .us : .kr }

  private static func clean(_ s: String) -> String {
    String(s.filter { $0 != "\t" && $0 != "\n" && $0 != "|" })
  }
}

// ── 헤드리스 검증용 덤프(--dump). GUI와 무관, 실제 API 응답으로 데이터 레이어 회귀 확인. ──
enum Dump {
  static func runBlocking() {
    let sem = DispatchSemaphore(value: 0)
    Task {
      await run()
      sem.signal()
    }
    sem.wait()
  }

  static func run() async {
    let api = TossAPI(tokens: TokenStore())
    let service = TossService(api: api)

    await dumpPacing()

    print("=== auth ===")
    do {
      let a = try await service.authStatus()
      print(
        "  accountNo=\(mask(a.accountNo)) seq=\(a.accountSeq) expiry=\(a.expiresAt.map(String.init(describing:)) ?? "nil")"
      )
    } catch { print("  FAILED: \(error)") }

    print("=== holdings (positionRows) ===")
    do {
      let rows = try await service.positionRows()
      print("  count=\(rows.count)")
      for r in rows {
        print(
          "  [\(tag(r.currency))] \(r.id) \(r.name)  last=\(r.lastPrice)  pct=\(String(format: "%+.2f", r.ratePercent))%  pnl=\(r.pnlAmount)  \(r.direction)"
        )
      }
    } catch { print("  FAILED: \(error)") }

    print("=== watchRows ===")
    do {
      let rows = try await service.watchRows(Watchlist.read())
      print("  count=\(rows.count)")
      for r in rows {
        print(
          "  [\(tag(r.currency))] \(r.id) row=\(r.rowName) title=\(r.titleName) last=\(r.lastPrice) change=\(r.change) resolved=\(r.resolvedName ?? "-")"
        )
      }
    } catch { print("  FAILED: \(error)") }

    await dumpSearch(api: api, service: service)
  }

  /// 유니버스 수집 → 로컬 검색 → 시세 스트림. 검색 경로 전체를 GUI 없이 한 번 통과시킨다.
  private static func dumpSearch(api: TossAPI, service: TossService) async {
    print("=== stock universe ===")
    let universe = StockUniverse(api: api)
    for await progress in await universe.load() {
      switch progress {
      case .fetching(let done, let total): print("  수집 \(done)/\(total)")
      case .finished(let count, let failedMarkets):
        print("  count=\(count) failed=\(failedMarkets.isEmpty ? "-" : failedMarkets.joined(separator: ","))")
      }
    }

    for query in ["삼성전자", "AAPL"] {
      let hits = await universe.search(query, limit: 3)
      print("=== search \"\(query)\" ===")
      print("  hits=\(hits.map { "\($0.symbol)/\($0.name)/\($0.market)" }.joined(separator: "  "))")
      for await update in service.quotes(for: hits.map(\.symbol)) {
        print("  \(update)")
      }
    }
  }

  /// candles 슬롯 예약이 동시 호출자에서도 간격을 지키는지. 폴링과 검색이 함께 도는 상황의 계약이다.
  /// 예약이 원자적이지 않으면 여러 호출자가 같은 슬롯을 받아 간격이 0으로 붕괴한다(2026-08-13 실측).
  private static func dumpPacing() async {
    let store = PrevCloseStore()
    var delays: [TimeInterval] = []
    await withTaskGroup(of: TimeInterval.self) { group in
      for _ in 0..<6 { group.addTask { await store.reserveCandleSlot() } }
      for await delay in group { delays.append(delay) }
    }
    delays.sort()
    let gaps = zip(delays.dropFirst(), delays).map { $0 - $1 }
    let collapsed = gaps.filter { $0 < 0.2 }.count
    print("=== candles 페이싱(동시 예약 6) ===")
    print("  대기 \(delays.map { String(format: "%.2f", $0) }.joined(separator: " "))")
    print("  간격 붕괴(0.2초 미만): \(collapsed)/\(gaps.count) \(collapsed == 0 ? "OK" : "FAIL")")
  }

  private static func tag(_ c: Currency) -> String {
    switch c {
    case .krw: "KRW"
    case .usd: "USD"
    case .unknown(let s): "?\(s)"
    }
  }
  private static func mask(_ no: String) -> String {
    no.count <= 4 ? no : String(repeating: "*", count: no.count - 4) + no.suffix(4)
  }
}
