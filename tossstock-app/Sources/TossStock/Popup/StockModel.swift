import Foundation

// ─────────────────────────────────────────────────────────────
// StockModel — @MainActor @Observable. 폴링 루프 소유 + 회전 타이틀 계산.
// service 결과를 메인에서 '대입만'. 네트워크는 service(off-actor)에서, holdings·watch는 async let 병렬.
// 섹션 통째 실패 시 .failed("조회 실패" 표시). watch 개별 누락은 row 단위 lookupFailed.
// ─────────────────────────────────────────────────────────────

enum LoadState<Row: Sendable>: Sendable {
  case idle
  case loaded([Row])
  case failed
}

enum AuthCheck: Sendable {
  case none, checking
  case ok(accountNo: String, seq: Int, expiry: Date?)
  case rateLimited(seq: Int?, expiry: Date?)
  case failed
}

/// 종목 검색용 유니버스 확보 상태. `partial`은 일부 마켓 수집 실패 — 검색은 되지만 목록에 구멍이 있다.
enum UniverseState: Sendable, Equatable {
  case idle
  case loading(done: Int, total: Int)
  case ready(partial: Bool)
  case unavailable
}

@MainActor
@Observable
final class StockModel {
  private(set) var holdings: LoadState<PositionRow> = .idle
  private(set) var watch: LoadState<WatchRow> = .idle
  private(set) var watchSymbols: [WatchSymbol] = []
  private(set) var lastUpdated: Date?
  private(set) var rotationIndex = 0
  private(set) var needsCredentials = false
  private(set) var authCheck: AuthCheck = .none
  private(set) var universeState: UniverseState = .idle
  private(set) var searchResults: [SearchRow] = []

  static let searchLimit = 8

  private let service: TossService
  private let universe: StockUniverse
  private var pollTask: Task<Void, Never>?
  private var authDismissTask: Task<Void, Never>?
  private var universeTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?

  init(service: TossService = TossService(api: TossAPI(tokens: TokenStore()))) {
    self.service = service
    self.universe = StockUniverse(api: service.api)
    needsCredentials = !TokenStore.hasCredentials()
    if !needsCredentials { start() }  // 자격증명 없으면 폴링 보류(무의미한 401 방지)
  }

  func start() {
    guard pollTask == nil else { return }
    watchSymbols = Watchlist.read()
    // RunLoop Timer 금지. Task.sleep는 런루프 모드 무관 → 팝업 펼친 채로도 동작.
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }  // 인스턴스 폐기 시 루프 자가 종료(@State 중복 평가 대비)
        await self.refresh()
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  func refreshNow() { Task { await refresh() } }

  /// 관심종목 추가/삭제 후 호출(symbols.tsv 재로딩 + 즉시 갱신).
  func reloadWatchlist() {
    watchSymbols = Watchlist.read()
    syncWatchedFlags()
    refreshNow()
  }

  // ── 관심종목 CRUD (파일 기록 + 인메모리 즉시 반영. 삭제·별칭수정은 네트워크 불필요) ──

  /// 추가. 새 행 시세·등락은 네트워크가 필요하므로 refreshNow로 채운다(관리 목록엔 즉시 노출). 중복이면 false.
  @discardableResult
  func addWatch(code: String, alias: String) -> Bool {
    guard Watchlist.add(code: code, alias: alias) else { return false }
    reloadWatchlist()
    return true
  }

  /// 삭제. 파일·watchSymbols·로드된 행에서 즉시 제거(다음 폴링까지 안 기다림).
  func removeWatch(code rawCode: String) {
    Watchlist.remove(code: rawCode)
    watchSymbols = Watchlist.read()
    syncWatchedFlags()
    guard case .loaded(var rows) = watch else { return }
    rows.removeAll { $0.id == Watchlist.cleanCode(rawCode) }
    watch = .loaded(rows)
  }

  /// 별칭 수정. 파일·watchSymbols 갱신 + 로드된 행 표시명 즉시 재계산(lookupFailed 행은 코드 표시 유지).
  func setWatchAlias(code rawCode: String, alias: String) {
    Watchlist.setAlias(code: rawCode, alias: alias)
    watchSymbols = Watchlist.read()
    let code = Watchlist.cleanCode(rawCode)
    guard case .loaded(var rows) = watch, let i = rows.firstIndex(where: { $0.id == code }) else { return }
    if case .lookupFailed = rows[i].change { return }
    rows[i] = rows[i].relabeled(alias: watchSymbols.first { $0.code == code }?.alias ?? "")
    watch = .loaded(rows)
  }

  /// 삭제 메뉴 라벨용: 종목명(조회 성공시).
  func resolvedName(_ code: String) -> String? {
    if case .loaded(let rows) = watch { return rows.first { $0.id == code }?.resolvedName }
    return nil
  }

  /// 보유종목 표시명에 별칭 병기: 코드가 관심종목에 별칭으로 등록돼 있으면 "종목명 · 별칭", 없으면 종목명. §3.2
  func aliased(_ name: String, for code: String) -> String {
    guard let alias = watchSymbols.first(where: { $0.code == code })?.alias, !alias.isEmpty else { return name }
    return "\(name) · \(alias)"
  }

