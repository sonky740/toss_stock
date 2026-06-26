import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────
// PopupView — 펼친 채 실시간 갱신되는 드롭다운 (다크 "Color pill" 리디자인, Claude Design 02안).
//   섹션마다 아이콘 배지 헤더 + 행별 색 액센트 바 + 등락률 색 배지(pill).
//   상승 초록(#34d399) / 하락 빨강(#f87171) / 보합·실패 회색(앱 색 규칙 유지).
//   보유 → 관심 → 관심종목 관리(인라인 추가/삭제) → 하단(새로고침·인증 점검·종료).
//   자격증명 미설정이면 설정 안내만 표시. 폰트는 시스템 + 숫자만 monospaced.
// ─────────────────────────────────────────────────────────────

struct PopupView: View {
    let model: StockModel
    @State private var newCode = ""
    @State private var newAlias = ""
    @State private var contentHeight: CGFloat = 0
    @State private var manageExpanded = false
    @State private var drag: DragSession?          // 활성 드래그 재배치 세션(섹션 공유)

    var body: some View {
        Group {
            if model.needsCredentials {
                setupGuidance
            } else {
                main
            }
        }
        .frame(width: 360)
        .background { Palette.bg.ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    holdingsSection
                    sectionDivider
                    watchSection
                    sectionDivider
                    manageSection
                }
                .padding(.bottom, 8)
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
            .scrollDisabled(drag != nil)  // 드래그 재배치 중 스크롤 충돌 방지
            hairline                      // 하단 풀폭 구분선
            footer
        }
    }

    // ── 보유종목 ──
    @ViewBuilder private var holdingsSection: some View {
        sectionHeader(badgeBG: Palette.indigoBG, symbol: "chart.bar.fill", badgeTint: Palette.indigo,
                      title: "내 보유종목", subtitle: "매입가 대비")
        switch model.holdings {
        case .idle: placeholder("불러오는 중…")
        case .failed: placeholder("보유종목 조회 실패 (인증 확인)")
        case .loaded(let rows):
            if rows.isEmpty { placeholder("보유종목 없음") }
            else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    positionRow(r).modifier(Reorderable(
                        section: .holding, index: i, count: rows.count, drag: $drag,
                        commit: { from, to in
                            withAnimation(.snappy(duration: 0.22)) { model.moveHolding(from: from, to: to) }
                        }))
                }
            }
        }
    }

    private func positionRow(_ r: PositionRow) -> some View {
        pillRow(name: r.name,
                price: Fmt.price(r.lastPrice, r.currency),
                pctText: Fmt.pctSigned(r.ratePercent, r.direction),
                pnlText: Fmt.pnl(r.pnlAmount, r.currency),
                direction: r.direction)
    }

    // ── 관심종목 ──
    @ViewBuilder private var watchSection: some View {
        sectionHeader(badgeBG: Palette.amberBG, symbol: "star.fill", badgeTint: Palette.amber,
                      title: "관심종목", subtitle: "당일 등락")
        switch model.watch {
        case .idle: placeholder("불러오는 중…")
        case .failed: placeholder("관심종목 조회 실패")
        case .loaded(let rows):
            if rows.isEmpty { placeholder("관심종목 없음") }
            else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    watchRow(r).modifier(Reorderable(
                        section: .watch, index: i, count: rows.count, drag: $drag,
                        commit: { from, to in
                            withAnimation(.snappy(duration: 0.22)) { model.moveWatch(from: from, to: to) }
                        }))
                }
            }
        }
    }

    @ViewBuilder private func watchRow(_ r: WatchRow) -> some View {
        switch r.change {
        case .priced(let chg, let rate, let dir):
            pillRow(name: r.rowName,
                    price: Fmt.price(r.lastPrice, r.currency),
                    pctText: "\(Fmt.arrow(dir))\(Fmt.pctAbs(rate))",
                    pnlText: "\(Fmt.arrow(dir))\(Fmt.changeAbs(chg, r.currency))",
                    direction: dir)
        case .noPrevClose:
            noteRow(name: r.rowName, price: Fmt.price(r.lastPrice, r.currency), note: "등락 데이터 없음")
        case .lookupFailed:
            noteRow(name: r.rowName, price: nil, note: "조회실패 (코드/인증 확인)")
        }
    }

    // ── 공통 행: 색 액센트 바 + 종목/현재가 + 등락 pill + 손익 ──
    private func pillRow(name: String, price: String, pctText: String, pnlText: String, direction: Direction) -> some View {
        let tint = tintColor(direction)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Text(price)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.priceMono)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(pctText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(pillColor(direction), in: RoundedRectangle(cornerRadius: 5))
                Text(pnlText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.82))
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 29).padding(.trailing, 15)
        .accentBar(tint)
    }

    // 등락 데이터 없음 / 조회실패 — pill 없이 보조색 노트.
    private func noteRow(name: String, price: String?, note: String) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                if let price {
                    Text(price)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.priceMono)
                }
            }
            Spacer(minLength: 8)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 6)
        .padding(.leading, 29).padding(.trailing, 15)
        .accentBar(Palette.neutral)
    }

    // ── 관심종목 관리 (인라인 추가/삭제) ──
    @ViewBuilder private var manageSection: some View {
        // 헤더 전체(화살표+배지+텍스트)를 클릭 가능하게 — DisclosureGroup은 chevron만 히트되는 문제 회피.
        Button {
            manageExpanded.toggle()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.priceMono)
                    .rotationEffect(.degrees(manageExpanded ? 90 : 0))
                iconBadge(bg: Palette.manageBG, symbol: "slider.horizontal.3", tint: Palette.manageTint)
                Text("관심종목 관리")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("추가 · 삭제")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 15).padding(.vertical, 5)
        }
        .buttonStyle(.plain)

        if manageExpanded {
            HStack(spacing: 6) {
                darkField("코드 (005930 / AAPL / 0190C0)", text: $newCode)
                darkField("별칭(선택)", text: $newAlias)
                Button { add() } label: {
                    Text("추가")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 7)
                        .background(Palette.addBtn, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(newCode.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 15).padding(.top, 2).padding(.bottom, 9)

            ForEach(model.watchSymbols) { sym in manageRow(sym) }
        }
    }

    private func manageRow(_ sym: WatchSymbol) -> some View {
        HStack(spacing: 8) {
            Text(manageLabel(sym))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.manageLabel)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text("(\(sym.code))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.time)
            Button {
                Watchlist.remove(code: sym.code)
                model.reloadWatchlist()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.priceMono)
                    .frame(width: 20, height: 20)
                    .background(Palette.deleteBG, in: Circle())
            }
            .buttonStyle(.plain)
            .help("삭제")
        }
        .padding(.horizontal, 15).padding(.vertical, 6)
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

    // ── 하단 ──
    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            authResultLine
            HStack(spacing: 8) {
                footerButton(icon: "arrow.clockwise", title: "새로고침") { model.refreshNow() }
                footerButton(title: "인증 점검") { model.checkAuth() }
                Spacer()
                if let updated = model.lastUpdated {
                    Text(updated.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.time)
                }
                footerButton(title: "종료", tint: Palette.quit, hasBG: false) { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
    }

    @ViewBuilder private var authResultLine: some View {
        switch model.authCheck {
        case .none: EmptyView()
        case .checking:
            authText("인증 확인 중…", Palette.textSecondary)
        case .ok(let no, let seq, let exp):
            authText("인증 OK · 계좌 \(mask(no)) (seq \(seq)) · 토큰 만료 \(expiryText(exp))", Palette.up)
        case .rateLimited(let seq, let exp):
            authText("rate limit(분당 1회) · 캐시 seq \(seq.map(String.init) ?? "?") · 만료 \(expiryText(exp))", Palette.textSecondary)
        case .failed:
            authText("인증 실패 — auth.env 의 client_id/secret 확인", Palette.down)
        }
    }

    private func authText(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color)
    }

    // ── 자격증명 설정 안내 ──
    private var setupGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🔐 Toss API 설정 필요")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text("~/.config/tossstock/auth.env 에 작성:")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            Text("TOSS_CLIENT_ID='...'\nTOSS_CLIENT_SECRET='...'")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textPrimary)
                .padding(8)
                .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.fieldBorder, lineWidth: 1))
            Link("토스증권 Open API 발급 안내", destination: URL(string: "https://developers.tossinvest.com/docs")!)
                .font(.system(size: 12))
                .tint(Palette.indigo)
            HStack {
                footerButton(title: "다시 확인") { model.checkAuth() }
                Spacer()
                footerButton(title: "종료", tint: Palette.quit, hasBG: false) { NSApp.terminate(nil) }
            }
        }
        .padding(16)
    }

    // ── 구성요소 ──
    private func sectionHeader(badgeBG: Color, symbol: String, badgeTint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 9) {
            iconBadge(bg: badgeBG, symbol: symbol, tint: badgeTint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 7)
    }

    private func iconBadge(bg: Color, symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(bg)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            )
    }

    private func footerButton(icon: String? = nil, title: String, tint: Color = Palette.footerText, hasBG: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(hasBG ? AnyShapeStyle(Palette.footerBtnBG) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func darkField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.fieldBorder, lineWidth: 1))
            .frame(maxWidth: .infinity)
    }

    private var sectionDivider: some View {
        hairline.padding(.horizontal, 15).padding(.vertical, 8)
    }

    private var hairline: some View {
        Rectangle().fill(Palette.divider).frame(height: 1)
    }

    // ── helpers ──
    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 15).padding(.vertical, 6)
    }

    private func tintColor(_ d: Direction) -> Color {
        switch d {
        case .up: Palette.up
        case .down: Palette.down
        case .flat: Palette.neutral
        }
    }

    private func pillColor(_ d: Direction) -> Color {
        switch d {
        case .up: Palette.upPill
        case .down: Palette.downPill
        case .flat: Palette.neutralPill
        }
    }

    private func mask(_ no: String) -> String {
        no.count <= 4 ? no : String(repeating: "•", count: max(0, no.count - 4)) + no.suffix(4)
    }

    private func expiryText(_ d: Date?) -> String {
        // 토큰은 ~24h 유효 → 만료가 익일인 경우가 많아 시간만 표기하면 당일로 오해. 월·일 병기.
        d?.formatted(.dateTime.month().day().hour().minute()) ?? "?"
    }
}

