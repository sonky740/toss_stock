import Foundation

// ─────────────────────────────────────────────────────────────
// TossDTO — 토스 Open API 응답 DTO. 표시용 Row 타입은 DisplayRow.swift.
// 실측(2026-06-23): 모든 금액/수량 필드는 JSON 문자열("334000", "-0.0497").
// 합성 Decodable은 `decode(Double.self)`로 문자열에 typeMismatch를 던져 struct 전체가
// 깨진다 → 금액을 가진 DTO는 전부 수동 init(from:)에서 decimal() 헬퍼를 쓴다.
// ─────────────────────────────────────────────────────────────

struct ApiResponse<T: Decodable>: Decodable { let result: T }

struct OAuth2TokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", expiresIn = "expires_in" }
}

// String→Double: 정상문자열/숫자형/null/키누락/빈문자열 전부 크래시 없이 처리.
extension KeyedDecodingContainer {
    func decimal(_ key: Key) -> Double? {
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Double(s) { return v }
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return n }
        return nil
    }
}

// 스펙: 클라이언트는 unknown enum 값을 허용해야 한다 → 흡수(안 그러면 중첩 디코드라 보유 통째 블랭크).
enum Currency: Decodable, Sendable, Equatable {
    case krw, usd, unknown(String)
    init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "KRW": self = .krw
        case "USD": self = .usd
        case let other: self = .unknown(other)
        }
    }
    var isUSD: Bool { self == .usd }
}

struct Account: Decodable, Sendable {
    let accountNo: String
    let accountSeq: Int      // 실측: number (token.json엔 string으로 저장 — 플러그인 호환)
    let accountType: String
}

// /holdings — .result.{...합계, items[]} 중 items만 사용
struct HoldingsOverview: Decodable, Sendable {
    let items: [HoldingsItem]
}

struct HoldingsItem: Decodable, Sendable {
    let symbol: String
    let name: String
    let currency: Currency
    let lastPrice: Double?       // 거래통화 기준(KR=KRW, US=USD)
    let profitLoss: ProfitLoss   // 누적 손익(보유섹션이 쓰는 것). dailyProfitLoss는 안 씀.

    enum CodingKeys: String, CodingKey { case symbol, name, currency, lastPrice, profitLoss }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        name = try c.decode(String.self, forKey: .name)
        currency = try c.decode(Currency.self, forKey: .currency)
        lastPrice = c.decimal(.lastPrice)
        profitLoss = try c.decode(ProfitLoss.self, forKey: .profitLoss)
    }
}

struct ProfitLoss: Decodable, Sendable {
    let amount: Double?   // 평가손익액(거래통화)
    let rate: Double?     // 소수비율 -0.0497 = -4.97% (통화무관)
    enum CodingKeys: String, CodingKey { case amount, rate }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = c.decimal(.amount)
        rate = c.decimal(.rate)
    }
}

struct PriceResponse: Decodable, Sendable {
    let symbol: String
    let lastPrice: Double?
    let currency: Currency
    enum CodingKeys: String, CodingKey { case symbol, lastPrice, currency }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        lastPrice = c.decimal(.lastPrice)
        currency = try c.decode(Currency.self, forKey: .currency)
    }
}

struct StockInfo: Decodable, Sendable {
    let symbol: String
    let name: String           // 한글 종목명
}

// /candles?interval=1d&count=2 — candles[0]=오늘, candles[1]=전일종가
struct CandlePageResponse: Decodable, Sendable {
    let candles: [Candle]
}

struct Candle: Decodable, Sendable {
    let closePrice: Double?
    enum CodingKeys: String, CodingKey { case closePrice }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        closePrice = c.decimal(.closePrice)
    }
}
