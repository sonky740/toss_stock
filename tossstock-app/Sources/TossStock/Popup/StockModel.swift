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

    private let service: TossService
    private var pollTask: Task<Void, Never>?
    private var authDismissTask: Task<Void, Never>?

    init(service: TossService = TossService(api: TossAPI(tokens: TokenStore()))) {
        self.service = service
        needsCredentials = !TokenStore.hasCredentials()
        if !needsCredentials { start() }   // 자격증명 없으면 폴링 보류(무의미한 401 방지)
    }

    func start() {
        guard pollTask == nil else { return }
        watchSymbols = Watchlist.read()
        // RunLoop Timer 금지. Task.sleep는 런루프 모드 무관 → 팝업 펼친 채로도 동작.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }   // 인스턴스 폐기 시 루프 자가 종료(@State 중복 평가 대비)
                await self.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refreshNow() { Task { await refresh() } }

    /// 관심종목 추가/삭제 후 호출(symbols.tsv 재로딩 + 즉시 갱신).
    func reloadWatchlist() {
        watchSymbols = Watchlist.read()
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

    /// 앱 내 인증 점검(토큰 발급 + accounts 조회). 429면 캐시 폴백.
    func checkAuth() {
        authDismissTask?.cancel()   // 직전 점검의 자동 숨김 타이머 취소
        if !TokenStore.hasCredentials() { needsCredentials = true; authCheck = .failed; return }
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
        holdings = applyHoldingsOrder(hr)   // 매 갱신마다 저장된 사용자 순서 재적용
        watch = reconcileWatch(wr)          // fetch 결과를 '현재' watchSymbols에 맞춤(in-flight 레이스 차단)
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
        let reconciled = fetched
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
        if case .loaded(var rows) = watch {     // 로드된 행도 같은 순서로 즉시 반영(다음 폴링까지 안 기다림)
            let rank = Dictionary(watchSymbols.enumerated().map { ($1.code, $0) }, uniquingKeysWith: { a, _ in a })
            rows.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
            watch = .loaded(rows)
        }
    }

    /// 보유종목 from → to 인덱스로 이동(to = 이동 후 최종 위치). 로드된 행 재정렬 + holdings_order.txt 저장.
    func moveHolding(from: Int, to: Int) {
        guard from != to, case .loaded(var rows) = holdings,
              rows.indices.contains(from), to >= 0, to < rows.count else { return }
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
            let aliasBy = Dictionary(watchSymbols.compactMap { $0.alias.isEmpty ? nil : ($0.code, $0.alias) },
                                     uniquingKeysWith: { a, _ in a })
            return rows.map { r in
                let name = aliasBy[r.id] ?? r.name
                return "\(name) \(Fmt.price(r.lastPrice, r.currency)) \(Fmt.pctSigned(r.ratePercent, r.direction))"
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
            return "\(r.titleName) \(Fmt.price(r.lastPrice, r.currency))"
        case .priced(_, let rate, let dir):
            return "\(r.titleName) \(Fmt.price(r.lastPrice, r.currency)) \(Fmt.arrow(dir))\(Fmt.pctAbs(rate))"
        }
    }
}
