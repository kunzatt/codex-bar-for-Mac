import Foundation
import Darwin

@main
struct CodexBarUnitRunner {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("initialize response decoding", testInitializeResponse),
            ("notification between responses", testNotification),
            ("rate limit mapping", testRateLimitMapping),
            ("null-heavy payload", testNullPayload),
            ("Int64 token usage", testTokenUsage),
            ("malformed JSONL recovery", testMalformedJSONL),
            ("duration and clamp", testDurationAndClamp),
            ("Pro-family plan recognition", testProFamilyPlanRecognition),
            ("polling backoff", testPollingBackoff),
            ("repository persistence", testRepositoryPersistence),
            ("log redaction", testRedaction)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("PASS  \(name)")
            } catch {
                failures += 1
                print("FAIL  \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) unit tests passed")
        if failures > 0 { exit(1) }
    }

    private static func testInitializeResponse() throws {
        let data = #"{"id":1,"result":{"serverInfo":{"name":"codex"}}}"#.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONLMessage.self, from: data)
        try expect(message.id?.integerValue == 1, "request ID")
        try expect(message.result?["serverInfo"]?["name"]?.string == "codex", "result object")
        try expect(message.method == nil, "must not be a notification")
    }

    private static func testNotification() throws {
        let data = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":42}}}}"#.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONLMessage.self, from: data)
        try expect(message.id == nil, "notification has no id")
        try expect(message.method == "account/rateLimits/updated", "notification method")
    }

    private static func testRateLimitMapping() throws {
        let value = try decode(#"""
        {"rateLimits":{"limitId":"legacy","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitName":"Codex 기본","primary":{"usedPercent":59,"windowDurationMins":10080,"resetsAt":1785024014},"secondary":{"usedPercent":15,"windowDurationMins":300,"resetsAt":1784700000}},"fast":{"limitId":"fast","primary":{"usedPercent":120,"windowDurationMins":60}}}}
        """#)
        let buckets = ProtocolMapper.rateLimitBuckets(from: value)
        try expect(buckets.count == 2, "all buckets")
        try expect(buckets.first?.limitId == "codex", "codex first")
        try expect(buckets.first?.primary?.remainingPercent == 41, "primary remaining")
        try expect(buckets.first?.secondary?.remainingPercent == 85, "secondary remaining")
        try expect(buckets.last?.primary?.remainingPercent == 0, "clamp usedPercent")
    }

    private static func testNullPayload() throws {
        let value = try decode(#"{"rateLimits":{"limitId":null,"limitName":null,"primary":null,"secondary":null,"credits":null}}"#)
        let buckets = ProtocolMapper.rateLimitBuckets(from: value)
        try expect(buckets.count == 1, "fallback bucket")
        try expect(buckets[0].limitId == "codex", "safe fallback id")
        try expect(buckets[0].primary == nil, "null window")
    }

    private static func testTokenUsage() throws {
        let value = try decode(#"{"summary":{"lifetimeTokens":9000000000000000000,"peakDailyTokens":1234567,"currentStreakDays":10},"dailyUsageBuckets":[{"startDate":"2026-07-20","tokens":12345}]}"#)
        let usage = ProtocolMapper.tokenSummary(from: value)
        try expect(usage.lifetimeTokens == 9_000_000_000_000_000_000, "Int64 lifetime")
        try expect(usage.dailyBuckets == [DailyTokenUsage(startDate: "2026-07-20", tokens: 12_345)], "daily bucket")
    }

    private static func testMalformedJSONL() throws {
        var buffer = JSONLLineBuffer()
        let messages = buffer.append(Data("{bad json}\n{\"id\":2,\"result\":{}}\n".utf8))
        try expect(messages.count == 1, "must skip one malformed line")
        try expect(messages.first?.id?.integerValue == 2, "valid later response survives")
    }

    private static func testDurationAndClamp() throws {
        try expect(RateLimitWindow(usedPercent: -20).remainingPercent == 100, "lower clamp")
        try expect(RateLimitWindow(usedPercent: 150).remainingPercent == 0, "upper clamp")
        try expect(CodexBarFormatters.windowText(300) == "5시간", "five hours")
        try expect(CodexBarFormatters.windowText(10_080) == "1주", "one week")
        try expect(CodexBarFormatters.windowText(73) == "73분", "arbitrary duration")
    }

    private static func testProFamilyPlanRecognition() throws {
        try expect(AccountIdentity(loginType: "chatgpt", email: nil, planType: "pro").isPro, "pro")
        try expect(AccountIdentity(loginType: "chatgpt", email: nil, planType: "prolite").isPro, "prolite")
        try expect(!AccountIdentity(loginType: "chatgpt", email: nil, planType: "unknown").isPro, "unknown")
    }

    private static func testPollingBackoff() throws {
        try expect(PollingPolicy.delay(forConsecutiveFailures: 0) == 30, "normal")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 1) == 60, "first failure")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 2) == 120, "second failure")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 3) == 300, "max failure")
        try expect(PollingPolicy.delay(forConsecutiveFailures: 0) == 30, "successful reset")
    }

    private static func testRepositoryPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AccountRepository(rootURL: root)
        try await repository.bootstrap()
        let first = AccountProfile(alias: "첫 계정", codexHomePath: root.appendingPathComponent("first"), isManagedByApp: true)
        let second = AccountProfile(alias: "둘째 계정", codexHomePath: root.appendingPathComponent("second"), isManagedByApp: true)
        _ = try await repository.save(CodexBarPreferences(profiles: [first, second], primaryAccountID: second.id))
        let reloaded = AccountRepository(rootURL: root)
        try await reloaded.bootstrap()
        let preferences = await reloaded.currentPreferences()
        try expect(preferences.primaryAccountID == second.id, "primary persistence")
    }

    private static func testRedaction() throws {
        let redacted = RedactingLogger.redact("user@example.com opened https://example.com/login?token=secret")
        try expect(!redacted.contains("user@example.com"), "email must not remain")
        try expect(!redacted.contains("token=secret"), "query must not remain")
    }

    private static func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
