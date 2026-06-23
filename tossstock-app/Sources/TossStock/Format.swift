import Foundation

// ─────────────────────────────────────────────────────────────
// Format — 표시 문자열 포맷(Foundation만, Vue/AppKit 무관 순수 함수).
// 셸 플러그인 포맷과 1:1 패리티:
//   보유 수익률%는 부호 있음(flat 무부호), 관심 등락률%는 절대값+화살표가 부호 운반.
//   원화 등락 변화량엔 ₩ 없음(셸 동작), 달러 변화량엔 $ 있음.
// ─────────────────────────────────────────────────────────────

enum Fmt {
    /// 정수 문자열에 1000단위 콤마(로케일 무관 강제 콤마).
    private static func group(_ digits: String) -> String {
        var out: [Character] = []
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }

    /// 현재가(원화): ₩351,500
    static func krw(_ v: Double) -> String {
        "₩" + group(String(Int(v.rounded())))
    }

    /// 현재가(달러): $1,234.05
    static func usd(_ v: Double) -> String {
        dollars(v, signed: false, zeroDollars: false)
    }

    /// 통화별 현재가
    static func price(_ v: Double, _ currency: Currency) -> String {
        currency.isUSD ? usd(v) : krw(v)
    }

    /// 평가손익(원화): +16,750원 / -1,000원 / 0원
    static func pnlKRW(_ v: Double) -> String {
        let n = Int(v.rounded())
        if n == 0 { return "0원" }
        return (n > 0 ? "+" : "-") + group(String(abs(n))) + "원"
    }

    /// 평가손익(달러): +$232.00 / -$53.47 / $0.00
    static func pnlUSD(_ v: Double) -> String {
        dollars(v, signed: true, zeroDollars: true)
    }

    /// 통화별 평가손익
    static func pnl(_ v: Double, _ currency: Currency) -> String {
        currency.isUSD ? pnlUSD(v) : pnlKRW(v)
    }

    /// 등락 변화량(절대값). USD=$14.02 / KRW=24,000(₩ 없음 — 셸 패리티)
    static func changeAbs(_ v: Double, _ currency: Currency) -> String {
        currency.isUSD ? dollars(abs(v), signed: false, zeroDollars: false)
                       : group(String(Int(abs(v).rounded())))
    }

    /// 보유 수익률%(부호 있음, flat 무부호): -5.40% / +12.84% / 0.00%
    static func pctSigned(_ pct: Double, _ dir: Direction) -> String {
        dir == .flat ? String(format: "%.2f%%", pct) : String(format: "%+.2f%%", pct)
    }

    /// 관심 등락률%(절대값 — 화살표가 부호 운반): 6.73%
    static func pctAbs(_ pct: Double) -> String {
        String(format: "%.2f%%", pct)
    }

    static func arrow(_ dir: Direction) -> String {
        switch dir { case .up: "▲"; case .down: "▼"; case .flat: "▬" }
    }

    // 달러 포맷 공통: 정수부 콤마 + 소수 2자리. signed=부호 표시, zeroDollars=0이면 "$0.00"(무부호)
    private static func dollars(_ v: Double, signed: Bool, zeroDollars: Bool) -> String {
        let s = String(format: "%.2f", abs(v))
        if zeroDollars && s == "0.00" { return "$0.00" }
        let parts = s.split(separator: ".", maxSplits: 1)
        let intPart = group(String(parts[0]))
        let dec = parts.count > 1 ? String(parts[1]) : "00"
        let prefix = signed ? (v > 0 ? "+$" : (v < 0 ? "-$" : "$")) : (v < 0 ? "-$" : "$")
        return prefix + intPart + "." + dec
    }
}
