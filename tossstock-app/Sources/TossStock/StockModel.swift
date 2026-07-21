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

    /// 삭제 메뉴 라벨용: 종목명(조회 성공시).
    func resolvedName(_ code: String) -> String? {
        if case .loaded(let rows) = watch { return rows.first { $0.id == code }?.resolvedName }
        return nil
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
        watch = wr                          // 관심종목은 watchSymbols(=symbols.tsv) 순서로 이미 도착
        lastUpdated = Date()
        advanceRotation()
    }

    private func applyHoldingsOrder(_ state: LoadState<PositionRow>) -> LoadState<PositionRow> {
        guard case .loaded(let rows) = state else { return state }
        return .loaded(HoldingsOrder.sorted(rows, by: \.id))
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
            return rows.map { "\($0.name) \(Fmt.price($0.lastPrice, $0.currency)) \(Fmt.pctSigned($0.ratePercent, $0.direction))" }
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
