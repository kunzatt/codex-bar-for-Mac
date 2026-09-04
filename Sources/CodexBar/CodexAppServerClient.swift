import Foundation

/// Owns one persistent `codex app-server --stdio` process for exactly one CODEX_HOME.
/// All JSONL request IDs and continuations stay inside this actor so interleaved replies
/// and notifications cannot cross account boundaries.
actor CodexAppServerClient: CodexUsageProvider {
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    private let profile: AccountProfile
    private let executableURL: URL
    private let accountUpdateHandler: (@Sendable () async -> Void)?
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var stdoutLineBuffer = JSONLLineBuffer()
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var loginWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var completedLogins: [String: Result<Void, Error>] = [:]
    private var isInitialized = false
    private var initializationTask: Task<Void, Error>?
    /// A new app-server process needs one account-token refresh before its first read.
    /// Later reads still need the `refreshToken` field, but set to false so they do not rotate it.
    private var shouldRefreshAccountToken = true

    init(
        profile: AccountProfile,
        executableURL: URL,
        accountUpdateHandler: (@Sendable () async -> Void)? = nil
    ) {
        self.profile = profile
        self.executableURL = executableURL
        self.accountUpdateHandler = accountUpdateHandler
    }

    func refresh(includeUsage: Bool) async throws -> ProviderRefreshResult {
        let accountParameters: JSONValue = .object([
            "refreshToken": .bool(shouldRefreshAccountToken)
        ])
        // The current app-server requires the refreshToken field for every account/read.
        // Complete the one-time token refresh before quota requests; routine reads explicitly
        // pass false so they keep the valid session without rotating it again.
        let account = try await request(
            method: "account/read",
            params: accountParameters,
            timeout: .seconds(20)
        )
        guard !(account["requiresOpenaiAuth"]?.bool == true && account["account"]?.object == nil) else {
            throw CodexBarError.authenticationRequired
        }
        shouldRefreshAccountToken = false

        async let limitsResult = request(method: "account/rateLimits/read", timeout: .seconds(20))
        if includeUsage {
            async let usageResult = request(method: "account/usage/read", timeout: .seconds(20))
            let (limits, usage) = try await (limitsResult, usageResult)
            return ProviderRefreshResult(
                identity: ProtocolMapper.accountIdentity(from: account),
                buckets: ProtocolMapper.rateLimitBuckets(from: limits),
                tokenSummary: ProtocolMapper.tokenSummary(from: usage)
            )
        }
        let limits = try await limitsResult
        return ProviderRefreshResult(
            identity: ProtocolMapper.accountIdentity(from: account),
            buckets: ProtocolMapper.rateLimitBuckets(from: limits),
            tokenSummary: nil
        )
    }

    func beginDeviceCodeLogin() async throws -> DeviceCodeLogin {
        let result = try await request(
            method: "account/login/start",
            params: .object(["type": .string("chatgptDeviceCode")]),
            timeout: .seconds(20)
        )
        guard let login = ProtocolMapper.deviceCodeLogin(from: result) else { throw CodexBarError.invalidLoginResponse }
        return login
    }

    func waitForLogin(loginID: String) async throws {
        try await ensureStarted()
        if let completed = completedLogins.removeValue(forKey: loginID) {
            return try completed.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            loginWaiters[loginID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                await self?.timeoutLogin(loginID)
            }
        }
    }

    func cancelLogin(loginID: String) async {
        _ = try? await request(
            method: "account/login/cancel",
            params: .object(["loginId": .string(loginID)]),
            timeout: .seconds(10)
        )
        if let continuation = loginWaiters.removeValue(forKey: loginID) {
            continuation.resume(throwing: CancellationError())
        }
    }

    func logout() async {
        _ = try? await request(method: "account/logout", timeout: .seconds(10))
    }

    func shutdown() async {
        initializationTask?.cancel()
        initializationTask = nil
        let activeProcess = process
        clearProcessState(error: CodexBarError.processExited)
        activeProcess?.terminate()
        // Give the child a short grace period before the host application is allowed to exit.
        for _ in 0..<10 where activeProcess?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
    }

    private func ensureStarted() async throws {
        if let process, process.isRunning, isInitialized { return }
        if let initializationTask { return try await initializationTask.value }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.startAndInitialize()
        }
        initializationTask = task
        do {
            try await task.value
            initializationTask = nil
        } catch {
            initializationTask = nil
            throw error
        }
    }

    /// Multiple account reads are allowed to overlap, but process initialization must be single-flight.
    /// Otherwise two first requests can terminate one another's just-launched app-server process.
    private func startAndInitialize() async throws {
        if process != nil { clearProcessState(error: CodexBarError.processExited) }
        try launch()
        do {
            _ = try await issueRequest(
                method: "initialize",
                params: .object([
                    "clientInfo": .object(["name": .string("codexbar"), "version": .string("0.1.2")]),
                    "capabilities": .object(["experimentalApi": .bool(false)])
                ]),
                timeout: .seconds(10)
            )
            try sendNotification(method: "initialized")
            isInitialized = true
        } catch {
            let activeProcess = process
            clearProcessState(error: error)
            activeProcess?.terminate()
            throw error
        }
    }

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexBarError.executableNotUsable(executableURL)
        }
        let nextProcess = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profile.codexHomePath.path
        nextProcess.executableURL = executableURL
        nextProcess.arguments = ["app-server", "--stdio"]
        nextProcess.environment = environment
        nextProcess.standardInput = input
        nextProcess.standardOutput = output
        nextProcess.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receiveStdout(data) }
        }
        // stderr is deliberately drained without persisting or surfacing raw content: it can contain URLs or account data.
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        nextProcess.terminationHandler = { [weak self] _ in
            Task { await self?.processDidExit() }
        }
        try nextProcess.run()
        process = nextProcess
        inputPipe = input
        outputPipe = output
        errorPipe = errors
        stdoutLineBuffer = JSONLLineBuffer()
        isInitialized = false
        shouldRefreshAccountToken = true
    }

    private func request(method: String, params: JSONValue? = nil, timeout: Duration) async throws -> JSONValue {
        try await ensureStarted()
        return try await issueRequest(method: method, params: params, timeout: timeout)
    }

    private func issueRequest(method: String, params: JSONValue? = nil, timeout: Duration) async throws -> JSONValue {
        let requestID = nextRequestID
        nextRequestID += 1
        let message = JSONLRequest(id: requestID, method: method, params: params)
        let data = try encodeLine(message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = PendingRequest(method: method, continuation: continuation)
            do {
                try write(data)
            } catch {
                pending[requestID] = nil
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutRequest(requestID)
            }
        }
    }

    private func sendNotification(method: String, params: JSONValue? = nil) throws {
        try write(encodeLine(JSONLRequest(id: nil, method: method, params: params)))
    }

    private func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    private func write(_ data: Data) throws {
        guard let inputPipe else { throw CodexBarError.processExited }
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func receiveStdout(_ data: Data) {
        for message in stdoutLineBuffer.append(data) { handle(message) }
    }

    private func handle(_ message: JSONLMessage) {
        if let requestID = message.id?.integerValue, let pendingRequest = pending.removeValue(forKey: requestID) {
            if let error = message.error {
                let mapped: Error = Self.isExplicitAuthenticationFailure(error)
                    ? CodexBarError.authenticationRequired
                    : CodexBarError.server("server request failed")
                pendingRequest.continuation.resume(throwing: mapped)
            } else if let result = message.result {
                pendingRequest.continuation.resume(returning: result)
            } else {
                pendingRequest.continuation.resume(throwing: CodexBarError.malformedResponse)
            }
            return
        }

        guard message.method == "account/login/completed",
              let loginID = message.params?["loginId"]?.string else {
            if message.method == "account/rateLimits/updated" || message.method == "account/updated" {
                let handler = accountUpdateHandler
                Task { await handler?() }
            }
            return
        }
        let successful = message.params?["success"]?.bool ?? false
        let result: Result<Void, Error> = successful ? .success(()) : .failure(CodexBarError.authenticationRequired)
        if let waiter = loginWaiters.removeValue(forKey: loginID) {
            waiter.resume(with: result)
        } else {
            completedLogins[loginID] = result
        }
    }

    private func timeoutRequest(_ requestID: Int) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.continuation.resume(throwing: CodexBarError.timeout(method: request.method))
    }

    private func timeoutLogin(_ loginID: String) {
        guard let waiter = loginWaiters.removeValue(forKey: loginID) else { return }
        waiter.resume(throwing: CodexBarError.timeout(method: "account/login/start"))
    }

    private func processDidExit() {
        clearProcessState(error: CodexBarError.processExited)
    }

    private func clearProcessState(error: Error) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        isInitialized = false
        shouldRefreshAccountToken = true
        let outstanding = pending
        pending.removeAll()
        for item in outstanding.values { item.continuation.resume(throwing: error) }
        let waiters = loginWaiters
        loginWaiters.removeAll()
        for item in waiters.values { item.resume(throwing: error) }
    }

    /// Keep the re-login UI for unambiguous authentication failures only. Generic app-server
    /// errors sometimes contain words such as "auth" while a token refresh is in progress.
    nonisolated static func isExplicitAuthenticationFailure(_ error: ServerErrorPayload) -> Bool {
        if error.code == 401 { return true }
        let message = (error.message ?? "").lowercased()
        let explicitPhrases = [
            "authentication required",
            "login required",
            "not authenticated",
            "unauthorized",
            "invalid token",
            "token expired",
            "expired token",
            "session expired"
        ]
        return explicitPhrases.contains { message.contains($0) }
    }
}
