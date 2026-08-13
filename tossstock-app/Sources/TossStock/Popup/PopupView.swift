import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────
// PopupView — 펼친 채 실시간 갱신되는 드롭다운 (다크 "Color pill" 리디자인, Claude Design 02안).
//   섹션마다 아이콘 배지 헤더 + 행별 색 액센트 바 + 등락률 색 배지(pill).
//   상승 초록(#34d399) / 하락 빨강(#f87171) / 보합·실패 회색(앱 색 규칙 유지).
//   관심종목 관리 진입(상단 고정) → 보유 → 관심 → 하단(새로고침·인증 점검·종료).
//   관리 자체는 별도 창이다(Popup/ManageView.swift).
//   자격증명 미설정이면 설정 안내만 표시. 폰트는 시스템 + 숫자만 monospaced.
// ─────────────────────────────────────────────────────────────

struct PopupView: View {
  let model: StockModel
  @State private var contentHeight: CGFloat = 0
  @State private var reorder = ReorderController()  // 드래그 재배치 세션 + edge 자동 스크롤(섹션 공유)
  @State private var tooltip: (text: String, point: CGPoint)?  // 미국 종목 hover 툴팁(popup 좌표). 최상위 overlay 렌더.
  @State private var manageOpen = false
  @State private var manageSide: PopupSide = .right

  var body: some View {
    Group {
      if model.needsCredentials {
        setupGuidance.frame(width: 360)
      } else {
        main
      }
    }
    .background { Palette.bg.ignoresSafeArea() }
    .environment(\.colorScheme, .dark)
    .coordinateSpace(.named("popup"))
    .background(PopupPanelGrabber())  // 관리 컬럼을 어느 쪽에 붙일지 정하기 위한 앵커 등록(§3.4)
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

  // 관리는 별도 창이 아니라 이 패널이 가로로 넓어지는 형태다. 붙는 쪽은 화면 남는 폭이 정한다(§3.4).
  private var main: some View {
    // .top 이어야 한다. 기본 .center 면 본체보다 짧은 관리 컬럼이 세로 가운데로 밀려 위아래에 여백이 생긴다.
    HStack(alignment: .top, spacing: 0) {
      if manageOpen && manageSide == .left {
        ManagePane(model: model, height: scrollHeight)
        vHairline
      }
      mainColumn
      if manageOpen && manageSide == .right {
        vHairline
        ManagePane(model: model, height: scrollHeight)
      }
    }
  }

  /// 두 컬럼이 같은 높이로 서게 스크롤 높이를 한 곳에서 정한다.
  private var scrollHeight: CGFloat { min(max(contentHeight, 60), 520) }

  private var mainColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      manageEntry  // ScrollView 밖 — 목록이 길어져도 스크롤에 밀려나지 않는다
      hairline
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          holdingsSection
          sectionDivider
          watchSection
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
      .frame(height: scrollHeight)
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
    .frame(width: 360)
  }

  // ── 관심종목 관리 열기/닫기 (옆 컬럼) ──
  private var manageEntry: some View {
    Button(action: toggleManage) {
      HStack(spacing: 9) {
        iconBadge(bg: Palette.manageBG, symbol: "slider.horizontal.3", tint: Palette.manageTint)
        Text("종목 검색·관리")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Palette.textPrimary)
        // 보유("매입가 대비")·관심("당일 등락")과 같은 결로 상태를 말한다 — 동작 나열은 기능이 늘 때마다 낡는다.
        Text(model.watchSymbols.isEmpty ? "등록된 종목 없음" : "\(model.watchSymbols.count)개 등록됨")
          .font(.system(size: 11))
          .foregroundStyle(Palette.textSecondary)
        Spacer()
        Image(systemName: manageSide == .left ? "sidebar.left" : "sidebar.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(manageOpen ? Palette.manageTint : Palette.priceMono)
      }
      .padding(.horizontal, 15)
      .frame(height: popupHeaderHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerCursor()
    .modifier(RowHover())
    .help(manageOpen ? "관리 영역 닫기" : "옆에 관리 영역 펼치기")
  }

  private func toggleManage() {
    if !manageOpen {
      // 펼칠 때만 방향을 정한다 — 접는 중에 바뀌면 컬럼이 반대편으로 튀었다가 사라진다.
      manageSide = PopupAnchor.side(paneWidth: ManagePane.width)
      // 유니버스 콜드 수집이 8초라 관리를 안 여는 세션에서는 시작조차 하지 않는다.
      model.prepareSearch()
    }
    manageOpen.toggle()
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
      help: r.currency.isUSD ? usStockHelp : nil)
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
        help: r.currency.isUSD ? usStockHelp : nil)
    case .noPrevClose:
      noteRow(
        name: r.rowName, price: Format.price(r.lastPrice, r.currency), note: "등락 데이터 없음",
        onTap: { openStock(code: r.id, isUS: r.currency.isUSD) },
        help: r.currency.isUSD ? usStockHelp : nil)
    case .lookupFailed:
      noteRow(
        name: r.rowName, price: nil, note: "조회실패 (코드/인증 확인)",
        onTap: { openStock(code: r.id, isUS: isUSCode(r.id)) },
        help: isUSCode(r.id) ? usStockHelp : nil)
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
        .pointerCursor()
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
    .pointerCursor()
  }

