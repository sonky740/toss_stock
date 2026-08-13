import SwiftUI

// ─────────────────────────────────────────────────────────────
// SearchSection — 관심종목 관리 안의 종목 검색(§3.4).
// 유니버스는 로컬(StockUniverse)에서 찾고, 결과 행의 가격은 배치로 한 번에·등락은 종목별로 뒤따라 온다.
// PopupView 에서 분리해 둔다: 등락이 하나씩 채워질 때마다 팝업 전체가 재평가되지 않게.
// ─────────────────────────────────────────────────────────────

struct SearchSection: View {
  let model: StockModel
  @Binding var query: String

  var body: some View {
    darkField("종목명·코드로 검색 (삼성전자 / AAPL / 0190C0)", text: $query)
      .padding(.horizontal, 15).padding(.top, 2).padding(.bottom, 6)
      .onChange(of: query) { _, text in model.search(text) }

    switch model.universeState {
    case .idle:
      EmptyView()
    case .loading(let done, let total):
      placeholder("종목 목록 준비 중… (\(done)/\(total))")
    case .unavailable:
      placeholder("종목 목록을 불러오지 못했어요 (인증 확인)")
    case .ready(let partial):
      if partial {
        placeholder("일부 시장 목록을 못 받아 결과가 빠질 수 있어요")
      }
      results
    }
  }

  @ViewBuilder private var results: some View {
    if model.searchResults.isEmpty {
      if !query.trimmingCharacters(in: .whitespaces).isEmpty {
        placeholder("검색 결과 없음")
      }
    } else {
      ForEach(model.searchResults) { resultRow($0) }
    }
  }

  /// 행 본문은 관심·보유 섹션과 같이 토스증권 종목 페이지를 연다(§3.2). 등록은 우측 `+`가 맡는다.
  private func resultRow(_ r: SearchRow) -> some View {
    let isUS = Self.isUSMarket(r.market)
    return HStack(spacing: 6) {
      Button {
        openStock(code: r.id, isUS: isUS)
      } label: {
        rowBody(r)
      }
      .buttonStyle(.plain)
      .pointerCursor()
      .help(isUS ? usStockHelp : "토스증권에서 열기")
      if r.isWatched {
        watchedBadge
      } else {
        circleIcon("plus", bg: Palette.addBtn, tint: .white) { model.addWatch(code: r.id, alias: "") }
          .help("관심종목에 추가")
      }
    }
    .padding(.trailing, 15)
    .modifier(RowHover())
  }

  private var watchedBadge: some View {
    Image(systemName: "checkmark")
      .font(.system(size: 8, weight: .bold))
      .foregroundStyle(Palette.time)
      .frame(width: 20, height: 20)
      .background(Palette.deleteBG, in: Circle())
  }

  private func rowBody(_ r: SearchRow) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(r.name)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(Palette.manageLabel)
          .lineLimit(1).truncationMode(.tail)
        Text("\(r.id) · \(r.market)")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(Palette.time)
      }
      Spacer(minLength: 4)
      quote(r)
    }
    .contentShape(Rectangle())
    .padding(.leading, 15).padding(.vertical, 5)
  }

  /// 시세 도착 전에도 판별해야 해서 `currency` 가 아니라 마켓으로 가른다.
  private static func isUSMarket(_ market: String) -> Bool {
    !["KOSPI", "KOSDAQ", "KR_ETC"].contains(market)
  }

  /// 가격이 먼저, 등락이 나중에 온다. 도착 전에도 자리를 채워 둬야 행 높이가 흔들리지 않는다.
  @ViewBuilder private func quote(_ r: SearchRow) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(r.lastPrice.map { Format.price($0, r.currency ?? .krw) } ?? "…")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.priceMono)
      switch r.change {
      case .priced(let amount, let rate, let direction):
        Text("\(Format.arrow(direction))\(Format.pctAbs(rate)) \(Format.changeAbs(amount, r.currency ?? .krw))")
          .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
          .foregroundStyle(tintColor(direction))
      case .noPrevClose:
        note("등락 없음")
      case .lookupFailed:
        note("시세 없음")
      case nil:
        note("확인 중…")
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.system(size: 10.5)).foregroundStyle(Palette.textSecondary)
  }
}
