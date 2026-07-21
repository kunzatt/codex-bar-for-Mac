import AppKit
import SwiftUI

struct CompactHoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let primary = store.primaryProfile {
                PrimaryUsageHeader(profile: primary, snapshot: store.primarySnapshot)
                let others = store.profiles.filter { $0.id != primary.id && $0.isEnabled }
                if !others.isEmpty {
                    Divider()
                    ForEach(others) { profile in
                        CompactAccountRow(profile: profile, snapshot: store.snapshots[profile.id])
                    }
                }
            } else {
                Text("등록된 Codex 계정이 없습니다")
                    .font(.headline)
                Text("클릭하여 첫 계정을 추가하세요.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
        .background(Color.white.opacity(0.82))
        .preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
    }
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let primary = store.primaryProfile {
                        PrimaryUsageHeader(profile: primary, snapshot: store.primarySnapshot)
                        BucketDetails(snapshot: store.primarySnapshot)
                    } else {
                        ContentUnavailableView("계정이 없습니다", systemImage: "person.crop.circle.badge.plus", description: Text("ChatGPT Pro Codex 계정을 추가해 시작하세요."))
                    }

                    if !store.profiles.isEmpty {
                        Divider()
                        Text("모든 계정").font(.headline)
                        ForEach(store.profiles) { profile in
                            AccountListRow(
                                profile: profile,
                                snapshot: store.snapshots[profile.id],
                                isPrimary: profile.id == store.primaryProfile?.id,
                                makePrimary: { store.makePrimary(profile.id) }
                            )
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button {
                    Task { await store.refreshAll(includeUsage: true) }
                } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button { store.showingAddAccount = true } label: { Label("계정 추가", systemImage: "plus") }
                Button { store.showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("설정")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .accessibilityLabel("CodexBar 종료")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 400, height: 560)
        .background(Color.white.opacity(0.82))
        .preferredColorScheme(.light)
        .sheet(isPresented: $store.showingAddAccount) { AddAccountView(store: store) }
        .sheet(isPresented: $store.showingSettings) { SettingsView(store: store) }
        .alert("CodexBar", isPresented: Binding(
            get: { store.transientMessage != nil },
            set: { if !$0 { store.transientMessage = nil } }
        )) {
            Button("확인", role: .cancel) { store.transientMessage = nil }
        } message: {
            Text(store.transientMessage ?? "")
        }
    }
}

private struct PrimaryUsageHeader: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat((snapshot?.remainingPercent ?? 0)) / 100)
                    .stroke(usageColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "--")
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 72, height: 72)
            .accessibilityLabel("잔여 Codex 쿼터 \(snapshot?.remainingPercent ?? 0) 퍼센트")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.alias).font(.headline).lineLimit(1)
                    if snapshot?.identity.isPro == true { Text("Pro").font(.caption.bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.blue.opacity(0.15), in: Capsule()) }
                }
                if let email = snapshot?.identity.email {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let plan = snapshot?.identity.planType, snapshot?.identity.isPro != true {
                    Label("Pro 플랜 확인 필요 (\(plan))", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                Text(primaryDetail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text("마지막 갱신 \(CodexBarFormatters.fetchedText(snapshot?.fetchedAt))")
                    .font(.caption2).foregroundStyle(snapshot?.isStale == true ? .orange : .secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var primaryDetail: String {
        guard let primary = snapshot?.primaryCodexBucket?.primary else { return snapshot?.connectionState.displayName ?? "사용량 정보 없음" }
        return "\(CodexBarFormatters.windowText(primary.windowDurationMinutes)) · \(CodexBarFormatters.resetText(primary.resetsAt))"
    }

    private var usageColor: Color {
        switch snapshot?.remainingPercent ?? 0 {
        case 0...20: .red
        case 21...50: .orange
        default: .green
        }
    }
}

private struct CompactAccountRow: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?

    var body: some View {
        HStack(spacing: 8) {
            Text(profile.alias).lineLimit(1)
            Spacer()
            Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "--")
                .monospacedDigit()
            Text(CodexBarFormatters.resetText(snapshot?.primaryCodexBucket?.primary?.resetsAt))
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption)
        .accessibilityLabel("\(profile.alias), 잔여 \(snapshot?.remainingPercent ?? 0) 퍼센트")
    }
}

private struct AccountListRow: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?
    let isPrimary: Bool
    let makePrimary: () -> Void

    var body: some View {
        Button(action: makePrimary) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: isPrimary ? "star.fill" : "star")
                        .foregroundStyle(isPrimary ? .yellow : .secondary)
                        .accessibilityHidden(true)
                    Text(profile.alias).lineLimit(1)
                    Spacer()
                    Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "--")
                        .font(.headline.monospacedDigit())
                    StateBadge(snapshot: snapshot)
                }
                ProgressView(value: Double(snapshot?.remainingPercent ?? 0), total: 100)
                    .tint(progressTint)
                HStack {
                    Text(CodexBarFormatters.resetText(snapshot?.primaryCodexBucket?.primary?.resetsAt))
                    Spacer()
                    Text(snapshot?.isStale == true ? "오래된 정보" : CodexBarFormatters.fetchedText(snapshot?.fetchedAt))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(isPrimary ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!profile.isEnabled)
        .accessibilityLabel("\(profile.alias), \(isPrimary ? "대표 계정, " : "")잔여 \(snapshot?.remainingPercent ?? 0) 퍼센트. 선택하면 대표 계정으로 설정합니다.")
    }

    private var progressTint: Color {
        switch snapshot?.remainingPercent ?? 0 {
        case 0...20: .red
        case 21...50: .orange
        default: .green
        }
    }
}

