import AppKit
import SwiftUI

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
  @State private var reorder = ReorderController()  // 드래그 재배치 세션 + edge 자동 스크롤(섹션 공유)
  @State private var editingCode: String?  // 별칭 인라인 편집 중인 행(코드). nil = 편집 없음
  @State private var editingAlias = ""
  @State private var tooltip: (text: String, point: CGPoint)?  // 미국 종목 hover 툴팁(popup 좌표). 최상위 overlay 렌더.
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
    .coordinateSpace(.named("popup"))
    .overlay { tooltipOverlay }  // 행이 아닌 최상위에 그려 z-index 최상위 + ScrollView clip 회피
    .onDisappear { reorder.cancel() }  // 팝업 닫힘 등 onEnded 없이 중단 시 tick 루프 종료
  }

  // 미국 종목 hover 시 popup 좌표(포인터) 근처에 뜨는 커스텀 툴팁. x는 팝업 폭(360) 안으로 clamp.
  @ViewBuilder private var tooltipOverlay: some View {
    if let tooltip {
      Text(tooltip.text)
        .font(.system(size: 11))
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.tooltipBG, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.fieldBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
        .position(x: min(max(tooltip.point.x, 115), 245), y: tooltip.point.y + 28)
        .allowsHitTesting(false)
    }
  }

  // RowInteraction 이 보고하는 hover 위치를 받는다. text 가 nil(한국·hover 종료)이면 툴팁을 숨긴다.
  private func setTooltip(_ text: String?, _ point: CGPoint) {
    tooltip = text.map { ($0, point) }
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
      hairline  // 하단 풀폭 구분선
      footer
    }
  }

  // ── 보유종목 ──
  @ViewBuilder private var holdingsSection: some View {
    sectionHeader(
      badgeBG: Palette.indigoBG, symbol: "chart.bar.fill", badgeTint: Palette.indigo,
      title: "내 보유종목", subtitle: "매입가 대비")
    switch model.holdings {
    case .idle: placeholder("불러오는 중…")
    case .failed: placeholder("보유종목 조회 실패 (인증 확인)")
    case .loaded(let rows):
      if rows.isEmpty {
        placeholder("보유종목 없음")
      } else {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
          positionRow(r).modifier(
            Reorderable(
              section: .holding, index: i, count: rows.count, controller: reorder,
              commit: { from, to in
                withAnimation(.snappy(duration: 0.22)) { model.moveHolding(from: from, to: to) }
              }))
        }
      }
    }
  }

  private func positionRow(_ r: PositionRow) -> some View {
    pillRow(
      name: model.aliased(r.name, for: r.id),
      price: Format.price(r.lastPrice, r.currency),
      pctText: Format.pctSigned(r.ratePercent, r.direction),
      pnlText: Format.pnl(r.pnlAmount, r.currency),
      direction: r.direction,
      onTap: { openStock(code: r.id, isUS: r.currency.isUSD) },
      help: r.currency.isUSD ? Self.usStockHelp : nil)
  }

  // ── 관심종목 ──
  @ViewBuilder private var watchSection: some View {
    sectionHeader(
      badgeBG: Palette.amberBG, symbol: "star.fill", badgeTint: Palette.amber,
      title: "관심종목", subtitle: "당일 등락")
    switch model.watch {
    case .idle: placeholder("불러오는 중…")
    case .failed: placeholder("관심종목 조회 실패")
    case .loaded(let rows):
      if rows.isEmpty {
        placeholder("관심종목 없음")
      } else {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
          watchRow(r).modifier(
            Reorderable(
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
      pillRow(
        name: r.rowName,
        price: Format.price(r.lastPrice, r.currency),
        pctText: "\(Format.arrow(dir))\(Format.pctAbs(rate))",
        pnlText: "\(Format.arrow(dir))\(Format.changeAbs(chg, r.currency))",
        direction: dir,
        onTap: { openStock(code: r.id, isUS: r.currency.isUSD) },
        help: r.currency.isUSD ? Self.usStockHelp : nil)
    case .noPrevClose:
      noteRow(
        name: r.rowName, price: Format.price(r.lastPrice, r.currency), note: "등락 데이터 없음",
        onTap: { openStock(code: r.id, isUS: r.currency.isUSD) },
        help: r.currency.isUSD ? Self.usStockHelp : nil)
    case .lookupFailed:
      noteRow(
        name: r.rowName, price: nil, note: "조회실패 (코드/인증 확인)",
        onTap: { openStock(code: r.id, isUS: isUSCode(r.id)) },
        help: isUSCode(r.id) ? Self.usStockHelp : nil)
    }
  }

  // ── 공통 행: 색 액센트 바 + 종목/현재가 + 등락 pill + 손익 ──
  private func pillRow(
    name: String, price: String, pctText: String, pnlText: String, direction: Direction,
    onTap: @escaping () -> Void, help: String?
  ) -> some View {
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
    .modifier(RowInteraction(onTap: onTap, help: help, report: setTooltip))
  }

  // 등락 데이터 없음 / 조회실패 — pill 없이 보조색 노트.
  private func noteRow(
    name: String, price: String?, note: String,
    onTap: @escaping () -> Void, help: String?
  ) -> some View {
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
    .modifier(RowInteraction(onTap: onTap, help: help, report: setTooltip))
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
        Button {
          add()
        } label: {
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
          .onAppear { aliasFieldFocused = true }  // 편집 진입 시 자동 포커스
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
        Button {
          beginAliasEdit(sym)
        } label: {
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

  private func circleIcon(_ symbol: String, bg: Color, tint: Color = Palette.priceMono, action: @escaping () -> Void)
    -> some View
  {
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
    case (let name?, false): "\(name) · \(s.alias)"
    case (let name?, true): name
    case (nil, false): s.alias
    case (nil, true): s.code
    }
  }

  private func add() {
    if model.addWatch(code: newCode, alias: newAlias) {
      newCode = ""
      newAlias = ""
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
      authText(
        "rate limit(분당 1회) · 캐시 seq \(seq.map(String.init) ?? "?") · 만료 \(expiryText(exp))",
        Palette.textSecondary)
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
  private func sectionHeader(badgeBG: Color, symbol: String, badgeTint: Color, title: String, subtitle: String)
    -> some View
  {
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

  private func footerButton(
    icon: String? = nil, title: String, tint: Color = Palette.footerText, hasBG: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon {
          Image(systemName: icon).font(.system(size: 11, weight: .semibold))
        }
        Text(title).font(.system(size: 12, weight: .medium))
      }
      .foregroundStyle(tint)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(
        hasBG ? AnyShapeStyle(Palette.footerBtnBG) : AnyShapeStyle(Color.clear),
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

  // ── 종목 페이지 열기 (§3.2/§3.3) ──
  // 한국: tossinvest.com/stocks/A{code} 로 정확한 딥링크(KRX 표준코드 A접두사).
  // 미국: Open API가 티커만 주고 웹 URL용 productCode(US…/NAS0…/AMX0…)를 안 줘 정확한 딥링크가 불가
  //   → 홈으로 이동 + 툴팁 안내. currency로 KR/US 판별(조회실패 행은 currency 신뢰 불가 → code 첫 글자).
  static let usStockHelp = "미국 종목은 상세 페이지 바로가기를 지원하지 않아요."

  private func openStock(code: String, isUS: Bool) {
    let s = isUS ? "https://www.tossinvest.com/" : "https://www.tossinvest.com/stocks/A\(code)"
    guard let url = URL(string: s) else { return }
    NSWorkspace.shared.open(url)
  }

  // 조회실패 행 폴백: 종목명·통화 조회가 안 돼 currency가 강제 KRW로 채워진 경우 code 형태로 판별.
  private func isUSCode(_ code: String) -> Bool { !(code.first?.isNumber ?? true) }

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

// 종목 행 상호작용: 본문 탭(종목 페이지 열기) + hover 시 pointer 커서 + 미국 종목 툴팁 위치 보고.
//  - 탭: 좌측 28px 드래그 핸들(Reorderable overlay·highPriorityGesture)이 그 영역은 우선 소비하므로 본문에만 걸린다.
//  - 커서: MenuBarExtra(.window)에서도 포인터 이동 시 OS가 커서를 리셋하므로 onContinuousHover .active 마다 재-set
//    (드래그 핸들과 동일 패턴). 좌측 스트립은 핸들의 openHand 가 이기도록 둔다.
//  - 툴팁: 행 overlay 로 그리면 인접 행이 덮으므로(z-index) 그리지 않고, popup 좌표만 상위로 보고한다.
//    실제 렌더는 PopupView 최상위 overlay(§tooltipOverlay) — ScrollView clip·행간 가림 없이 항상 위.
private struct RowInteraction: ViewModifier {
  let onTap: () -> Void
  let help: String?
  let report: (String?, CGPoint) -> Void  // (help, popup좌표). 벗어나면 (nil, _).

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      .onContinuousHover(coordinateSpace: .named("popup")) { phase in
        switch phase {
        case .active(let p):
          NSCursor.pointingHand.set()
          report(help, p)
        case .ended:
          NSCursor.arrow.set()
          report(nil, .zero)
        }
      }
  }
}

// 행 좌측 색 액센트 바(3px). 그리디 셰이프가 행 높이를 부풀리지 않도록 overlay로 그린다.
extension View {
  fileprivate func accentBar(_ color: Color) -> some View {
    overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(color)
        .frame(width: 3)
        .padding(.leading, 15)
        .padding(.vertical, 6)
    }
  }
}
