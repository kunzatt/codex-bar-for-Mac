import Foundation

actor AccountRepository {
    private let rootURL: URL
    private let preferencesURL: URL
    private var preferences = CodexBarPreferences()

    init(rootURL: URL? = nil) {
        let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar", isDirectory: true)
        self.rootURL = rootURL ?? defaultRoot
        self.preferencesURL = (rootURL ?? defaultRoot).appendingPathComponent("accounts.json")
    }

    func bootstrap() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do {
                preferences = try JSONDecoder.codexBar.decode(CodexBarPreferences.self, from: Data(contentsOf: preferencesURL))
            } catch {
                // Metadata is non-sensitive. A damaged file is preserved for inspection and the app recovers empty.
                preferences = CodexBarPreferences()
            }
        }
    }

    func rootDirectory() -> URL { rootURL }
    func currentPreferences() -> CodexBarPreferences { preferences }

    func save(_ newPreferences: CodexBarPreferences) throws -> CodexBarPreferences {
        preferences = newPreferences
        try persist()
        return preferences
    }

    private func persist() throws {
        let data = try JSONEncoder.codexBar.encode(preferences)
        try data.write(to: preferencesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
    }
}

enum ProfileManager {
    static func createManagedProfile(alias: String, repositoryRoot: URL) throws -> AccountProfile {
        let id = UUID()
        let accountRoot = repositoryRoot
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let codexHome = accountRoot.appendingPathComponent("codex-home", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        for url in [repositoryRoot.appendingPathComponent("Accounts", isDirectory: true), accountRoot, codexHome] {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let configURL = codexHome.appendingPathComponent("config.toml")
        let config = "cli_auth_credentials_store = \"file\"\n"
        try config.data(using: .utf8)?.write(to: configURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return AccountProfile(id: id, alias: alias.trimmingCharacters(in: .whitespacesAndNewlines), codexHomePath: codexHome, isManagedByApp: true)
    }

    static func defaultCodexProfile(alias: String) -> AccountProfile {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return AccountProfile(alias: alias, codexHomePath: home, isManagedByApp: false)
    }

    static func secureAuthenticationFile(at codexHome: URL) {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authURL.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }

    static func removeManagedProfile(_ profile: AccountProfile, repositoryRoot: URL) throws {
        guard profile.isManagedByApp else { return }
        let expected = repositoryRoot
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
        let resolvedExpected = expected.standardizedFileURL.path
        let resolvedHome = profile.codexHomePath.standardizedFileURL.path
        guard resolvedHome == expected.appendingPathComponent("codex-home", isDirectory: true).standardizedFileURL.path,
              resolvedExpected.hasPrefix(repositoryRoot.standardizedFileURL.path + "/") else {
            throw CodexBarError.invalidProfilePath
        }
        try FileManager.default.removeItem(at: expected)
    }

}

struct CodexExecutableLocator: Sendable {
    var configuredURL: URL?

    func locate() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let configuredURL { candidates.append(configuredURL) }
        candidates += [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex")
        ]
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        candidates += pathEntries.map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return match }
        if let configuredURL { throw CodexBarError.executableNotUsable(configuredURL) }
        throw CodexBarError.executableNotFound
    }

    func version(at executable: URL) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CodexBarError.executableNotUsable(executable) }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol CodexUsageProvider: Sendable {
    func refresh(includeUsage: Bool) async throws -> ProviderRefreshResult
    func beginDeviceCodeLogin() async throws -> DeviceCodeLogin
    func waitForLogin(loginID: String) async throws
    func cancelLogin(loginID: String) async
    func logout() async
    func shutdown() async
}

actor CodexClientPool {
    private var clients: [UUID: CodexAppServerClient] = [:]
    private var configuredExecutableURL: URL?
    private var accountUpdateHandler: (@Sendable (UUID) async -> Void)?

    func setConfiguredExecutableURL(_ url: URL?) async {
        guard configuredExecutableURL != url else { return }
        let activeClients = Array(clients.values)
        clients.removeAll()
        configuredExecutableURL = url
        for client in activeClients { await client.shutdown() }
    }

    func setAccountUpdateHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
        accountUpdateHandler = handler
    }

    func refresh(profile: AccountProfile, includeUsage: Bool) async throws -> ProviderRefreshResult {
        try await client(for: profile).refresh(includeUsage: includeUsage)
    }

    func beginDeviceCodeLogin(profile: AccountProfile) async throws -> DeviceCodeLogin {
        try await client(for: profile).beginDeviceCodeLogin()
    }

