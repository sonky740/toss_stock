import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────
// 관심종목 관리 — 드롭다운 옆으로 붙는 컬럼(§3.4).
//   별도 창이 아니라 같은 패널이 가로로 넓어지는 형태다. 어느 쪽으로 넓힐지는 PopupAnchor 가
//   패널이 놓인 화면의 남는 폭으로 정한다(기본 오른쪽).
// ─────────────────────────────────────────────────────────────

enum PopupSide {
  case left, right
}

/// 메뉴바 팝업 패널의 화면 위치를 들고 있는다 — 관리 컬럼을 어느 쪽에 붙일지 정하는 데만 쓴다.
/// SwiftUI 가 씬의 `NSWindow`를 노출하지 않아 `PopupPanelGrabber`로 잡는다.
@MainActor
enum PopupAnchor {
  private static weak var panel: NSWindow?  // SwiftUI 소유라 약참조

  static func set(_ window: NSWindow?) {
    guard let window else { return }  // 팝업이 닫힐 때도 불린다. nil 로 덮으면 앵커를 잃는다
    panel = window
  }

  /// 프레임은 캐시하지 않고 펼칠 때 다시 읽는다 — 회전 타이틀 길이에 따라 상태아이템 폭이
  /// 바뀌어 패널이 가로로 움직인다. 앵커나 그 화면을 못 찾으면 기본값(오른쪽).
  /// `NSScreen.main` 폴백은 쓰지 않는다(key window 가 없으면 아무 화면이나 준다).
  static func side(paneWidth: CGFloat) -> PopupSide {
    guard
      let frame = panel?.frame,
      let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
    else { return .right }
    return preferredSide(anchor: frame, visible: screen.visibleFrame, paneWidth: paneWidth)
  }

  /// 패널을 닫는다(Esc). 패널 `close()` 로는 창만 사라지고 SwiftUI 의 MenuBarExtra 표시 상태가 안 풀린다 —
  /// 실측에서 다음 상태아이템 클릭이 "닫기"로 소비돼 두 번 눌러야 다시 열렸다. 그래서 상태아이템 버튼을
  /// 대신 눌러 SwiftUI 자신의 토글 경로를 태운다. 버튼을 못 찾을 때만 close() 로 떨어진다.
  static func dismiss() {
    if let button = statusItemButton() {
      button.performClick(nil)
    } else {
      panel?.close()
    }
  }

  /// 상태아이템 버튼은 SwiftUI 가 소유해 참조를 안 준다. 자기 앱 창에서 찾는다.
  private static func statusItemButton() -> NSStatusBarButton? {
    NSApp.windows.lazy.compactMap { $0.contentView.flatMap(statusButton(in:)) }.first
  }

  private static func statusButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    return view.subviews.lazy.compactMap(statusButton(in:)).first
  }

  /// 순수 판정. 메뉴바 패널이 합성 클릭에 반응하지 않아 이 계산만은 따로 검사할 수 있어야 한다.
  static func preferredSide(anchor: NSRect, visible: NSRect, paneWidth: CGFloat) -> PopupSide {
    if visible.maxX - anchor.maxX >= paneWidth { return .right }
    if anchor.minX - visible.minX >= paneWidth { return .left }
    return .right
  }
}

/// 팝업 패널의 backing window 를 `PopupAnchor` 에 넘긴다(`ScrollViewGrabber` 와 같은 수법).
struct PopupPanelGrabber: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { GrabberView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class GrabberView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      PopupAnchor.set(window)
    }
  }
}

/// 관리 컬럼 본문. 높이는 옆 컬럼(보유·관심)이 정하므로 여기서 실측하지 않는다.
struct ManagePane: View {
  let model: StockModel
  let height: CGFloat
  @State private var query = ""
  @State private var editingCode: String?  // 별칭 인라인 편집 중인 행(코드). nil = 편집 없음
  @State private var editingAlias = ""
  @FocusState private var aliasFieldFocused: Bool

  static let width: CGFloat = 320

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      paneHeader
      hairlineH
      // 검색 결과를 ↑/↓ 로 훑을 때 선택 행을 끌어오려면 프록시가 필요하다. ScrollView 안이 아니라
      // 바깥에 둔다 — 실측 대상 서브트리(§4.2)에 컨테이너를 끼우면 높이 해석이 달라진다.
      ScrollViewReader { scroll in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            SearchSection(model: model, query: $query, scroll: scroll)
            registeredHeader
            ForEach(model.watchSymbols) { manageRow($0) }
          }
          .padding(.bottom, 8)
        }
        // 남는 높이를 먹어 본체 컬럼과 아래를 맞춘다. minHeight 는 붕괴 방지용 — ScrollView 고유 높이가
        // 0이라(§4.2) maxHeight 만 주면 HStack 높이 계산에 따라 납작해질 수 있다.
        .frame(minHeight: height, maxHeight: .infinity)
      }
    }
    .frame(width: Self.width, alignment: .top)
  }

  private var paneHeader: some View {
    HStack(spacing: 8) {
      Text("종목 검색·관리")
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Palette.textPrimary)
      Spacer()
    }
    .padding(.horizontal, 15)
    .frame(height: popupHeaderHeight)  // 본체 진입 행과 같은 높이 → 두 컬럼의 첫 구분선이 맞는다
  }

  /// 검색 결과와 등록 목록이 그냥 이어 붙으면 경계가 안 보인다.
  private var registeredHeader: some View {
    Text(model.watchSymbols.isEmpty ? "등록된 종목 없음" : "등록된 종목 \(model.watchSymbols.count)개")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Palette.textSecondary)
      .padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 4)
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
        .pointerCursor()
        .help("별칭 수정")
        codeTag(sym.code)
        circleIcon("xmark", bg: Palette.deleteBG) { model.removeWatch(code: sym.code) }
          .help("삭제")
      }
    }
    .padding(.horizontal, 15).padding(.vertical, 6)
    .modifier(RowHover())
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

  private var hairlineH: some View {
    Rectangle().fill(Palette.divider).frame(height: 1)
  }
}