private struct StateBadge: View {
    let snapshot: AccountUsageSnapshot?

    var body: some View {
        if let state = snapshot?.connectionState, state != .ready {
            Label(state.displayName, systemImage: symbol)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch snapshot?.connectionState {
        case .authRequired: "key.slash"
        case .stale, .error: "exclamationmark.triangle"
        case .refreshing, .starting: "arrow.triangle.2.circlepath"
        default: "circle"
        }
    }
}

private struct BucketDetails: View {
    let snapshot: AccountUsageSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot, !snapshot.rateLimitBuckets.isEmpty {
                Text("제한별 상세").font(.headline)
                ForEach(snapshot.rateLimitBuckets) { bucket in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(bucket.displayName).font(.subheadline.weight(.medium))
                            Spacer()
                            if bucket.spendControlReached == true { Label("제한 도달", systemImage: "exclamationmark.octagon") .font(.caption).foregroundStyle(.orange) }
                        }
                        if let primary = bucket.primary { WindowDetail(title: "기본", window: primary) }
                        if let secondary = bucket.secondary { WindowDetail(title: "보조", window: secondary) }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                if let lifetime = snapshot.tokenSummary.lifetimeTokens {
                    HStack {
                        TokenStat(label: "오늘", value: snapshot.tokenSummary.dailyBuckets.last?.tokens)
                        TokenStat(label: "누적", value: lifetime)
                        TokenStat(label: "최대 일간", value: snapshot.tokenSummary.peakDailyTokens)
                    }
                }
            }
        }
    }
}

private struct WindowDetail: View {
    let title: String
    let window: RateLimitWindow

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            ProgressView(value: Double(window.remainingPercent), total: 100)
            Text("\(window.remainingPercent)% 남음").monospacedDigit()
            Text(CodexBarFormatters.windowText(window.windowDurationMinutes)).foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityLabel("\(title) \(window.remainingPercent)퍼센트 남음, \(CodexBarFormatters.resetText(window.resetsAt))")
    }
}

private struct TokenStat: View {
    let label: String
    let value: Int64?

    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(CodexBarFormatters.tokenText(value)).font(.subheadline.monospacedDigit())
                .help(CodexBarFormatters.fullTokenText(value))
        }
    }
}

