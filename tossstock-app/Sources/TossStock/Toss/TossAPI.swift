import Foundation

// ─────────────────────────────────────────────────────────────
// TossAPI — URLSession 요청 계층.
//   TossHTTP: 인증 무관 순수 I/O(토큰 발급/계좌조회/일반 GET).
//   TossAPI : Bearer 부착 + (필요시)X-Tossinvest-Account + ApiResponse<T> 디코드
//             + 401 단일 재발급 재시도 + 429 단일 백오프 재시도.
// ─────────────────────────────────────────────────────────────

enum TossError: Error, Sendable {
    case http(Int)
    case notHTTP
}

struct TossHTTP: Sendable {
    let base = URL(string: "https://openapi.tossinvest.com")!

    private func makeURL(_ path: String) -> URL {
        // path는 쿼리 포함 전체 경로("/api/v1/prices?symbols=A,B"). 심볼은 영숫자/콤마라 그대로 안전.
        URL(string: base.absoluteString + path) ?? base
    }

    func get(path: String, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TossError.notHTTP }
        return (data, http)
    }

    func mintToken(_ creds: Credentials) async throws -> OAuth2TokenResponse {
        var req = URLRequest(url: makeURL("/oauth2/token"))
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode([
            ("grant_type", "client_credentials"),
            ("client_id", creds.clientId),
            ("client_secret", creds.clientSecret),
        ]).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TossError.notHTTP }
        guard http.statusCode == 200 else { throw TossAuthError.mintFailed(status: http.statusCode) }
        return try JSONDecoder().decode(OAuth2TokenResponse.self, from: data)
    }

    func accounts(token: String) async throws -> [Account] {
        let (data, http) = try await get(path: "/api/v1/accounts",
                                         headers: ["Authorization": "Bearer \(token)"])
        guard http.statusCode == 200 else { throw TossError.http(http.statusCode) }
        return try JSONDecoder().decode(ApiResponse<[Account]>.self, from: data).result
    }

    private static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

struct TossAPI: Sendable {
    let http: TossHTTP
    let tokens: TokenStore

    init(http: TossHTTP = TossHTTP(), tokens: TokenStore) {
        self.http = http
        self.tokens = tokens
    }

    func get<T: Decodable & Sendable>(_ path: String, needsAccount: Bool = false, as type: T.Type) async throws -> T {
        let data = try await fetchData(path: path, needsAccount: needsAccount)
        return try JSONDecoder().decode(ApiResponse<T>.self, from: data).result
    }

    private func fetchData(path: String, needsAccount: Bool) async throws -> Data {
        var token = try await tokens.token()
        var seq: Int? = needsAccount ? try await tokens.accountSeq() : nil
        var (data, resp) = try await send(path, token: token, seq: seq)

        if resp.statusCode == 401 {
            token = try await tokens.forceRefresh(used: token.accessToken)
            if needsAccount { seq = try await tokens.accountSeq() }
            (data, resp) = try await send(path, token: token, seq: seq)
        } else if resp.statusCode == 429 {
            try await Task.sleep(for: .seconds(Self.retryAfter(resp, body: data)))
            (data, resp) = try await send(path, token: token, seq: seq)
        }

        guard resp.statusCode == 200 else { throw TossError.http(resp.statusCode) }
        return data
    }

    private func send(_ path: String, token: CachedToken, seq: Int?) async throws -> (Data, HTTPURLResponse) {
        var headers = ["Authorization": "Bearer \(token.accessToken)"]
        if let seq { headers["X-Tossinvest-Account"] = String(seq) }
        return try await http.get(path: path, headers: headers)
    }

    private static func retryAfter(_ resp: HTTPURLResponse, body: Data) -> Double {
        if let h = resp.value(forHTTPHeaderField: "Retry-After"), let s = Double(h) { return min(max(s, 0.1), 5) }
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let raw = obj["retryAfterSeconds"]
            if let r = raw as? Double { return min(max(r, 0.1), 5) }
            if let r = raw as? Int { return min(max(Double(r), 0.1), 5) }
            if let s = raw as? String, let r = Double(s) { return min(max(r, 0.1), 5) }
        }
        return 1.0
    }
}
