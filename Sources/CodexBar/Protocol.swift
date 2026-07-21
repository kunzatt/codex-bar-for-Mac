import Foundation

/// A tolerant representation of app-server JSON. Keeping this at the protocol boundary
/// prevents unstable raw payloads from leaking into the app's domain model.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var int64: Int64? {
        switch self {
        case .integer(let value): value
        case .number(let value): Int64(value)
        case .string(let value): Int64(value)
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    subscript(_ key: String) -> JSONValue? { object?[key] }
}

struct RequestIdentifier: Codable, Equatable, Sendable {
    let integerValue: Int?

    init(_ integerValue: Int) { self.integerValue = integerValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) { integerValue = number }
        else if let text = try? container.decode(String.self) { integerValue = Int(text) }
        else { integerValue = nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(integerValue)
    }
}

struct ServerErrorPayload: Decodable, Sendable {
    let code: Int?
    let message: String?
}

struct JSONLMessage: Decodable, Sendable {
    let id: RequestIdentifier?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: ServerErrorPayload?
}

struct JSONLRequest: Encodable, Sendable {
    let id: Int?
    let method: String
    let params: JSONValue?
}

/// Incrementally decodes stdout JSONL and discards only the malformed line, allowing
/// a long-lived app-server connection to recover on its next valid message.
struct JSONLLineBuffer: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [JSONLMessage] {
        buffer.append(data)
        var messages: [JSONLMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty, let message = try? JSONDecoder().decode(JSONLMessage.self, from: line) else { continue }
            messages.append(message)
        }
        return messages
    }
}

enum ProtocolMapper {
    static func accountIdentity(from result: JSONValue) -> AccountIdentity {
        let account = result["account"]?.object
        return AccountIdentity(
            loginType: account?["type"]?.string ?? "unknown",
            email: account?["email"]?.string,
            planType: account?["planType"]?.string
        )
    }

    static func rateLimitBuckets(from result: JSONValue) -> [RateLimitBucket] {
        let multiBucket = result["rateLimitsByLimitId"]?.object ?? [:]
        let buckets: [RateLimitBucket]
        if !multiBucket.isEmpty {
            buckets = multiBucket.compactMap { key, value in bucket(from: value, fallbackID: key) }
        } else if let defaultBucket = result["rateLimits"] {
            buckets = bucket(from: defaultBucket, fallbackID: "codex").map { [$0] } ?? []
        } else {
            buckets = []
        }
        return buckets.sorted { lhs, rhs in
            if lhs.limitId == "codex" { return true }
            if rhs.limitId == "codex" { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func tokenSummary(from result: JSONValue) -> TokenUsageSummary {
        let summary = result["summary"]?.object
        let daily = result["dailyUsageBuckets"]?.array?.compactMap { entry -> DailyTokenUsage? in
            guard let object = entry.object,
                  let startDate = object["startDate"]?.string,
                  let tokens = object["tokens"]?.int64 else { return nil }
            return DailyTokenUsage(startDate: startDate, tokens: tokens)
        } ?? []
        return TokenUsageSummary(
            lifetimeTokens: summary?["lifetimeTokens"]?.int64,
            peakDailyTokens: summary?["peakDailyTokens"]?.int64,
            longestRunningTurnSeconds: summary?["longestRunningTurnSec"]?.int64,
            currentStreakDays: summary?["currentStreakDays"]?.int64,
            longestStreakDays: summary?["longestStreakDays"]?.int64,
            dailyBuckets: daily
        )
    }

    static func deviceCodeLogin(from result: JSONValue) -> DeviceCodeLogin? {
        guard result["type"]?.string == "chatgptDeviceCode",
              let loginID = result["loginId"]?.string,
              let userCode = result["userCode"]?.string,
              let urlText = result["verificationUrl"]?.string,
              let url = URL(string: urlText) else { return nil }
        return DeviceCodeLogin(loginID: loginID, userCode: userCode, verificationURL: url)
    }

    private static func bucket(from value: JSONValue, fallbackID: String) -> RateLimitBucket? {
        guard let raw = value.object else { return nil }
        let limitID = raw["limitId"]?.string ?? fallbackID
        return RateLimitBucket(
            limitId: limitID,
            displayName: raw["limitName"]?.string?.nonEmpty ?? limitID,
            primary: window(from: raw["primary"]),
            secondary: window(from: raw["secondary"]),
            hasCredits: raw["credits"]?["hasCredits"]?.bool,
            unlimitedCredits: raw["credits"]?["unlimited"]?.bool,
            creditBalance: raw["credits"]?["balance"]?.string,
            spendControlReached: raw["spendControlReached"]?.bool,
            planType: raw["planType"]?.string,
            rateLimitReachedType: raw["rateLimitReachedType"]?.string
        )
    }

    private static func window(from value: JSONValue?) -> RateLimitWindow? {
        guard let raw = value?.object, let usedPercent = raw["usedPercent"]?.double else { return nil }
        let duration = raw["windowDurationMins"]?.int64 ?? raw["windowDurationMinutes"]?.int64
        let resetSeconds = raw["resetsAt"]?.double
        return RateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: duration.map(Int.init),
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
