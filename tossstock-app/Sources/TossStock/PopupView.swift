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
    @State private var reorder = ReorderController()   // 드래그 재배치 세션 + edge 자동 스크롤(섹션 공유)
    @State private var editingCode: String?        // 별칭 인라인 편집 중인 행(코드). nil = 편집 없음
    @State private var editingAlias = ""
    @FocusState private var aliasFieldFocused: Bool

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
        .onDisappear { reorder.cancel() }   // 팝업 닫힘 등 onEnded 없이 중단 시 tick 루프 종료
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
                // 콘텐츠 서브트리에 심어 뒤의 NSScrollView 참조를 잡는다(드래그 edge 자동 스크롤용).
                .background(ScrollViewGrabber { reorder.attach($0) })
            }
            .frame(height: min(max(contentHeight, 60), 520))
            // 뷰포트(스크롤 안 되는 바깥 프레임)의 글로벌 위치 → 드래그 중 edge 밴드 판정 기준.
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, f in
                        reorder.setViewport(f)
                    }
                }
            )
            // scrollDisabled 없음: 자동 스크롤 델타(S)를 translation 에 실시간 합산해 정합하므로 desync 가드 불필요.
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
                        section: .holding, index: i, count: rows.count, controller: reorder,
                        commit: { from, to in
                            withAnimation(.snappy(duration: 0.22)) { model.moveHolding(from: from, to: to) }
                        }))
                }
            }
        }
    }

    private func positionRow(_ r: PositionRow) -> some View {
        pillRow(name: model.aliased(r.name, for: r.id),
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
                        section: .watch, index: i, count: rows.count, controller: reorder,
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

    @ViewBuilder private func manageRow(_ sym: WatchSymbol) -> some View {
        HStack(spacing: 8) {
            if editingCode == sym.code {
                // 별칭 인라인 편집 — 표시명 자리에 TextField. ✓/Enter 저장, ✗ 취소.
                TextField("별칭(비우면 제거)", text: $editingAlias)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textPrimary)
                    .focused($aliasFieldFocused)
                    .onSubmit { commitAliasEdit(sym.code) }
                    .onAppear { aliasFieldFocused = true }   // 편집 진입 시 자동 포커스
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.fieldBorder, lineWidth: 1))
                    .frame(maxWidth: .infinity)
                codeTag(sym.code)
                circleIcon("checkmark", bg: Palette.addBtn, tint: .white) { commitAliasEdit(sym.code) }
                    .help("저장")
                circleIcon("xmark", bg: Palette.deleteBG) { cancelAliasEdit() }
                    .help("취소")
            } else {
                // 표시명 클릭 → 별칭 편집 진입(별칭 없던 종목도 새로 지정 가능).
                Button { beginAliasEdit(sym) } label: {
                    Text(manageLabel(sym))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.manageLabel)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("별칭 수정")
                codeTag(sym.code)
                circleIcon("xmark", bg: Palette.deleteBG) { model.removeWatch(code: sym.code) }
                .help("삭제")
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 6)
    }

    private func codeTag(_ code: String) -> some View {
        Text("(\(code))")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.time)
    }

    private func circleIcon(_ symbol: String, bg: Color, tint: Color = Palette.priceMono, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(bg, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func beginAliasEdit(_ sym: WatchSymbol) {
        editingAlias = sym.alias
        editingCode = sym.code
    }

    private func commitAliasEdit(_ code: String) {
        model.setWatchAlias(code: code, alias: editingAlias)
        editingCode = nil
    }

    private func cancelAliasEdit() {
        editingCode = nil
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
        if model.addWatch(code: newCode, alias: newAlias) {
            newCode = ""; newAlias = ""
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
            authText("인증 OK · 계좌 \(mask(no)) (seq \(seq)) · 토큰 만료 \(expiryText(exp))", Palette.success)
        case .rateLimited(let seq, let exp):
            authText("rate limit(분당 1회) · 캐시 seq \(seq.map(String.init) ?? "?") · 만료 \(expiryText(exp))", Palette.textSecondary)
        case .failed:
            authText("인증 실패 — auth.env 의 client_id/secret 확인", Palette.error)
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
    let controller: ReorderController
    let commit: (_ from: Int, _ to: Int) -> Void

    @State private var rowHeight: CGFloat = 44

    private var session: DragSession? { controller.session }
    private var isDragging: Bool { session?.section == section && session?.fromIndex == index }
    private var isTarget: Bool {
        guard let d = session, d.section == section, d.fromIndex != index else { return false }
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
            .offset(y: isDragging ? (session?.translation ?? 0) : 0)
            .zIndex(isDragging ? 1 : 0)
    }

    // 왼쪽 액센트 바 주변(28px) 투명 스트립만 드래그 트리거. 텍스트 영역은 드래그 안 됨.
    // 호버 시 펼친 손, 끄는 중 쥔 손 커서로 그랩 영역을 알린다.
    private var dragHandle: some View {
        Color.clear
            .frame(width: 28)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard controller.session == nil else { return }   // 드래그 중엔 쥔 손(아래 gesture) 유지
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
                        controller.dragChanged(section: section, index: index, count: count, rowHeight: rowHeight,
                                               baseTranslation: value.translation.height,
                                               pointerGlobalY: value.location.y)
                    }
                    .onEnded { _ in
                        if let move = controller.dragEnded(), move.section == section, move.from == index {
                            commit(move.from, move.to)
                        }
                        NSCursor.arrow.set()
                    }
            )
    }
}

// 드래그 재배치 세션 소유 + 포인터가 뷰포트 상/하단 밴드에 들어오면 스크롤을 자동으로 민다.
//   - session 만 @Observable 로 뷰가 관찰(offset·타깃 하이라이트). 나머지는 내부 상태.
//   - enclosingScrollView(정식 AppKit API)로 SwiftUI ScrollView 뒤의 NSScrollView 참조 확보.
//   - 스크롤 델타 S = contentView.bounds.origin.y − 드래그 시작 시점 origin.y.
//     DragGesture(.global) 의 translation 은 포인터-앵커(스크롤 독립) → 유효 translation = base + S.
//     떠 있는 행 offset 과 targetIndex 둘 다 S 를 더해 정합(포인터를 edge 에 멈춰도 S 가 커지며 타깃 전진).
//   - 스크롤은 onChanged 가 아니라 독립 Task 루프가 몬다: 사용자가 edge 에서 포인터를 멈추면
//     onChanged 가 안 불리기 때문. Timer 아닌 Task.sleep(§4.1: .eventTracking 모드서도 도는 폴링과 동일).
@MainActor
@Observable
final class ReorderController {
    var session: DragSession?

    @ObservationIgnored private var baseTranslation: CGFloat = 0
    @ObservationIgnored private var scrollAtStart: CGFloat = 0
    @ObservationIgnored private var pointerGlobalY: CGFloat = 0
    @ObservationIgnored private var viewport: CGRect = .zero
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var loop: Task<Void, Never>?

    private let edgeBand: CGFloat = 44      // 뷰포트 상/하단 이 폭 안에 포인터가 들면 자동 스크롤
    private let maxStep: CGFloat = 14       // tick 당 최대 스크롤 px(밴드 깊이에 비례)

    func attach(_ sv: NSScrollView) { scrollView = sv }
    func setViewport(_ frame: CGRect) { viewport = frame }

    /// 드래그 onChanged 마다 호출. 첫 호출에서 스크롤 기준점을 잡고 tick 루프를 띄운다.
    func dragChanged(section: ReorderSection, index: Int, count: Int, rowHeight: CGFloat,
                     baseTranslation: CGFloat, pointerGlobalY: CGFloat) {
        if session == nil { scrollAtStart = currentOrigin }
        self.baseTranslation = baseTranslation
        self.pointerGlobalY = pointerGlobalY
        session = DragSession(section: section, fromIndex: index, rowHeight: rowHeight,
                              count: count, translation: baseTranslation + scrollDelta)
        if loop == nil { startLoop() }
    }

    /// 드래그 onEnded. 커밋 대상 (section, from, to) 를 돌려주고 세션·루프를 정리한다.
    func dragEnded() -> (section: ReorderSection, from: Int, to: Int)? {
        let s = session
        cancel()
        guard let s else { return nil }
        let to = s.targetIndex
        return to == s.fromIndex ? nil : (s.section, s.fromIndex, to)
    }

    /// onEnded 없이 드래그가 중단될 때(팝업 닫힘 등) 세션·tick 루프를 정리해 idle 공회전을 막는다.
    /// 활성 드래그가 없으면 no-op. (그 밖의 희귀 중단은 tick 의 session 가드+no-op scrollBy 로 무해.)
    func cancel() {
        guard session != nil || loop != nil else { return }
        session = nil
        loop?.cancel()
        loop = nil
    }

    private var currentOrigin: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }
    private var scrollDelta: CGFloat { currentOrigin - scrollAtStart }

    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session != nil else { return }
                self.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func tick() {
        guard session != nil, let sv = scrollView, viewport.height > 0 else { return }
        let topDist = pointerGlobalY - viewport.minY
        let botDist = viewport.maxY - pointerGlobalY
        let dy: CGFloat
        if topDist < edgeBand {
            dy = -maxStep * min(1, max(0, edgeBand - topDist) / edgeBand)
        } else if botDist < edgeBand {
            dy = maxStep * min(1, max(0, edgeBand - botDist) / edgeBand)
        } else {
            return
        }
        guard scrollBy(sv, dy) else { return }   // 실제로 이동했을 때만(문서 끝이면 no-op) 재계산
        if var s = session {
            s.translation = baseTranslation + scrollDelta
            session = s
        }
    }

    /// contentView 를 dy 만큼 민다(문서 범위로 clamp). 실제 이동하면 true.
    @discardableResult
    private func scrollBy(_ sv: NSScrollView, _ dy: CGFloat) -> Bool {
        let clip = sv.contentView
        guard let doc = sv.documentView else { return false }
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let cur = clip.bounds.origin.y
        let newY = min(max(0, cur + dy), maxY)
        guard abs(newY - cur) > 0.01 else { return false }
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: newY))
        sv.reflectScrolledClipView(clip)
        return true
    }
}

