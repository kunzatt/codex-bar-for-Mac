import Foundation

struct AccountProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var alias: String
    var codexHomePath: URL
    let isManagedByApp: Bool
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        alias: String,
        codexHomePath: URL,
        isManagedByApp: Bool,
        isEnabled: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.alias = alias
        self.codexHomePath = codexHomePath
        self.isManagedByApp = isManagedByApp
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

struct AccountIdentity: Codable, Hashable, Sendable {
    var loginType: String
    var email: String?
    var planType: String?

    static let unknown = AccountIdentity(loginType: "unknown", email: nil, planType: nil)

    /// Codex currently reports both `pro` and `prolite` as paid Pro-family plans.
    var isPro: Bool {
        guard let planType = planType?.lowercased() else { return false }
        return ["pro", "prolite"].contains(planType)
    }
}

struct RateLimitWindow: Codable, Hashable, Sendable {
    var usedPercent: Double
    var windowDurationMinutes: Int?
    var resetsAt: Date?

    init(usedPercent: Double, windowDurationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent.clamped(to: 0...100)
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    var remainingPercent: Int { Int((100 - usedPercent).rounded()) }
}

struct RateLimitBucket: Codable, Identifiable, Hashable, Sendable {
    var id: String { limitId }
    var limitId: String
    var displayName: String
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    var hasCredits: Bool?
    var unlimitedCredits: Bool?
    var creditBalance: String?
    var spendControlReached: Bool?
    var planType: String?
    var rateLimitReachedType: String?

    /// The app-server currently reports the weekly and five-hour Codex limits as
    /// primary/secondary windows. Their order is not a user-facing contract, so
    /// use the shortest known window for the status UI.
    var windows: [RateLimitWindow] {
        [primary, secondary].compactMap { $0 }
    }

    var shortestWindow: RateLimitWindow? {
        windows.min { lhs, rhs in
            let lhsDuration = lhs.windowDurationMinutes ?? .max
            let rhsDuration = rhs.windowDurationMinutes ?? .max
            if lhsDuration != rhsDuration { return lhsDuration < rhsDuration }

            switch (lhs.resetsAt, rhs.resetsAt) {
            case let (lhsReset?, rhsReset?): return lhsReset < rhsReset
            case (.some, .none): return true
            default: return false
            }
        }
    }
}

struct DailyTokenUsage: Codable, Identifiable, Hashable, Sendable {
    var id: String { startDate }
    var startDate: String
    var tokens: Int64
}

struct TokenUsageSummary: Codable, Hashable, Sendable {
    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    var longestRunningTurnSeconds: Int64?
    var currentStreakDays: Int64?
    var longestStreakDays: Int64?
    var dailyBuckets: [DailyTokenUsage]

    static let empty = TokenUsageSummary(
        lifetimeTokens: nil,
        peakDailyTokens: nil,
        longestRunningTurnSeconds: nil,
        currentStreakDays: nil,
        longestStreakDays: nil,
        dailyBuckets: []
    )
}

enum ConnectionState: String, Codable, Hashable, Sendable {
    case idle
    case starting
    case authenticating
    case ready
    case refreshing
    case stale
    case authRequired
    case error

    var displayName: String {
        switch self {
        case .idle: "대기 중"
        case .starting: "Codex 시작 중"
        case .authenticating: "로그인 중"
        case .ready: "정상"
        case .refreshing: "갱신 중"
        case .stale: "오래된 정보"
        case .authRequired: "로그인 필요"
        case .error: "오류"
        }
    }
}

struct AccountUsageSnapshot: Codable, Identifiable, Hashable, Sendable {
    var id: UUID { accountID }
    var accountID: UUID
    var identity: AccountIdentity
    var rateLimitBuckets: [RateLimitBucket]
    var tokenSummary: TokenUsageSummary
    var fetchedAt: Date?
    var isStale: Bool
    var lastError: String?
    var connectionState: ConnectionState

    init(
        accountID: UUID,
        identity: AccountIdentity = .unknown,
        rateLimitBuckets: [RateLimitBucket] = [],
        tokenSummary: TokenUsageSummary = .empty,
        fetchedAt: Date? = nil,
        isStale: Bool = false,
        lastError: String? = nil,
        connectionState: ConnectionState = .idle
    ) {
        self.accountID = accountID
        self.identity = identity
        self.rateLimitBuckets = rateLimitBuckets
        self.tokenSummary = tokenSummary
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.lastError = lastError
        self.connectionState = connectionState
    }

    var primaryCodexBucket: RateLimitBucket? {
        rateLimitBuckets.first(where: { $0.limitId.lowercased() == "codex" }) ?? rateLimitBuckets.first
    }

    /// The shortest active Codex quota is the one most likely to block the next
    /// request, such as the shared five-hour window for ChatGPT Pro.
    var activeCodexWindow: RateLimitWindow? { primaryCodexBucket?.shortestWindow }

    var remainingPercent: Int? { activeCodexWindow?.remainingPercent }
}

struct CodexBarPreferences: Codable, Sendable {
    var profiles: [AccountProfile] = []
    var primaryAccountID: UUID?
    var customCodexExecutablePath: URL?
    var launchAtLogin: Bool = false
}

struct DeviceCodeLogin: Sendable, Equatable {
    let loginID: String
    let userCode: String
    let verificationURL: URL
}

struct ProviderRefreshResult: Sendable {
    let identity: AccountIdentity?
    let buckets: [RateLimitBucket]
    let tokenSummary: TokenUsageSummary?
}

enum CodexBarError: LocalizedError, Sendable, Equatable {
    case executableNotFound
    case executableNotUsable(URL)
    case unsupportedProtocol
    case timeout(method: String)
    case processExited
    case malformedResponse
    case authenticationRequired
    case server(String)
    case invalidLoginResponse
    case invalidProfilePath

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Codex 실행 파일을 찾을 수 없습니다. 설정에서 경로를 지정하세요."
        case .executableNotUsable: "선택한 Codex 실행 파일을 실행할 수 없습니다."
        case .unsupportedProtocol: "설치된 Codex app-server 프로토콜을 지원하지 않습니다."
        case .timeout: "Codex 응답 시간이 초과되었습니다."
        case .processExited: "Codex app-server가 예기치 않게 종료되었습니다."
        case .malformedResponse: "Codex에서 해석할 수 없는 응답을 받았습니다."
        case .authenticationRequired: "이 계정은 다시 로그인해야 합니다."
        case .server: "Codex 정보를 갱신하지 못했습니다. 잠시 후 자동으로 다시 시도합니다."
        case .invalidLoginResponse: "Codex 로그인 응답이 예상과 다릅니다."
        case .invalidProfilePath: "보안을 위해 이 프로필 경로는 삭제할 수 없습니다."
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