// 행 좌측 색 액센트 바(3px). 그리디 셰이프가 행 높이를 부풀리지 않도록 overlay로 그린다.
private extension View {
    func accentBar(_ color: Color) -> some View {
        overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
                .padding(.leading, 15)
                .padding(.vertical, 6)
        }
    }
}

// ── 드래그 재배치 (수동 DragGesture) ──
// 메뉴바 .window 는 비활성 창이라 AppKit NSDraggingSession(.draggable)이 시작되지 않는다.
// 버튼 탭과 동일한 마우스 이벤트 스트림을 타는 SwiftUI DragGesture로 직접 구현한다.
// macOS ScrollView는 휠/투핑거로 스크롤하지 클릭-드래그로 하지 않으므로 롱프레스 게이트가 불필요.
// 누르고 바로 끌면 잡히도록 순수 DragGesture + highPriorityGesture(스크롤뷰 내부 인식기보다 우선).
enum ReorderSection { case holding, watch }

struct DragSession: Equatable {
    let section: ReorderSection
    let fromIndex: Int
    let rowHeight: CGFloat
    let count: Int
    var translation: CGFloat

    // 이동 후 최종 인덱스: 누적 이동량 / 행높이 반올림.
    var targetIndex: Int {
        guard rowHeight > 0 else { return fromIndex }
        let delta = Int((translation / rowHeight).rounded())
        return min(max(fromIndex + delta, 0), count - 1)
    }
}

