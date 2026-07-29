import Foundation

// ─────────────────────────────────────────────────────────────
// HoldingsOrder — 보유종목 드래그 재배치 순서를 holdings_order.txt(심볼 줄단위)에 저장/복원.
// 보유종목은 /holdings API 응답 순서라 사용자가 못 정한다 → 저장된 순서로 정렬해 덮어쓴다.
// 저장에 없는(새로 매수한) 종목은 뒤에 API 순서로 붙이고, 저장에만 있고 현재 없는(매도한)
// 종목은 무시한다. 파일은 다음 드래그 시 현재 보유 집합으로 통째 덮여 자연 정리된다.
// ─────────────────────────────────────────────────────────────

enum HoldingsOrder {
  /// 저장된 심볼 순서. 파일 없으면 빈 배열(= API 순서 유지).
  static func read(_ paths: ConfigPaths = .standard) -> [String] {
    guard let text = try? String(contentsOf: paths.holdingsOrder, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// 현재 표시 순서대로 통째 저장.
  static func write(_ symbols: [String], _ paths: ConfigPaths = .standard) {
    try? FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
    let text = symbols.joined(separator: "\n") + "\n"
    try? text.data(using: .utf8)?.write(to: paths.holdingsOrder, options: .atomic)
  }

  /// 저장 순서대로 정렬. 저장에 없는 항목은 원래(API) 순서로 뒤에 둔다(안정 정렬).
  static func sorted<T>(_ rows: [T], by id: (T) -> String, _ paths: ConfigPaths = .standard) -> [T] {
    let saved = read(paths)
    guard !saved.isEmpty else { return rows }
    let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return rows.enumerated().sorted { a, b in
      switch (rank[id(a.element)], rank[id(b.element)]) {
      case (let x?, let y?): return x < y  // 둘 다 저장됨 → 저장 순서
      case (_?, nil): return true  // 저장된 게 앞
      case (nil, _?): return false  // 미저장은 뒤
      case (nil, nil): return a.offset < b.offset  // 둘 다 신규 → API 순서 유지
      }
    }.map(\.element)
  }
}