    func waitForLogin(profile: AccountProfile, loginID: String) async throws {
        try await client(for: profile).waitForLogin(loginID: loginID)
        ProfileManager.secureAuthenticationFile(at: profile.codexHomePath)
    }

    func cancelLogin(profile: AccountProfile, loginID: String) async {
        guard let activeClient = try? await client(for: profile) else { return }
        await activeClient.cancelLogin(loginID: loginID)
    }

    func logout(profile: AccountProfile) async {
        guard let activeClient = try? await client(for: profile) else { return }
        await activeClient.logout()
    }

    func shutdownAll() async {
        let activeClients = Array(clients.values)
        clients.removeAll()
        for client in activeClients { await client.shutdown() }
    }

    func removeClient(for accountID: UUID) async {
        guard let client = clients.removeValue(forKey: accountID) else { return }
        await client.shutdown()
    }

    private func client(for profile: AccountProfile) async throws -> CodexAppServerClient {
        if let existing = clients[profile.id] { return existing }
        let executable = try CodexExecutableLocator(configuredURL: configuredExecutableURL).locate()
        let profileID = profile.id
        let newClient = CodexAppServerClient(profile: profile, executableURL: executable) { [weak self] in
            await self?.forwardAccountUpdate(for: profileID)
        }
        clients[profile.id] = newClient
        return newClient
    }

    private func forwardAccountUpdate(for profileID: UUID) async {
        await accountUpdateHandler?(profileID)
    }
}

actor PollingCoordinator {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(
        profiles: [AccountProfile],
        refresh: @escaping @Sendable (UUID, Bool) async -> Bool
    ) {
        stop()
        for (index, profile) in profiles.enumerated() where profile.isEnabled {
            let profileID = profile.id
            tasks[profileID] = Task { [weak self] in
                if index > 0 { try? await Task.sleep(for: .seconds(Double(index))) }
                var consecutiveFailures = 0
                var cycle = 0
                while !Task.isCancelled {
                    let includeUsage = cycle == 0 || cycle % 4 == 0
                    let succeeded = await refresh(profileID, includeUsage)
                    consecutiveFailures = succeeded ? 0 : min(consecutiveFailures + 1, 4)
                    cycle += 1
                    let base = PollingPolicy.delay(forConsecutiveFailures: consecutiveFailures)
                    let jitter = Double.random(in: 0...2)
                    try? await Task.sleep(for: .seconds(base + jitter))
                }
                await self?.removeTask(profileID)
            }
        }
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func removeTask(_ id: UUID) { tasks[id] = nil }
}

enum PollingPolicy {
    static func delay(forConsecutiveFailures failures: Int) -> Double {
        switch failures {
        case ...0: 30
        case 1: 60
        case 2: 120
        default: 300
        }
    }
}

enum CodexBarFormatters {
    static let token: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 3
        return formatter
    }()

    static func tokenText(_ tokens: Int64?) -> String {
        guard let tokens else { return "—" }
        if #available(macOS 13.0, *) {
            return tokens.formatted(.number.notation(.compactName))
        }
        return token.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    static func fullTokenText(_ tokens: Int64?) -> String {
        guard let tokens else { return "—" }
        return NumberFormatter.localizedString(from: NSNumber(value: tokens), number: .decimal)
    }

    static func windowText(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "기간 미상" }
        if minutes % (60 * 24 * 7) == 0 { return "\(minutes / (60 * 24 * 7))주" }
        if minutes % (60 * 24) == 0 { return "\(minutes / (60 * 24))일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "리셋 시각 미상" }
        let relative = RelativeDateTimeFormatter()
        relative.locale = .current
        let exact = date.formatted(date: .abbreviated, time: .shortened)
        return "\(relative.localizedString(for: date, relativeTo: .now)) · \(exact)"
    }

    static func fetchedText(_ date: Date?) -> String {
        guard let date else { return "아직 갱신하지 않음" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

enum RedactingLogger {
    static func redact(_ text: String) -> String {
        let emailPattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        let queryPattern = #"(https?://[^\s?]+)\?[^\s]+"#
        let redactedEmail = text.replacingOccurrences(of: emailPattern, with: "[email]", options: [.regularExpression, .caseInsensitive])
        return redactedEmail.replacingOccurrences(of: queryPattern, with: "$1?[redacted]", options: .regularExpression)
    }
}

private extension JSONDecoder {
    static var codexBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var codexBar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