// 드롭 시 1회 커밋(commit-on-end) → 드래그 중 모델 변이 없음 → 10초 폴링과 충돌 없음.
private struct Reorderable: ViewModifier {
    let section: ReorderSection
    let index: Int
    let count: Int
    @Binding var drag: DragSession?
    let commit: (_ from: Int, _ to: Int) -> Void

    @State private var rowHeight: CGFloat = 44

    private var isDragging: Bool { drag?.section == section && drag?.fromIndex == index }
    private var isTarget: Bool {
        guard let d = drag, d.section == section, d.fromIndex != index else { return false }
        return d.targetIndex == index
    }

    func body(content: Content) -> some View {
        content
            // 왼쪽 바 영역만 드래그 핸들(아래). 시각 피드백·offset은 행 전체에 적용되도록 핸들을
            // content에 먼저 얹어 함께 변형시킨다.
            .overlay(alignment: .leading) { dragHandle }
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size.height, initial: true) { _, h in rowHeight = h }
            })
            .background(
                (isDragging ? Palette.dragLift : isTarget ? Palette.dropHi : Color.clear),
                in: RoundedRectangle(cornerRadius: isDragging ? 8 : 0)
            )
            .scaleEffect(isDragging ? 1.03 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.45 : 0), radius: isDragging ? 8 : 0, y: isDragging ? 3 : 0)
            .offset(y: isDragging ? (drag?.translation ?? 0) : 0)
            .zIndex(isDragging ? 1 : 0)
    }

    // 왼쪽 액센트 바 주변(28px) 투명 스트립만 드래그 트리거. 텍스트 영역은 드래그 안 됨.
    // 호버 시 펼친 손, 끄는 중 쥔 손 커서로 그랩 영역을 알린다.
    private var dragHandle: some View {
        Color.clear
            .frame(width: 28)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard drag == nil else { return }   // 드래그 중엔 쥔 손(아래 gesture) 유지
                switch phase {
                case .active: NSCursor.openHand.set()
                case .ended:  NSCursor.arrow.set()
                }
            }
            .highPriorityGesture(
                // .global 필수: 행이 자기 translation 만큼 .offset 되므로, .local 이면 좌표공간이 함께
                // 움직여 translationₙ = T − translationₙ₋₁ 진동(격렬한 흔들림)이 생긴다. 화면 고정 공간으로 차단.
                DragGesture(minimumDistance: 5, coordinateSpace: .global)
                    .onChanged { value in
                        NSCursor.closedHand.set()
                        drag = DragSession(section: section, fromIndex: index, rowHeight: rowHeight,
                                           count: count, translation: value.translation.height)
                    }
                    .onEnded { _ in
                        if let s = drag, s.section == section, s.fromIndex == index {
                            let to = s.targetIndex
                            if to != s.fromIndex { commit(s.fromIndex, to) }
                        }
                        drag = nil
                        NSCursor.arrow.set()
                    }
            )
    }
}

