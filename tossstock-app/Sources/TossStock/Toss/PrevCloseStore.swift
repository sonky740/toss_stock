import Foundation

// ─────────────────────────────────────────────────────────────
// PrevCloseStore — 관심종목·검색 전일종가 캐시 + candles 호출 페이싱.
// 전일종가는 세션 안에서 불변이라 종목당 세션당 1회만 조회한다(10초 폴링마다 재조회 금지).
// 키는 벽시계 날짜가 아니라 시장 세션일이다 — 세션 롤은 자정이 아니라 09:00 KST·00:00 ET다.
// candles(MARKET_DATA_CHART) 간격도 여기서 지킨다. 호출자가 폴링·검색 둘이라 예약과 대기를 가른다.
// ─────────────────────────────────────────────────────────────

actor PrevCloseStore {
  private var entries: [String: (day: String, value: Double)] = [:]
  private var nextSlotAt: Date?

  private static let minCallInterval: TimeInterval = 0.25

  /// 해당 세션일에 캐시된 값. 세션이 넘어갔으면 nil(재조회).
  func cached(_ code: String, on day: String) -> Double? {
    guard let entry = entries[code], entry.day == day else { return nil }
    return entry.value
  }

  func store(_ value: Double, for code: String, on day: String) {
    entries[code] = (day, value)
  }

  /// 다음 candles 호출 슬롯을 예약하고 그때까지 남은 대기 시간을 돌려준다. 호출자가 그만큼 잔 뒤 호출한다.
  ///
  /// **대기를 actor 밖에 두는 것이 이 설계의 전부다.** 여기서 `await Task.sleep` 을 하면 그 중단점에서
  /// 격리가 풀려 다른 호출자가 같은 상태를 읽고 들어온다 — 실측(2026-08-13, 동시 호출자 2)에서
  /// 호출 간격 11개 중 5개가 0.000초로 페이싱이 절반으로 무너졌다. 예약은 중단점이 없어야 원자적이다.
  func reserveCandleSlot() -> TimeInterval {
    let now = Date()
    let slot = max(nextSlotAt ?? now, now)
    nextSlotAt = slot.addingTimeInterval(Self.minCallInterval)
    return slot.timeIntervalSince(now)
  }
}
