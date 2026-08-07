import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var preferences = CodexBarPreferences()
    @Published private(set) var snapshots: [UUID: AccountUsageSnapshot] = [:]
    @Published private(set) var isBootstrapped = false
    @Published var transientMessage: String?
    @Published var showingSettings = false
    @Published var showingAddAccount = false
    @Published var reauthenticationProfile: AccountProfile?

    private let repository: AccountRepository
    private let clientPool: CodexClientPool
    private let polling: PollingCoordinator
    private var refreshingAccountIDs = Set<UUID>()
    private var queuedAccountUpdateIDs = Set<UUID>()
    private var authenticatingAccountIDs = Set<UUID>()

    init(
        repository: AccountRepository = AccountRepository(),
        clientPool: CodexClientPool = CodexClientPool(),
        polling: PollingCoordinator = PollingCoordinator()
    ) {
        self.repository = repository
        self.clientPool = clientPool
        self.polling = polling
    }

    var profiles: [AccountProfile] { preferences.profiles }
    var primaryProfile: AccountProfile? {
        guard let primaryID = preferences.primaryAccountID else { return profiles.first(where: \.isEnabled) ?? profiles.first }
        return profiles.first(where: { $0.id == primaryID }) ?? profiles.first
    }
    var primarySnapshot: AccountUsageSnapshot? { primaryProfile.flatMap { snapshots[$0.id] } }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.bootstrap()
                let loaded = await repository.currentPreferences()
                preferences = loaded
                await clientPool.setConfiguredExecutableURL(loaded.customCodexExecutablePath)
                await clientPool.setAccountUpdateHandler { [weak self] profileID in
                    await Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.refreshingAccountIDs.contains(profileID) {
                            self.queuedAccountUpdateIDs.insert(profileID)
                        } else {
                            _ = await self.refresh(profileID: profileID, includeUsage: false)
                        }
                    }.value
                }
                for profile in loaded.profiles where snapshots[profile.id] == nil {
                    snapshots[profile.id] = AccountUsageSnapshot(accountID: profile.id)
                }
                isBootstrapped = true
                restartPolling()
                await refreshAll(includeUsage: true)
            } catch {
                transientMessage = "설정을 불러오지 못했습니다. 새 설정으로 시작합니다."
                isBootstrapped = true
            }
        }
    }

    func shutdown() async {
        await polling.stop()
        await clientPool.shutdownAll()
    }

    func refreshAll(includeUsage: Bool = true) async {
        let enabled = profiles.filter(\.isEnabled)
        for (index, profile) in enabled.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(1)) }
            _ = await refresh(profileID: profile.id, includeUsage: includeUsage)
        }
    }

    @discardableResult
    func refresh(profileID: UUID, includeUsage: Bool) async -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }), profile.isEnabled else { return false }
        // A device-code login owns this profile until it completes or is cancelled. Polling
        // during that period could otherwise overwrite “로그인 중” with an old auth error.
        guard !authenticatingAccountIDs.contains(profileID) else { return true }
        guard !refreshingAccountIDs.contains(profileID) else { return true }
        refreshingAccountIDs.insert(profileID)
        defer {
            refreshingAccountIDs.remove(profileID)
            if queuedAccountUpdateIDs.remove(profileID) != nil {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.refresh(profileID: profileID, includeUsage: false)
                }
            }
        }

        var previous = snapshots[profileID] ?? AccountUsageSnapshot(accountID: profileID)
        previous.connectionState = .refreshing
        snapshots[profileID] = previous
        do {
            let result = try await clientPool.refresh(profile: profile, includeUsage: includeUsage)
            var fresh = previous
            fresh.identity = result.identity ?? previous.identity
            fresh.rateLimitBuckets = result.buckets
            if let tokens = result.tokenSummary { fresh.tokenSummary = tokens }
            fresh.fetchedAt = .now
            fresh.isStale = false
            fresh.lastError = nil
            fresh.connectionState = .ready
            snapshots[profileID] = fresh
            return true
        } catch {
            var stale = previous
            stale.isStale = true
            stale.lastError = friendly(error)
            stale.connectionState = isAuthenticationError(error) ? .authRequired : .stale
            snapshots[profileID] = stale
            return false
        }
    }

    func makePrimary(_ accountID: UUID) {
        guard profiles.contains(where: { $0.id == accountID }) else { return }
        preferences.primaryAccountID = accountID
        persist()
    }

    func rename(_ accountID: UUID, to alias: String) {
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty, let index = preferences.profiles.firstIndex(where: { $0.id == accountID }) else { return }
        preferences.profiles[index].alias = cleanAlias
        persist()
    }

    func setEnabled(_ accountID: UUID, enabled: Bool) {
        guard let index = preferences.profiles.firstIndex(where: { $0.id == accountID }) else { return }
        preferences.profiles[index].isEnabled = enabled
        if !enabled, preferences.primaryAccountID == accountID {
            preferences.primaryAccountID = preferences.profiles.first(where: { $0.isEnabled && $0.id != accountID })?.id
        }
        persist()
        restartPolling()
    }

    func setCodexExecutablePath(_ url: URL?) {
        preferences.customCodexExecutablePath = url
        persist()
        Task { await clientPool.setConfiguredExecutableURL(url) }
    }

    func addManagedAccount(alias: String) async throws -> (AccountProfile, DeviceCodeLogin) {
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty else { throw CodexBarError.invalidLoginResponse }
        let root = await repository.rootDirectory()
        let profile = try ProfileManager.createManagedProfile(alias: cleanAlias, repositoryRoot: root)
        preferences.profiles.append(profile)
        if preferences.primaryAccountID == nil { preferences.primaryAccountID = profile.id }
        snapshots[profile.id] = AccountUsageSnapshot(accountID: profile.id, connectionState: .authenticating)
        persist()
        restartPolling()
        do {
            let login = try await clientPool.beginDeviceCodeLogin(profile: profile)
            return (profile, login)
        } catch {
            updateSnapshot(profile.id) { snapshot in
                snapshot.connectionState = .error
                snapshot.lastError = friendly(error)
            }
            throw error
        }
    }

    /// Starts a device-code login for an existing profile without removing its quota history
    /// or replacing the profile. This also works for an external ~/.codex profile, but changes
    /// only happen after the user completes the device-code flow in their browser.
    func beginReauthentication(profile: AccountProfile) async throws -> DeviceCodeLogin {
        guard profiles.contains(where: { $0.id == profile.id }) else { throw CodexBarError.invalidLoginResponse }
        authenticatingAccountIDs.insert(profile.id)
        updateSnapshot(profile.id) { snapshot in
            snapshot.connectionState = .authenticating
            snapshot.lastError = nil
        }
        do {
            return try await clientPool.beginDeviceCodeLogin(profile: profile)
        } catch {
            authenticatingAccountIDs.remove(profile.id)
            updateSnapshot(profile.id) { snapshot in
                snapshot.connectionState = isAuthenticationError(error) ? .authRequired : .error
                snapshot.lastError = friendly(error)
            }
            throw error
        }
    }

    func waitForDeviceLogin(profile: AccountProfile, loginID: String) async {
        do {
            try await clientPool.waitForLogin(profile: profile, loginID: loginID)
            authenticatingAccountIDs.remove(profile.id)
            _ = await refresh(profileID: profile.id, includeUsage: true)
        } catch is CancellationError {
            authenticatingAccountIDs.remove(profile.id)
            return
        } catch {
            authenticatingAccountIDs.remove(profile.id)
            updateSnapshot(profile.id) { snapshot in
                snapshot.connectionState = isAuthenticationError(error) ? .authRequired : .error
                snapshot.lastError = friendly(error)
            }
        }
    }

    func cancelDeviceLogin(profile: AccountProfile, loginID: String) {
        Task { await clientPool.cancelLogin(profile: profile, loginID: loginID) }
    }

    func cancelReauthentication(profile: AccountProfile, loginID: String) async {
        await clientPool.cancelLogin(profile: profile, loginID: loginID)
        authenticatingAccountIDs.remove(profile.id)
        updateSnapshot(profile.id) { snapshot in
            snapshot.connectionState = .authRequired
            snapshot.lastError = "로그인이 취소되었습니다. 다시 로그인하면 사용량 갱신이 재개됩니다."
        }
    }

    func cancelAndDiscardDeviceLogin(profile: AccountProfile, loginID: String) async {
        await clientPool.cancelLogin(profile: profile, loginID: loginID)
        if profile.isManagedByApp {
            let root = await repository.rootDirectory()
            try? ProfileManager.removeManagedProfile(profile, repositoryRoot: root)
        }
        await clientPool.removeClient(for: profile.id)
        preferences.profiles.removeAll { $0.id == profile.id }
        snapshots[profile.id] = nil
        if preferences.primaryAccountID == profile.id {
            preferences.primaryAccountID = preferences.profiles.first(where: \.isEnabled)?.id ?? preferences.profiles.first?.id
        }
        persist()
        restartPolling()
    }

    func addDefaultCodexProfile(alias: String) {
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty else { return }
        let profile = ProfileManager.defaultCodexProfile(alias: cleanAlias)
        preferences.profiles.append(profile)
        if preferences.primaryAccountID == nil { preferences.primaryAccountID = profile.id }
        snapshots[profile.id] = AccountUsageSnapshot(accountID: profile.id)
        persist()
        restartPolling()
        Task { _ = await self.refresh(profileID: profile.id, includeUsage: true) }
    }

    func remove(_ profile: AccountProfile, deleteManagedFiles: Bool) async throws {
        if deleteManagedFiles && profile.isManagedByApp {
            await clientPool.logout(profile: profile)
            let root = await repository.rootDirectory()
            try ProfileManager.removeManagedProfile(profile, repositoryRoot: root)
        }
        preferences.profiles.removeAll { $0.id == profile.id }
        snapshots[profile.id] = nil
        if preferences.primaryAccountID == profile.id {
            preferences.primaryAccountID = preferences.profiles.first(where: \.isEnabled)?.id ?? preferences.profiles.first?.id
        }
        await clientPool.removeClient(for: profile.id)
        persist()
        restartPolling()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            preferences.launchAtLogin = enabled
            persist()
        } catch {
            transientMessage = "로그인 시 실행 설정을 변경하지 못했습니다. 시스템 설정에서 허용했는지 확인하세요."
        }
    }

    private func restartPolling() {
        let activeProfiles = profiles
        Task { [weak self, polling] in
            await polling.start(profiles: activeProfiles) { [weak self] id, includeUsage in
                guard let self else { return false }
                return await Task { @MainActor in
                    await self.refresh(profileID: id, includeUsage: includeUsage)
                }.value
            }
        }
    }

    private func persist() {
        let next = preferences
        Task { [repository] in
            do { _ = try await repository.save(next) }
            catch { /* A later mutation will retry; metadata remains in memory. */ }
        }
    }

    private func updateSnapshot(_ id: UUID, _ update: (inout AccountUsageSnapshot) -> Void) {
        var snapshot = snapshots[id] ?? AccountUsageSnapshot(accountID: id)
        update(&snapshot)
        snapshots[id] = snapshot
    }

    private func friendly(_ error: Error) -> String {
        if let codexError = error as? CodexBarError { return codexError.errorDescription ?? "알 수 없는 오류" }
        return "Codex 정보를 불러오지 못했습니다."
    }

    private func isAuthenticationError(_ error: Error) -> Bool {
        (error as? CodexBarError) == .authenticationRequired
    }
}