// 다크 "Color pill" 팔레트 (Claude Design 02안 hex 그대로).
private enum Palette {
    static let bg            = Color(hex: 0x16161A)
    static let divider       = Color(hex: 0x232329)
    static let textPrimary   = Color(hex: 0xECECF0)
    static let textSecondary = Color(hex: 0x76767E)
    static let priceMono     = Color(hex: 0x7E7E88)
    static let manageLabel   = Color(hex: 0xDCDCE2)
    static let time          = Color(hex: 0x6F6F78)

    static let up            = Color(hex: 0x34D399)
    static let down          = Color(hex: 0xF87171)
    static let neutral       = Color(hex: 0x9A9AA3)
    static let upPill        = Color(hex: 0x34D399, alpha: 0.14)
    static let downPill      = Color(hex: 0xF87171, alpha: 0.14)
    static let neutralPill   = Color(hex: 0xFFFFFF, alpha: 0.08)

    static let indigo        = Color(hex: 0xA5B4FC)
    static let indigoBG      = Color(hex: 0x818CF8, alpha: 0.15)
    static let amber         = Color(hex: 0xFBBF24)
    static let amberBG       = Color(hex: 0xFBBF24, alpha: 0.14)
    static let manageTint    = Color(hex: 0x9A9AA3)
    static let manageBG      = Color(hex: 0xFFFFFF, alpha: 0.07)

    static let addBtn        = Color(hex: 0x4F46E5)
    static let fieldBG       = Color(hex: 0x0D0D10)
    static let fieldBorder   = Color(hex: 0x2B2B31)
    static let deleteBG      = Color(hex: 0xFFFFFF, alpha: 0.08)
    static let footerText    = Color(hex: 0xCFCFD6)
    static let footerBtnBG   = Color(hex: 0xFFFFFF, alpha: 0.06)
    static let quit          = Color(hex: 0xF0A0A0)

    static let dropHi        = Color(hex: 0x818CF8, alpha: 0.16)  // 드롭 타깃 슬롯 하이라이트
    static let dragLift      = Color(hex: 0x26262E)              // 들어올린 행(떠 있는 카드) 배경
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
