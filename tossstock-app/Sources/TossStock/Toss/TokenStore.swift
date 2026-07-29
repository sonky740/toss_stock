import Foundation

// ─────────────────────────────────────────────────────────────
// TokenStore — OAuth2 토큰 관리.
// 핵심 제약: client당 토큰 1개(재발급 시 이전 토큰 즉시 무효화 + AUTH rate limit).
//   (a) 만료까지 캐시 재사용  (b) 만료 5분 전 선제 재발급(저장 시 반영)
//   (c) 동시 다수 요청이 만료를 동시 감지해도 재발급 1회  (d) 401 시 단일 재발급
// 토큰 저장 a안: 플러그인과 ~/.config/tossstock/token.json 캐시 공유(동일 스키마, atomic).
// ─────────────────────────────────────────────────────────────

struct Credentials: Sendable {
  let clientId: String
  let clientSecret: String
}

struct CachedToken: Sendable {
  let accessToken: String
  let expiresAt: Date
  var accountSeq: Int?
}

enum TossAuthError: Error, Sendable {
  case missingCredentials
  case mintFailed(status: Int)
  case noAccount
}

// token.json 스키마(셸 플러그인과 공유): expires_at=unix초(number), account_seq=string.
private struct TokenCacheFile: Codable {
  let access_token: String
  let expires_at: Int
  let account_seq: String?
}

actor TokenStore {
  private let config: ConfigPaths
  private let http: TossHTTP
  private var cached: CachedToken?
  private var refreshTask: Task<CachedToken, Error>?

  init(config: ConfigPaths = .standard, http: TossHTTP = TossHTTP()) {
    self.config = config
    self.http = http
    self.cached = Self.loadCache(config)  // 플러그인이 써둔 토큰 재사용
  }

  /// 유효한 토큰 확보(캐시 우선, 만료면 재발급).
  func token() async throws -> CachedToken {
    if let c = cached, c.expiresAt > Date() { return c }
    return try await refresh(invalidating: nil)
  }

  /// 401 수신 후 호출. 그새 다른 caller가 갱신했으면 그 토큰을, 아니면 단일 재발급.
  func forceRefresh(used stale: String) async throws -> CachedToken {
    if let c = cached, c.accessToken != stale, c.expiresAt > Date() { return c }
    return try await refresh(invalidating: stale)
  }

  /// X-Tossinvest-Account 헤더용 accountSeq. 캐시에 있으면 네트워크 0(accounts는 limit=1).
  func accountSeq() async throws -> Int {
    let t = try await token()
    if let seq = t.accountSeq { return seq }
    let seq = try await fetchAccountSeq(token: t.accessToken)
    let updated = CachedToken(accessToken: t.accessToken, expiresAt: t.expiresAt, accountSeq: seq)
    cached = updated
    persist(updated)
    return seq
  }

  func currentExpiry() -> Date? { cached?.expiresAt }
  func cachedSeq() -> Int? { cached?.accountSeq }

  /// 자격증명(auth.env) 존재 여부. actor 인스턴스 없이 동기 확인 가능.
  nonisolated static func hasCredentials(_ config: ConfigPaths = .standard) -> Bool {
    loadCredentials(config) != nil
  }

  // ── in-flight 공유: refreshTask를 await '이전'에 동기 세팅하는 게 핵심 ──
  private func refresh(invalidating: String?) async throws -> CachedToken {
    if let refreshTask { return try await refreshTask.value }  // 진행 중이면 합류
    let task = Task { try await self.reloadOrMint(invalidating: invalidating) }
    refreshTask = task  // ← await 전 동기 세팅(thundering-herd 차단)
    defer { refreshTask = nil }
    return try await task.value
  }

  // 재발급 전 디스크 재확인: 플러그인(같은 client_id)이 이미 더 새 토큰을 써뒀으면 그걸 채택해
  // 불필요한 mint를 피한다(이중 클라이언트 thrashing 차단 — a안의 핵심).
  private func reloadOrMint(invalidating stale: String?) async throws -> CachedToken {
    if let disk = Self.loadCache(config), disk.expiresAt > Date(), disk.accessToken != stale {
      cached = disk
      return disk
    }
    return try await fetchAndCache()
  }

  private func fetchAndCache() async throws -> CachedToken {
    guard let creds = Self.loadCredentials(config) else { throw TossAuthError.missingCredentials }
    let resp = try await http.mintToken(creds)
    let expiresAt = Date().addingTimeInterval(Double(resp.expiresIn) - 300)  // 5분 선제
    let seq = try? await fetchAccountSeq(token: resp.accessToken)
    let tok = CachedToken(accessToken: resp.accessToken, expiresAt: expiresAt, accountSeq: seq)
    cached = tok
    persist(tok)
    return tok
  }

  private func fetchAccountSeq(token: String) async throws -> Int {
    let accounts = try await http.accounts(token: token)
    guard let first = accounts.first else { throw TossAuthError.noAccount }
    return first.accountSeq
  }

  // ── 자격증명 / 캐시 파일 I/O ──
  private static func loadCredentials(_ paths: ConfigPaths) -> Credentials? {
    guard let text = try? String(contentsOf: paths.authEnv, encoding: .utf8) else { return nil }
    var map: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces)
      let value = stripQuotes(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
      map[key] = value
    }
    guard let id = map["TOSS_CLIENT_ID"], let secret = map["TOSS_CLIENT_SECRET"],
      !id.isEmpty, !secret.isEmpty
    else { return nil }
    return Credentials(clientId: id, clientSecret: secret)
  }

  private static func stripQuotes(_ s: String) -> String {
    guard s.count >= 2, let f = s.first, let l = s.last, f == l, f == "'" || f == "\"" else { return s }
    return String(s.dropFirst().dropLast())
  }

  private static func loadCache(_ paths: ConfigPaths) -> CachedToken? {
    guard let data = try? Data(contentsOf: paths.tokenJSON),
      let file = try? JSONDecoder().decode(TokenCacheFile.self, from: data),
      !file.access_token.isEmpty
    else { return nil }
    let seq = file.account_seq.flatMap { Int($0) }
    return CachedToken(
      accessToken: file.access_token,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(file.expires_at)),
      accountSeq: seq)
  }

  private func persist(_ token: CachedToken) {
    let file = TokenCacheFile(
      access_token: token.accessToken,
      expires_at: Int(token.expiresAt.timeIntervalSince1970),
      account_seq: token.accountSeq.map(String.init)
    )
    guard let data = try? JSONEncoder().encode(file) else { return }
    let url = config.tokenJSON
    try? FileManager.default.createDirectory(at: config.dir, withIntermediateDirectories: true)
    // .atomic = 임시파일 작성 후 rename. 직후 0600(셸의 umask 077과 동등 의도).
    guard (try? data.write(to: url, options: .atomic)) != nil else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
