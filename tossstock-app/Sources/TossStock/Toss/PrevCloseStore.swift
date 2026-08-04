import Foundation

// ─────────────────────────────────────────────────────────────
// PrevCloseStore — 관심종목 전일종가 캐시 + candles 호출 페이싱.
// 전일종가는 세션 안에서 불변이라 종목당 세션당 1회만 조회한다(10초 폴링마다 재조회 금지).
// 키는 벽시계 날짜가 아니라 시장 세션일이다 — 세션 롤은 자정이 아니라 09:00 KST·00:00 ET다.
// candles(MARKET_DATA_CHART, 초당 5회) 간격도 여기서 지킨다 — actor 직렬화가 곧 호출 직렬화다.
// ─────────────────────────────────────────────────────────────

actor PrevCloseStore {
  private var entries: [String: (day: String, value: Double)] = [:]
  private var lastCallAt: Date?

  private static let minCallInterval: TimeInterval = 0.25

  /// 해당 세션일에 캐시된 값. 세션이 넘어갔으면 nil(재조회).
  func cached(_ code: String, on day: String) -> Double? {
    guard let entry = entries[code], entry.day == day else { return nil }
    return entry.value
  }

  func store(_ value: Double, for code: String, on day: String) {
    entries[code] = (day, value)
  }

  /// 앞 candles 호출로부터 최소 간격을 확보한다. 호출 직전에 부른다.
  func paceCandleCall() async {
    if let lastCallAt {
      let wait = Self.minCallInterval - Date().timeIntervalSince(lastCallAt)
      // 취소되면 그대로 진행 — 페이싱 실패의 유일한 결과는 429이고 요청계층이 재시도한다.
      if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }
    lastCallAt = Date()
  }
}
