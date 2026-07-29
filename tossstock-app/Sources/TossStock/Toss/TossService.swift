import Foundation

// ─────────────────────────────────────────────────────────────
// TossService — 도메인 메서드 + Row 매핑.
//   positionRows: /holdings → 보유섹션(종목별 native 통화 손익)
//   watchRows   : /prices(batch) + /stocks(batch) + /candles(종목당 1, 0.25s 페이싱)
//                 → 관심섹션(현재가-전일종가 등락). prices 누락 코드는 줄단위 "조회실패" 격리.
//   authStatus  : 앱 내 인증 점검(토큰 발급 + accounts 조회)
// ─────────────────────────────────────────────────────────────

struct TossService: Sendable {
  let api: TossAPI

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

    var rows: [WatchRow] = []
    var firstCandle = true
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

      // candles(MARKET_DATA_CHART, limit 5/s): 연속 호출 사이 250ms 페이싱(앞 호출과만).
      if !firstCandle { try? await Task.sleep(for: .milliseconds(250)) }
      firstCandle = false
      let prev = await prevClose(sym.code)

      let change: WatchChange
      if let prev, prev > 0 {
        let chg = last - prev
        let dir: Direction = chg > 0 ? .up : (chg < 0 ? .down : .flat)
        change = .priced(changeAmount: abs(chg), ratePercent: abs(chg / prev * 100), direction: dir)
      } else {
        change = .noPrevClose
      }
      rows.append(
        WatchRow(
          id: sym.code, rowName: row, titleName: title,
          currency: price.currency, lastPrice: last, change: change, resolvedName: resolved))
    }
    return rows
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

  private func prevClose(_ code: String) async -> Double? {
    guard
      let page = try? await api.get(
        "/api/v1/candles?symbol=\(code)&interval=1d&count=2",
        as: CandlePageResponse.self),
      page.candles.count >= 2
    else { return nil }  // 신규상장 등 count<2 인덱스 가드
    return page.candles[1].closePrice
  }

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
    let service = TossService(api: TossAPI(tokens: TokenStore()))

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