  private var sectionDivider: some View {
    hairline.padding(.horizontal, 15).padding(.vertical, 8)
  }

  private var hairline: some View {
    Rectangle().fill(Palette.divider).frame(height: 1)
  }

  // 두 컬럼 사이 세로 구분선.
  private var vHairline: some View {
    Rectangle().fill(Palette.divider).frame(width: 1)
  }

  // 조회실패 행 폴백: 종목명·통화 조회가 안 돼 currency가 강제 KRW로 채워진 경우 code 형태로 KR/US를 판별한다.
  private func isUSCode(_ code: String) -> Bool { !(code.first?.isNumber ?? true) }

  // ── helpers ──
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

// ── 팝업 공용 조각 (PopupView·SearchSection 공유) ──

// 종목 페이지 열기 (§3.2/§3.3/§3.4).
// 한국: tossinvest.com/stocks/A{code} 로 정확한 딥링크(KRX 표준코드 A접두사).
// 미국: Open API가 티커만 주고 웹 URL용 productCode(US…/NAS0…/AMX0…)를 안 줘 정확한 딥링크가 불가 → 홈 + 안내.
let usStockHelp = "미국 종목은 상세 페이지 바로가기를 지원하지 않아요."

// 관리 진입 행(본체)과 관리 컬럼 헤더의 높이. 두 컬럼의 첫 구분선이 어긋나면 바로 눈에 띈다.
// 값은 진입 행이 자연히 갖는 높이 = iconBadge 22 + 상하 패딩 9×2. 컬럼 헤더는 텍스트뿐이라 더 낮다.
let popupHeaderHeight: CGFloat = 40

@MainActor
func openStock(code: String, isUS: Bool) {
  let s = isUS ? "https://www.tossinvest.com/" : "https://www.tossinvest.com/stocks/A\(code)"
  guard let url = URL(string: s) else { return }
  NSWorkspace.shared.open(url)
}

func darkField(_ prompt: String, text: Binding<String>) -> some View {
  TextField(prompt, text: text)
    .textFieldStyle(.plain)
    .font(.system(size: 12))
    .foregroundStyle(Palette.textPrimary)
    .padding(.horizontal, 9).padding(.vertical, 7)
    .background(Palette.fieldBG, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.fieldBorder, lineWidth: 1))
    .frame(maxWidth: .infinity)
}

// pointerCursor(NSCursor)가 메인 격리라 이 헬퍼도 같은 도메인이어야 한다.
@MainActor
func circleIcon(_ symbol: String, bg: Color, tint: Color = Palette.priceMono, action: @escaping () -> Void)
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
  .pointerCursor()
}

func codeTag(_ code: String) -> some View {
  Text("(\(code))")
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(Palette.time)
}

func placeholder(_ text: String) -> some View {
  Text(text)
    .font(.system(size: 12))
    .foregroundStyle(Palette.textSecondary)
    .padding(.horizontal, 15).padding(.vertical, 6)
}

func tintColor(_ d: Direction) -> Color {
  switch d {
  case .up: Palette.up
  case .down: Palette.down
  case .flat: Palette.neutral
  }
}

func pillColor(_ d: Direction) -> Color {
  switch d {
  case .up: Palette.upPill
  case .down: Palette.downPill
  case .flat: Palette.neutralPill
  }
}

// 클릭 가능한 행(관심종목 관리·검색 결과) hover 배경. 재배치 행은 Reorderable 이 드래그 상태와 함께 다룬다.
struct RowHover: ViewModifier {
  @State private var hovering = false

  func body(content: Content) -> some View {
    content
      .background(Palette.rowHover.opacity(hovering ? 1 : 0).animation(.easeOut(duration: 0.12), value: hovering))
      .onHover { hovering = $0 }
  }
}

// 행 좌측 색 액센트 바(3px). 그리디 셰이프가 행 높이를 부풀리지 않도록 overlay로 그린다.
extension View {
  // .plain 버튼엔 커서가 안 붙는다. MenuBarExtra(.window)는 포인터 이동 시 OS가 커서를 리셋하므로
  // .active 마다 재-set 한다(RowInteraction·dragHandle 과 동일 패턴).
  func pointerCursor() -> some View {
    onContinuousHover { phase in
      switch phase {
      case .active: NSCursor.pointingHand.set()
      case .ended: NSCursor.arrow.set()
      }
    }
  }

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
