import AppKit
import SwiftUI

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
struct Reorderable: ViewModifier {
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
      .background(
        GeometryReader { g in
          Color.clear.onChange(of: g.size.height, initial: true) { _, h in rowHeight = h }
        }
      )
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
        guard controller.session == nil else { return }  // 드래그 중엔 쥔 손(아래 gesture) 유지
        switch phase {
        case .active: NSCursor.openHand.set()
        case .ended: NSCursor.arrow.set()
        }
      }
      .highPriorityGesture(
        // .global 필수: 행이 자기 translation 만큼 .offset 되므로, .local 이면 좌표공간이 함께
        // 움직여 translationₙ = T − translationₙ₋₁ 진동(격렬한 흔들림)이 생긴다. 화면 고정 공간으로 차단.
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
          .onChanged { value in
            NSCursor.closedHand.set()
            controller.dragChanged(
              section: section, index: index, count: count, rowHeight: rowHeight,
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

  private let edgeBand: CGFloat = 44  // 뷰포트 상/하단 이 폭 안에 포인터가 들면 자동 스크롤
  private let maxStep: CGFloat = 14  // tick 당 최대 스크롤 px(밴드 깊이에 비례)

  func attach(_ sv: NSScrollView) { scrollView = sv }
  func setViewport(_ frame: CGRect) { viewport = frame }

  /// 드래그 onChanged 마다 호출. 첫 호출에서 스크롤 기준점을 잡고 tick 루프를 띄운다.
  func dragChanged(
    section: ReorderSection, index: Int, count: Int, rowHeight: CGFloat,
    baseTranslation: CGFloat, pointerGlobalY: CGFloat
  ) {
    if session == nil { scrollAtStart = currentOrigin }
    self.baseTranslation = baseTranslation
    self.pointerGlobalY = pointerGlobalY
    session = DragSession(
      section: section, fromIndex: index, rowHeight: rowHeight,
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
    guard scrollBy(sv, dy) else { return }  // 실제로 이동했을 때만(문서 끝이면 no-op) 재계산
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
struct ScrollViewGrabber: NSViewRepresentable {
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
