import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────
// PopupView — 펼친 채 실시간 갱신되는 드롭다운.
//   보유/관심(색: 상승 green / 하락 red / 보합·실패 secondary) + 관심종목 관리(추가/삭제) + 하단(새로고침·인증 점검).
//   자격증명 미설정이면 설정 안내만 표시.
// ─────────────────────────────────────────────────────────────

struct PopupView: View {
    let model: StockModel
    @State private var newCode = ""
    @State private var newAlias = ""
    @State private var contentHeight: CGFloat = 0
    @State private var manageExpanded = false

    var body: some View {
        Group {
            if model.needsCredentials {
                setupGuidance
            } else {
                main
            }
        }
        .frame(width: 360)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    holdingsSection
                    Divider()
                    watchSection
                    Divider()
                    manageSection
                }
                .padding(14)
                // ScrollView는 고유 높이가 0 → self-sizing 윈도우(MenuBarExtra .window)에서 붕괴.
                // 콘텐츠 실측 높이로 ScrollView 높이를 고정(최대 520, 초과 시 스크롤).
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.height, initial: true) { _, h in
                            contentHeight = h
                        }
                    }
                )
            }
            .frame(height: min(max(contentHeight, 60), 520))
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // ── 보유종목 ──
    @ViewBuilder private var holdingsSection: some View {
        Text("📊 내 보유종목 비교 (매입가 대비)").font(.subheadline.weight(.semibold))
        switch model.holdings {
        case .idle: placeholder("불러오는 중…")
        case .failed: placeholder("보유종목 조회 실패 (인증 확인)")
        case .loaded(let rows):
            if rows.isEmpty { placeholder("보유종목 없음") }
            else { ForEach(rows) { positionRow($0) } }
        }
    }

    private func positionRow(_ r: PositionRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(r.name).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Fmt.price(r.lastPrice, r.currency)).foregroundStyle(.secondary).monospacedDigit()
                    Text(Fmt.pctSigned(r.ratePercent, r.direction)).fontWeight(.semibold).monospacedDigit().foregroundStyle(tint(r.direction))
                }
                Text(Fmt.pnl(r.pnlAmount, r.currency)).font(.caption2).monospacedDigit().foregroundStyle(tint(r.direction))
            }
            .font(.caption)
        }
    }

    // ── 관심종목 ──
    @ViewBuilder private var watchSection: some View {
        Text("⭐ 관심종목 (당일 등락)").font(.subheadline.weight(.semibold))
        switch model.watch {
        case .idle: placeholder("불러오는 중…")
        case .failed: placeholder("관심종목 조회 실패")
        case .loaded(let rows):
            if rows.isEmpty { placeholder("관심종목 없음") }
            else { ForEach(rows) { watchRow($0) } }
        }
    }

    private func watchRow(_ r: WatchRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(r.rowName).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            watchTrailing(r).font(.caption)
        }
    }

    @ViewBuilder private func watchTrailing(_ r: WatchRow) -> some View {
        switch r.change {
        case .lookupFailed:
            Text("조회실패 (코드/인증 확인)").foregroundStyle(.secondary)
        case .noPrevClose:
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.price(r.lastPrice, r.currency)).monospacedDigit()
                Text("등락 데이터 없음").font(.caption2)
            }.foregroundStyle(.secondary)
        case .priced(let chg, let rate, let dir):
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Fmt.price(r.lastPrice, r.currency)).foregroundStyle(.secondary).monospacedDigit()
                    Text("\(Fmt.arrow(dir))\(Fmt.pctAbs(rate))").fontWeight(.semibold).monospacedDigit().foregroundStyle(tint(dir))
                }
                Text("\(Fmt.arrow(dir))\(Fmt.changeAbs(chg, r.currency))").font(.caption2).monospacedDigit().foregroundStyle(tint(dir))
            }
        }
    }

    // ── 관심종목 관리 (Phase 4) ──
    @ViewBuilder private var manageSection: some View {
        // 헤더 전체(화살표+텍스트)를 클릭 가능하게 — DisclosureGroup은 chevron만 히트되는 문제 회피.
        Button {
            manageExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(manageExpanded ? 90 : 0))
                Text("관심종목 관리").font(.subheadline)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if manageExpanded {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("코드 (005930 / AAPL / 0190C0)", text: $newCode)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                    TextField("별칭(선택)", text: $newAlias)
                        .textFieldStyle(.roundedBorder)
                    Button("추가") { add() }.disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(model.watchSymbols) { sym in
                    HStack(spacing: 6) {
                        Text(manageLabel(sym)).font(.caption).lineLimit(1).truncationMode(.tail)
                        Text("(\(sym.code))").font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button {
                            Watchlist.remove(code: sym.code)
                            model.reloadWatchlist()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("삭제")
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func manageLabel(_ s: WatchSymbol) -> String {
        switch (model.resolvedName(s.code), s.alias.isEmpty) {
        case let (name?, false): "\(name) · \(s.alias)"
        case let (name?, true): name
        case (nil, false): s.alias
        case (nil, true): s.code
        }
    }

    private func add() {
        if Watchlist.add(code: newCode, alias: newAlias) {
            newCode = ""; newAlias = ""
            model.reloadWatchlist()
        }
    }

    // ── 하단 (Phase 5) ──
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            authResultLine
            HStack(spacing: 12) {
                Button { model.refreshNow() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                Button("인증 점검") { model.checkAuth() }
                Spacer()
                if let updated = model.lastUpdated {
                    Text(updated.formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("종료") { NSApp.terminate(nil) }
            }
            .font(.caption)
        }
    }

    @ViewBuilder private var authResultLine: some View {
        switch model.authCheck {
        case .none: EmptyView()
        case .checking:
            Text("인증 확인 중…").font(.caption2).foregroundStyle(.secondary)
        case .ok(let no, let seq, let exp):
            Text("인증 OK · 계좌 \(mask(no)) (seq \(seq)) · 토큰 만료 \(expiryText(exp))")
                .font(.caption2).foregroundStyle(.green)
        case .rateLimited(let seq, let exp):
            Text("rate limit(분당 1회) · 캐시 seq \(seq.map(String.init) ?? "?") · 만료 \(expiryText(exp))")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text("인증 실패 — auth.env 의 client_id/secret 확인").font(.caption2).foregroundStyle(.red)
        }
    }

    // ── 자격증명 설정 안내 ──
    private var setupGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🔐 Toss API 설정 필요").font(.headline)
            Text("~/.config/tossstock/auth.env 에 작성:").font(.caption).foregroundStyle(.secondary)
            Text("TOSS_CLIENT_ID='...'\nTOSS_CLIENT_SECRET='...'")
                .font(.system(.caption, design: .monospaced))
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Link("토스증권 Open API 발급 안내", destination: URL(string: "https://developers.tossinvest.com/docs")!)
                .font(.caption)
            HStack {
                Button("다시 확인") { model.checkAuth() }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }.font(.caption)
        }
        .padding(16)
    }

    // ── helpers ──
    private func placeholder(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func tint(_ d: Direction) -> AnyShapeStyle {
        switch d {
        case .up: AnyShapeStyle(.green)
        case .down: AnyShapeStyle(.red)
        case .flat: AnyShapeStyle(.secondary)
        }
    }

    private func mask(_ no: String) -> String {
        no.count <= 4 ? no : String(repeating: "•", count: max(0, no.count - 4)) + no.suffix(4)
    }

    private func expiryText(_ d: Date?) -> String {
        d?.formatted(date: .omitted, time: .shortened) ?? "?"
    }
}