  // ── 종목 검색 (유니버스 로컬 검색 + 시세·등락 점진 채움) ──

  /// 유니버스 확보 시작. 관심종목 관리 섹션을 처음 펼칠 때 부른다.
  /// 콜드 수집은 마켓 7개 × 1.2초라 8초쯤 걸리므로, 검색을 안 쓰는 세션에서는 아예 시작하지 않는다.
  func prepareSearch() {
    guard universeTask == nil else { return }
    universeTask = Task { [weak self] in
      guard let self else { return }
      for await progress in await self.universe.load() {
        switch progress {
        case .fetching(let done, let total):
          self.universeState = .loading(done: done, total: total)
        case .finished(let count, let failedMarkets):
          self.universeState = count > 0 ? .ready(partial: !failedMarkets.isEmpty) : .unavailable
          // 전량 실패면 가드를 풀어 다음 펼침에 다시 받는다. 안 풀면 메뉴바 앱이 몇 주씩 떠 있는 동안
          // 복구 수단이 앱 재시작뿐이다. 부분 실패는 검색이 되므로 경고만 두고 재수집하지 않는다.
          if count == 0 { self.universeTask = nil }
        }
      }
    }
  }

  /// 질의 변경. 350ms 디바운스 후 로컬 검색 → 가격 배치 → 등락 순으로 채운다.
  /// 한글은 자모 조합 단계마다 `onChange`가 오므로 디바운스가 짧으면 조합 중간 질의로 시세를 부른다.
  func search(_ query: String) {
    searchTask?.cancel()
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
      searchResults = []
      return
    }
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, let self else { return }
      await self.runSearch(query)
    }
  }

  private func runSearch(_ query: String) async {
    let hits = await universe.search(query, limit: Self.searchLimit)
    guard !Task.isCancelled else { return }
    let watched = Set(watchSymbols.map(\.code))
    searchResults = hits.map { SearchRow(entry: $0, isWatched: watched.contains($0.symbol)) }
    guard !searchResults.isEmpty else { return }

    for await update in service.quotes(for: searchResults.map(\.id)) {
      guard !Task.isCancelled else { return }
      apply(update)
    }
  }

  private func apply(_ update: QuoteUpdate) {
    switch update {
    case .priced(let symbol, let lastPrice, let currency):
      guard let i = searchResults.firstIndex(where: { $0.id == symbol }) else { return }
      searchResults[i].lastPrice = lastPrice
      searchResults[i].currency = currency
    case .unavailable(let symbol):
      guard let i = searchResults.firstIndex(where: { $0.id == symbol }) else { return }
      searchResults[i].change = .lookupFailed
    case .changed(let symbol, let change):
      guard let i = searchResults.firstIndex(where: { $0.id == symbol }) else { return }
      searchResults[i].change = change
    }
  }

  /// 검색 결과의 등록 표시를 현재 관심종목에 맞춘다. 결과를 다시 조회하지 않고 플래그만 고친다.
  private func syncWatchedFlags() {
    guard !searchResults.isEmpty else { return }
    let watched = Set(watchSymbols.map(\.code))
    for i in searchResults.indices {
      searchResults[i].isWatched = watched.contains(searchResults[i].id)
    }
  }

  /// 앱 내 인증 점검(토큰 발급 + accounts 조회). 429면 캐시 폴백.
  func checkAuth() {
    authDismissTask?.cancel()  // 직전 점검의 자동 숨김 타이머 취소
    if !TokenStore.hasCredentials() {
      needsCredentials = true
      authCheck = .failed
      return
    }
    needsCredentials = false
    if pollTask == nil { start() }
    authCheck = .checking
    Task {
      do {
        let s = try await service.authStatus()
        authCheck = .ok(accountNo: s.accountNo, seq: s.accountSeq, expiry: s.expiresAt)
      } catch TossError.http(429) {
        let info = await service.cachedAuthInfo()
        authCheck = .rateLimited(seq: info.seq, expiry: info.expiry)
      } catch {
        authCheck = .failed
      }
      scheduleAuthDismiss()
    }
  }

  /// 인증 점검 결과는 상시 노출하지 않는다 — 누른 뒤 잠깐만 보여주고 자동으로 숨긴다.
  private func scheduleAuthDismiss() {
    authDismissTask?.cancel()
    authDismissTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      self?.authCheck = .none
    }
  }

  private func refresh() async {
    let svc = service
    let syms = watchSymbols
    // 서로 다른 rate 그룹 → off-actor 병렬. 섹션 throw는 .failed로 격리.
    async let h: LoadState<PositionRow> = {
      do { return .loaded(try await svc.positionRows()) } catch { return .failed }
    }()
    async let w: LoadState<WatchRow> = {
      guard !syms.isEmpty else { return .loaded([]) }
      do { return .loaded(try await svc.watchRows(syms)) } catch { return .failed }
    }()
    let (hr, wr) = await (h, w)
    holdings = applyHoldingsOrder(hr)  // 매 갱신마다 저장된 사용자 순서 재적용
    watch = reconcileWatch(wr)  // fetch 결과를 '현재' watchSymbols에 맞춤(in-flight 레이스 차단)
    lastUpdated = Date()
    advanceRotation()
  }

  private func applyHoldingsOrder(_ state: LoadState<PositionRow>) -> LoadState<PositionRow> {
    guard case .loaded(let rows) = state else { return state }
    return .loaded(HoldingsOrder.sorted(rows, by: \.id))
  }

  /// 폴링 커밋 시 fetch 결과를 '현재' watchSymbols에 정합(applyHoldingsOrder와 대칭).
  /// refresh()가 캡처한 옛 syms로 만든 행이 그 사이 일어난 삭제/별칭수정/재배치를 되돌리는 레이스를 차단한다.
  /// 삭제된 코드는 버리고, 별칭은 현재 값으로 relabel, 순서는 watchSymbols 기준. lookupFailed 행은 코드 표시 유지.
  private func reconcileWatch(_ state: LoadState<WatchRow>) -> LoadState<WatchRow> {
    guard case .loaded(let fetched) = state else { return state }
    let aliasBy = Dictionary(watchSymbols.map { ($0.code, $0.alias) }, uniquingKeysWith: { a, _ in a })
    let rank = Dictionary(watchSymbols.enumerated().map { ($1.code, $0) }, uniquingKeysWith: { a, _ in a })
    let reconciled =
      fetched
      .filter { rank[$0.id] != nil }
      .map { row -> WatchRow in
        if case .lookupFailed = row.change { return row }
        return row.relabeled(alias: aliasBy[row.id] ?? "")
      }
      .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    return .loaded(reconciled)
  }

  // ── 드래그 재배치 (네트워크 없음: 인메모리 재정렬 + 즉시 영속화) ──

  /// 관심종목 from → to 인덱스로 이동(to = 이동 후 최종 위치). watchSymbols·로드된 행 재정렬 + symbols.tsv 저장.
  func moveWatch(from: Int, to: Int) {
    guard from != to, watchSymbols.indices.contains(from), to >= 0, to < watchSymbols.count else { return }
    let moved = watchSymbols.remove(at: from)
    watchSymbols.insert(moved, at: to)
    Watchlist.save(watchSymbols)
    if case .loaded(var rows) = watch {  // 로드된 행도 같은 순서로 즉시 반영(다음 폴링까지 안 기다림)
      let rank = Dictionary(watchSymbols.enumerated().map { ($1.code, $0) }, uniquingKeysWith: { a, _ in a })
      rows.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
      watch = .loaded(rows)
    }
  }

  /// 보유종목 from → to 인덱스로 이동(to = 이동 후 최종 위치). 로드된 행 재정렬 + holdings_order.txt 저장.
  func moveHolding(from: Int, to: Int) {
    guard from != to, case .loaded(var rows) = holdings,
      rows.indices.contains(from), to >= 0, to < rows.count
    else { return }
    let moved = rows.remove(at: from)
    rows.insert(moved, at: to)
    holdings = .loaded(rows)
    HoldingsOrder.write(rows.map(\.id))
  }

  // ── 회전 타이틀 (보유 우선 → 관심 폴백 → 종목 없음) ──
  var titleText: String {
    let titles = titleCandidates()
    guard !titles.isEmpty else { return "📈 종목 없음" }
    return titles[rotationIndex % titles.count]
  }

  private func advanceRotation() {
    let n = titleCandidates().count
    rotationIndex = n == 0 ? 0 : (rotationIndex + 1) % n
  }

  private func titleCandidates() -> [String] {
    if case .loaded(let rows) = holdings, !rows.isEmpty {
      // 메뉴바에 뜨는 보유종목이 관심종목(symbols.tsv)에 별칭으로 등록돼 있으면 종목명 대신 별칭. §3.1
      let aliasBy = Dictionary(
        watchSymbols.compactMap { $0.alias.isEmpty ? nil : ($0.code, $0.alias) },
        uniquingKeysWith: { a, _ in a })
      return rows.map { r in
        let name = aliasBy[r.id] ?? r.name
        let pct = Format.pctSigned(r.ratePercent, r.direction)
        return "\(name) \(Format.price(r.lastPrice, r.currency)) \(pct)"
      }
    }
    if case .loaded(let rows) = watch, !rows.isEmpty {
      return rows.map(Self.watchTitle)
    }
    return []
  }

  private static func watchTitle(_ r: WatchRow) -> String {
    switch r.change {
    case .lookupFailed:
      return "\(r.id) ⚠️"
    case .noPrevClose:
      return "\(r.titleName) \(Format.price(r.lastPrice, r.currency))"
    case .priced(_, let rate, let dir):
      return "\(r.titleName) \(Format.price(r.lastPrice, r.currency)) \(Format.arrow(dir))\(Format.pctAbs(rate))"
    }
  }
}
