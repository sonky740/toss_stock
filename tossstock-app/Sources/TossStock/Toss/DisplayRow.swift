import Foundation

// ─────────────────────────────────────────────────────────────
// DisplayRow — service → view 로 넘기는 표시용 Row 타입.
// 와이어 DTO(TossDTO.swift)와 분리해 둔다: API 응답 스키마가 바뀌어도
// 뷰가 보는 계약은 TossService 가 흡수한다.
// ─────────────────────────────────────────────────────────────

enum Direction: Sendable, Equatable { case up, down, flat }

struct PositionRow: Identifiable, Sendable {
    let id: String           // symbol
    let name: String
    let lastPrice: Double
    let currency: Currency
    let ratePercent: Double  // 부호 있는 % (rate*100)
    let pnlAmount: Double
    let direction: Direction
}

enum WatchChange: Sendable {
    case priced(changeAmount: Double, ratePercent: Double, direction: Direction)  // 둘 다 절대값, 부호는 direction
    case noPrevClose         // 신규상장 등 — 현재가만
    case lookupFailed        // prices 누락 — "조회실패"
}

struct WatchRow: Identifiable, Sendable {
    let id: String           // 종목코드
    let rowName: String      // 드롭다운 행 표시명: 종목명 · 별칭 (별칭 없으면 종목명 > 코드)
    let titleName: String    // 회전 타이틀 표시명: 별칭 > 종목명 > 코드
    let currency: Currency
    let lastPrice: Double
    let change: WatchChange
    let resolvedName: String?  // 종목명 조회 성공시만(삭제 메뉴 라벨용)
}

extension WatchRow {
    /// 표시명 단일 규칙(§3.3). 초기 빌드(TossService)와 별칭 즉시 반영(relabeled)이 같은 문자열을 내도록 공유.
    /// rowName = 종목명 · 별칭(별칭 없으면 종목명 > 코드), titleName = 별칭 > 종목명 > 코드.
    static func displayNames(code: String, resolvedName: String?, alias: String) -> (row: String, title: String) {
        let full = resolvedName ?? code
        let title = alias.isEmpty ? full : alias
        let row = alias.isEmpty ? full : (resolvedName.map { "\($0) · \(alias)" } ?? alias)
        return (row, title)
    }

    /// 별칭만 바꿔 표시명을 재계산한 복제본(인메모리 즉시 반영·reconcile용). resolvedName·시세·등락은 보존.
    func relabeled(alias: String) -> WatchRow {
        let (row, title) = WatchRow.displayNames(code: id, resolvedName: resolvedName, alias: alias)
        return WatchRow(id: id, rowName: row, titleName: title, currency: currency,
                        lastPrice: lastPrice, change: change, resolvedName: resolvedName)
    }
}

struct AuthStatus: Sendable {
    let accountNo: String
    let accountSeq: Int
    let expiresAt: Date?
}