struct AddAccountView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var activeProfile: AccountProfile?
    @State private var login: DeviceCodeLogin?
    @State private var errorText: String?
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex 계정 추가").font(.title3.bold())
            if let login, let profile = activeProfile {
                Text("브라우저에서 ChatGPT Pro 계정으로 로그인한 뒤 아래 코드를 입력하세요.")
                Text(login.userCode).font(.system(.title2, design: .monospaced).bold()).textSelection(.enabled)
                HStack {
                    Button("브라우저 열기") { NSWorkspace.shared.open(login.verificationURL) }
                    Button("코드 복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(login.userCode, forType: .string)
                    }
                }
                Text("로그인 완료를 기다리는 중입니다. 이 창을 닫아도 Codex는 인증을 안전하게 관리합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("로그인 취소", role: .destructive) {
                    Task {
                        await store.cancelAndDiscardDeviceLogin(profile: profile, loginID: login.loginID)
                        dismiss()
                    }
                }
            } else {
                TextField("별칭 (예: 개인 Pro)", text: $alias)
                Text("각 계정은 별도의 로컬 Codex 프로필과 인증 파일을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorText { Text(errorText).foregroundStyle(.red).font(.caption) }
                HStack {
                    Button("취소", role: .cancel) { dismiss() }
                    Spacer()
                    Button(isStarting ? "시작 중…" : "Device Code 로그인 시작") { beginLogin() }
                        .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func beginLogin() {
        isStarting = true
        Task {
            do {
                let result = try await store.addManagedAccount(alias: alias)
                activeProfile = result.0
                login = result.1
                NSWorkspace.shared.open(result.1.verificationURL)
                await store.waitForDeviceLogin(profile: result.0, loginID: result.1.loginID)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "로그인을 시작하지 못했습니다."
            }
            isStarting = false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var deletionCandidate: AccountProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("CodexBar 설정").font(.title2.bold())
                Spacer()
                Button("완료") { dismiss() }
            }
            GroupBox("계정") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.profiles) { profile in
                        AccountSettingsRow(profile: profile, store: store, deletionCandidate: $deletionCandidate)
                    }
                    HStack {
                        Button("새 계정 추가") { store.showingAddAccount = true }
                        Button("기본 ~/.codex 등록") { store.addDefaultCodexProfile(alias: "기본 Codex") }
                    }
                }
            }
            GroupBox("Codex 실행 파일") {
                HStack {
                    Text(store.preferences.customCodexExecutablePath?.path ?? "자동 탐색")
                        .font(.caption).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Button("선택…") { chooseExecutable() }
                    if store.preferences.customCodexExecutablePath != nil { Button("자동") { store.setCodexExecutablePath(nil) } }
                }
            }
            Toggle("로그인 시 CodexBar 실행", isOn: Binding(
                get: { store.preferences.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 500)
        .confirmationDialog("계정을 제거할까요?", isPresented: Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )) {
            if let profile = deletionCandidate {
                Button("목록에서만 제거", role: .destructive) { remove(profile, deleteFiles: false) }
                if profile.isManagedByApp {
                    Button("로그아웃 후 로컬 프로필 삭제", role: .destructive) { remove(profile, deleteFiles: true) }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            if let profile = deletionCandidate {
                Text(profile.isManagedByApp ? "두 번째 옵션은 이 계정의 Codex 인증 파일만 삭제합니다. ~/.codex 같은 외부 프로필은 삭제하지 않습니다." : "외부 프로필의 폴더와 인증 파일은 절대 삭제하지 않습니다.")
            }
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "codex 실행 파일을 선택하세요"
        if panel.runModal() == .OK { store.setCodexExecutablePath(panel.url) }
    }

    private func remove(_ profile: AccountProfile, deleteFiles: Bool) {
        Task {
            do { try await store.remove(profile, deleteManagedFiles: deleteFiles) }
            catch { store.transientMessage = "계정을 제거하지 못했습니다. \((error as? LocalizedError)?.errorDescription ?? "")" }
        }
    }
}

private struct AccountSettingsRow: View {
    let profile: AccountProfile
    @ObservedObject var store: UsageStore
    @Binding var deletionCandidate: AccountProfile?

    var body: some View {
        HStack(spacing: 8) {
            Button { store.makePrimary(profile.id) } label: {
                Image(systemName: profile.id == store.primaryProfile?.id ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("대표 계정 설정")
            TextField("별칭", text: Binding(
                get: { store.profiles.first(where: { $0.id == profile.id })?.alias ?? profile.alias },
                set: { store.rename(profile.id, to: $0) }
            ))
            Toggle("활성", isOn: Binding(
                get: { store.profiles.first(where: { $0.id == profile.id })?.isEnabled ?? false },
                set: { store.setEnabled(profile.id, enabled: $0) }
            ))
            .toggleStyle(.switch).labelsHidden()
            Text(profile.isManagedByApp ? "앱 관리" : "외부")
                .font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { deletionCandidate = profile } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).accessibilityLabel("계정 제거")
        }
        .help(store.snapshots[profile.id]?.lastError ?? "마지막 정상 갱신: \(CodexBarFormatters.fetchedText(store.snapshots[profile.id]?.fetchedAt))")
        if let snapshot = store.snapshots[profile.id] {
            Text(snapshot.lastError ?? "마지막 정상 갱신: \(CodexBarFormatters.fetchedText(snapshot.fetchedAt))")
                .font(.caption2).foregroundStyle(snapshot.lastError == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
    }
}
