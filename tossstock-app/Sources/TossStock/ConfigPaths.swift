import Foundation

// 런타임 설정 파일 경로 묶음(레포 밖 ~/.config/tossstock, §2.3).
// 특정 레이어에 속하지 않아 타깃 루트에 둔다 — Format.swift 와 같은 자리.

struct ConfigPaths: Sendable {
  let dir: URL
  var authEnv: URL { dir.appendingPathComponent("auth.env") }
  var tokenJSON: URL { dir.appendingPathComponent("token.json") }
  var symbolsTSV: URL { dir.appendingPathComponent("symbols.tsv") }
  var holdingsOrder: URL { dir.appendingPathComponent("holdings_order.txt") }  // 보유종목 드래그 재배치 순서

  static let standard = Self(
    dir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tossstock")
  )
}
