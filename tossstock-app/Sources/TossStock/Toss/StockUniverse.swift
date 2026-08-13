import Foundation

// ─────────────────────────────────────────────────────────────
// StockUniverse — 종목 검색용 전체 종목 목록(actor).
// 토스 Open API에 검색 엔드포인트가 없어(2026-08-13 OpenAPI 스펙 전수 확인) /stocks/all로
// 마켓별 전체 목록을 받아 로컬에서 찾는다. 실측 15,176종목 — 선형 스캔으로 충분하다.
// STOCK_ALL은 초당 1회 제한이고 일 배치 데이터라, 받은 결과를 universe.json에 하루 캐싱한다.
// ─────────────────────────────────────────────────────────────

struct UniverseEntry: Codable, Sendable, Identifiable {
  var id: String { symbol }
  let symbol: String
  let name: String
  let market: String
}

enum UniverseProgress: Sendable {
  case fetching(done: Int, total: Int)
  /// 실패한 마켓이 있어도 받은 만큼으로 검색은 된다. 대신 그 결과는 캐시하지 않는다.
  case finished(count: Int, failedMarkets: [String])
}

// universe.json 스키마. fetchedOn은 KST 달력 날짜다.
private struct UniverseCacheFile: Codable {
  let fetchedOn: String
  let stocks: [UniverseEntry]
}

actor StockUniverse {
  private let api: TossAPI
  private let config: ConfigPaths
  private var entries: [UniverseEntry] = []
  private var missingMarkets: [String] = []  // 마지막 수집에서 빠진 마켓. 재조회에도 경고가 유지되게 기억한다

  /// STOCK_ALL(초당 1회) 여유분. 마켓 7개라 콜드 수집에 약 8초가 든다.
  private static let callInterval: Duration = .milliseconds(1200)
  private static let markets = ["KOSPI", "KOSDAQ", "NYSE", "NASDAQ", "AMEX", "KR_ETC", "US_ETC"]

  init(api: TossAPI, config: ConfigPaths = .standard) {
    self.api = api
    self.config = config
  }

  var isReady: Bool { !entries.isEmpty }

  /// 유니버스를 확보한다. 오늘 받은 캐시가 있으면 그걸 쓰고, 없으면 마켓별로 새로 받는다.
  /// 진행 상황을 순서대로 흘리고 마지막에 `.finished`를 낸다. 이미 메모리에 있으면 즉시 끝난다.
  func load() -> AsyncStream<UniverseProgress> {
    AsyncStream { continuation in
      let task = Task { await self.fill(continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func fill(_ continuation: AsyncStream<UniverseProgress>.Continuation) async {
    if !entries.isEmpty {
      continuation.yield(.finished(count: entries.count, failedMarkets: missingMarkets))
      continuation.finish()
      return
    }
    if let cached = loadCache(), !cached.isEmpty {
      entries = cached
      missingMarkets = []  // 캐시는 완주한 수집만 저장되므로 빠진 마켓이 없다
      continuation.yield(.finished(count: cached.count, failedMarkets: []))
      continuation.finish()
      return
    }

    var collected: [String: UniverseEntry] = [:]  // 심볼 중복 제거
    var failed: [String] = []
    for (index, market) in Self.markets.enumerated() {
      // 취소면 아무것도 남기지 않고 빠진다 — 잘린 목록을 오늘 날짜로 캐시하면 하루 내내 구멍이 남는다.
      if Task.isCancelled {
        continuation.finish()
        return
      }
      if index > 0 { try? await Task.sleep(for: Self.callInterval) }
      continuation.yield(.fetching(done: index, total: Self.markets.count))
      do {
        let listed = try await api.get("/api/v1/stocks/all?market=\(market)", as: [ListedStock].self)
        for stock in listed {
          collected[stock.symbol] = UniverseEntry(symbol: stock.symbol, name: stock.name, market: market)
        }
      } catch {
        failed.append(market)
      }
    }

    entries = collected.values.sorted { $0.symbol < $1.symbol }
    missingMarkets = failed
    // 부분 수집을 캐시하면 빠진 종목이 하루 내내 안 잡힌다. 다음 시도에서 다시 받게 둔다.
    if failed.isEmpty && !entries.isEmpty { writeCache(entries) }
    continuation.yield(.finished(count: entries.count, failedMarkets: failed))
    continuation.finish()
  }

  /// 질의에 맞는 종목을 점수 순으로 최대 `limit`건.
  ///
  /// 심볼과 종목명 양쪽을 본다 — 이름만 보면 "AAPL"이 안 걸리고, 심볼만 보면 "삼성전자"가 안 걸린다.
  /// 미국 ETF 상당수는 종목명이 심볼과 같아 이름 매칭이 사실상 심볼 매칭이 되는 것도 감안한 것이다.
  func search(_ rawQuery: String, limit: Int) -> [UniverseEntry] {
    let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return [] }
    return
      entries
      .compactMap { entry -> (entry: UniverseEntry, score: Int)? in
        Self.score(entry, matching: query).map { (entry, $0) }
      }
      .sorted { ($0.score, $0.entry.symbol) < ($1.score, $1.entry.symbol) }
      .prefix(limit)
      .map(\.entry)
  }

  /// 낮을수록 먼저. 아무 데도 안 걸리면 nil.
  private static func score(_ entry: UniverseEntry, matching query: String) -> Int? {
    let symbol = entry.symbol.lowercased()
    let name = entry.name.lowercased()
    if symbol == query { return 0 }
    if name == query { return 1 }
    if symbol.hasPrefix(query) { return 2 }
    if name.hasPrefix(query) { return 3 }
    if name.contains(query) { return 4 }
    if symbol.contains(query) { return 5 }
    return nil
  }

  // ── universe.json I/O ──

  /// 오늘(KST) 받은 캐시만 유효로 본다.
  ///
  /// 여기서는 벽시계 날짜가 맞다. 전일종가 캐시(`PrevCloseStore`)가 날짜 키를 금지하는 이유는
  /// 세션 롤이 자정이 아니라 09:00 KST라 기준가가 한 세션 어긋나기 때문인데(§3.3), 유니버스는
  /// 일 배치 데이터라 갱신이 하루 늦어도 신규 상장 종목이 하루 늦게 검색될 뿐이다.
  private func loadCache() -> [UniverseEntry]? {
    guard let data = try? Data(contentsOf: config.universeJSON),
      let file = try? JSONDecoder().decode(UniverseCacheFile.self, from: data),
      file.fetchedOn == Self.today()
    else { return nil }
    return file.stocks
  }

  private func writeCache(_ stocks: [UniverseEntry]) {
    let file = UniverseCacheFile(fetchedOn: Self.today(), stocks: stocks)
    guard let data = try? JSONEncoder().encode(file) else { return }
    try? FileManager.default.createDirectory(at: config.dir, withIntermediateDirectories: true)
    try? data.write(to: config.universeJSON, options: .atomic)
  }

  private static func today() -> String {
    var formatter = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "Asia/Seoul") ?? .current)
    formatter = formatter.year().month().day().dateSeparator(.dash)
    return Date().formatted(formatter)
  }
}