// SwiftUI ScrollView 뒤의 NSScrollView 참조를 잡아 컨트롤러에 넘긴다(드래그 edge 자동 스크롤용).
// enclosingScrollView 는 정식 AppKit API — 임의 트리 순회가 아니다. 콘텐츠 서브트리에 심어야 resolve 된다.
private struct ScrollViewGrabber: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void
    func makeNSView(context: Context) -> NSView { GrabberView(onResolve: onResolve) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class GrabberView: NSView {
        let onResolve: (NSScrollView) -> Void
        init(onResolve: @escaping (NSScrollView) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) 미사용") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let sv = enclosingScrollView { onResolve(sv) }
        }
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

    // 등락/손익 색 — 토스증권 규약: 상승·수익 빨강, 하락·손실 파랑.
    static let up            = Color(hex: 0xF04452)
    static let down          = Color(hex: 0x3182F6)
    static let neutral       = Color(hex: 0x9A9AA3)
    static let upPill        = Color(hex: 0xF04452, alpha: 0.14)
    static let downPill      = Color(hex: 0x3182F6, alpha: 0.14)
    static let neutralPill   = Color(hex: 0xFFFFFF, alpha: 0.08)

    // 인증 상태 색 — 등락과 무관한 성공/실패 의미(초록 OK / 소프트 레드 실패).
    static let success       = Color(hex: 0x34D399)
    static let error         = Color(hex: 0xF87171)

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
