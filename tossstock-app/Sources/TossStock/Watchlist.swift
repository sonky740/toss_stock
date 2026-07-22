import Foundation

// ─────────────────────────────────────────────────────────────
// Watchlist — symbols.tsv("코드<TAB>별칭") 읽기/쓰기/추가/삭제.
// 셸 플러그인과 동일 형식·정제 규칙(cleanCode/cleanAlias)을 유지해 상호 호환.
// ─────────────────────────────────────────────────────────────

struct WatchSymbol: Identifiable, Sendable, Equatable {
    var id: String { code }
    let code: String
    let alias: String
}

enum Watchlist {
    // 코드: 소문자→대문자, 영숫자·'.'·'-'만 유지
    static func cleanCode(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return String(raw.uppercased().filter { allowed.contains($0) })
    }

    // 별칭: 탭/개행/파이프 제거 후 트림
    static func cleanAlias(_ raw: String) -> String {
        String(raw.filter { $0 != "\t" && $0 != "\n" && $0 != "|" })
            .trimmingCharacters(in: .whitespaces)
    }

    /// 관심종목 읽기. 파일 없으면 빈 목록.
    static func read(_ paths: ConfigPaths = .standard) -> [WatchSymbol] {
        guard let text = try? String(contentsOf: paths.symbolsTSV, encoding: .utf8) else { return [] }
        var out: [WatchSymbol] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "\t")
            let code = parts.first.map { cleanCode($0) } ?? ""
            if code.isEmpty { continue }
            let alias = parts.count > 1 ? cleanAlias(parts[1]) : ""
            out.append(WatchSymbol(code: code, alias: alias))
        }
        return out
    }

    /// 코드 추가(중복이면 false). 별칭은 선택.
    @discardableResult
    static func add(code rawCode: String, alias rawAlias: String, _ paths: ConfigPaths = .standard) -> Bool {
        let code = cleanCode(rawCode)
        guard !code.isEmpty else { return false }
        var list = read(paths)
        guard !list.contains(where: { $0.code == code }) else { return false }
        list.append(WatchSymbol(code: code, alias: cleanAlias(rawAlias)))
        write(list, paths)
        return true
    }

    /// 코드 삭제.
    static func remove(code rawCode: String, _ paths: ConfigPaths = .standard) {
        let code = cleanCode(rawCode)
        guard !code.isEmpty else { return }
        write(read(paths).filter { $0.code != code }, paths)
    }

    /// 외부에서 정한 순서로 통째 저장(드래그 재배치). add/remove와 동일한 write 경로.
    static func save(_ list: [WatchSymbol], _ paths: ConfigPaths = .standard) {
        write(list, paths)
    }

    private static func write(_ list: [WatchSymbol], _ paths: ConfigPaths) {
        let text = list.map { "\($0.code)\t\($0.alias)" }.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: paths.symbolsTSV, options: .atomic)
    }
}
