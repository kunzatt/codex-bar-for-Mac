import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    let addAccount: () -> Void
    let reauthenticate: (AccountProfile) -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(store: store)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let primary = store.primaryProfile {
                        PrimaryQuotaCard(
                            profile: primary,
                            snapshot: store.primarySnapshot,
                            reauthenticate: { reauthenticate(primary) }
                        )

                        if let snapshot = store.primarySnapshot,
                           !snapshot.rateLimitBuckets.isEmpty {
                            QuotaDetailsSection(snapshot: snapshot, isExpanded: $showsDetails)
                        }

                        let otherProfiles = store.profiles.filter { $0.id != primary.id }
                        if !otherProfiles.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle(title: "다른 계정", detail: "별을 눌러 대표 계정을 바꿉니다")
                                VStack(spacing: 0) {
                                    ForEach(Array(otherProfiles.enumerated()), id: \.element.id) { index, profile in
                                        OtherAccountRow(
                                            profile: profile,
                                            snapshot: store.snapshots[profile.id],
                                            makePrimary: { store.makePrimary(profile.id) },
                                            reauthenticate: { reauthenticate(profile) }
                                        )
                                        if index < otherProfiles.count - 1 {
                                            Divider().padding(.leading, 45)
                                        }
                                    }
                                }
                                .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    } else {
                        EmptyDashboard(addAccount: addAccount)
                    }
                }
                .padding(16)
            }

            Divider()
            PopoverFooter(addAccount: addAccount)
        }
        .frame(width: 420, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct PopoverHeader: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("CODEXBAR")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text("사용량")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            Button {
                Task { await store.refreshAll(includeUsage: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("모든 계정 새로고침 ⌘R")
            .accessibilityLabel("모든 계정 새로고침")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct PopoverFooter: View {
    let addAccount: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    presentSettings()
                } label: {
                    Label("설정", systemImage: "gearshape")
                }
                Divider()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("CodexBar 종료", systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("더 보기")
            .accessibilityLabel("더 보기")

            Spacer()

            Button {
                addAccount()
            } label: {
                Label("계정 추가", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @MainActor
    private func presentSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        bringSettingsWindowForward()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            NSApp.activate(ignoringOtherApps: true)
            bringSettingsWindowForward()
        }
    }

    @MainActor
    private func bringSettingsWindowForward() {
        NSApp.windows
            .first { window in
                window.isVisible
                    && window.styleMask.contains(.titled)
                    && !(window is NSPanel)
            }?
            .makeKeyAndOrderFront(nil)
    }
}

private struct EmptyDashboard: View {
    let addAccount: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: 6) {
                Text("Codex 사용량을 한눈에")
                    .font(.title3.weight(.semibold))
                Text("계정을 연결하면 남은 쿼터와 초기화 시각을\n메뉴바에서 바로 확인할 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: addAccount) {
                Label("첫 계정 연결", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Label("인증 정보는 Mac 안에서 Codex가 직접 관리합니다", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

private struct PrimaryQuotaCard: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?
    let reauthenticate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                RemainingRing(window: snapshot?.activeCodexWindow, size: 90, lineWidth: 9, font: .title3.weight(.bold))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(profile.alias)
                            .font(.headline)
                            .lineLimit(1)
                        if let planName = snapshot?.identity.codexPlanName {
                            PlanBadge(text: planName)
                        }
                    }

                    if let email = snapshot?.identity.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(activeResetSummary(snapshot))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        StatusLabel(snapshot: snapshot)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(CodexBarFormatters.fetchedText(snapshot?.fetchedAt))
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if snapshot?.connectionState == .authRequired {
                InlineNotice(
                    text: snapshot?.lastError ?? "로그인이 필요합니다.",
                    symbol: "key.slash",
                    tint: .orange,
                    actionTitle: "다시 로그인",
                    action: reauthenticate
                )
            } else if let error = snapshot?.lastError {
                InlineNotice(text: error, symbol: "exclamationmark.triangle", tint: .orange)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.13), Color.accentColor.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct RemainingRing: View {
    let window: RateLimitWindow?
    let size: CGFloat
    let lineWidth: CGFloat
    let font: Font

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    usageColor(window?.remainingPercent),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(window.map { "\($0.remainingPercent)%" } ?? "—")
                    .font(font)
                    .monospacedDigit()
                if size > 70 {
                    Text(quotaWindowTitle(window))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remainingAccessibilityText(window?.remainingPercent, window: window))
    }

    private var progress: CGFloat {
        guard let remaining = window?.remainingPercent else { return 0 }
        return CGFloat(remaining) / 100
    }
}

private struct OtherAccountRow: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?
    let makePrimary: () -> Void
    let reauthenticate: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(statusTint(snapshot).opacity(0.13))
                Image(systemName: statusSymbol(snapshot))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint(snapshot))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.alias)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if !profile.isEnabled {
                        Text("꺼짐")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(accountSecondaryText(profile: profile, snapshot: snapshot))
                    .font(.caption)
                    .foregroundStyle(snapshot?.connectionState == .authRequired ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(profile.isEnabled ? Color.primary : Color.secondary)

            if snapshot?.connectionState == .authRequired {
                Button(action: reauthenticate) {
                    Image(systemName: "key")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("\(profile.alias) 다시 로그인")
                .accessibilityLabel("\(profile.alias) 다시 로그인")
            } else {
                Button(action: makePrimary) {
                    Image(systemName: "star")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!profile.isEnabled)
                .help("\(profile.alias)을 대표 계정으로 설정")
                .accessibilityLabel("\(profile.alias)을 대표 계정으로 설정")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

private struct QuotaDetailsSection: View {
    let snapshot: AccountUsageSnapshot
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                ForEach(snapshot.rateLimitBuckets) { bucket in
                    QuotaBucketCard(bucket: bucket)
                }
                if snapshot.tokenSummary.lifetimeTokens != nil ||
                    snapshot.tokenSummary.dailyBuckets.last?.tokens != nil ||
                    snapshot.tokenSummary.peakDailyTokens != nil {
                    TokenSummaryCard(summary: snapshot.tokenSummary)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Label("제한별 상세", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(snapshot.rateLimitBuckets.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct QuotaBucketCard: View {
    let bucket: RateLimitBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(bucket.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if bucket.spendControlReached == true {
                    Label("제한 도달", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let primary = bucket.primary {
                QuotaWindowRow(title: quotaWindowTitle(primary), window: primary)
            }
            if let secondary = bucket.secondary {
                Divider()
                QuotaWindowRow(title: quotaWindowTitle(secondary), window: secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct QuotaWindowRow: View {
    let title: String
    let window: RateLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(window.remainingPercent)% 남음")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(usageColor(window.remainingPercent))
            HStack {
                Text(CodexBarFormatters.windowText(window.windowDurationMinutes))
                Spacer()
                Text("초기화 \(CodexBarFormatters.resetText(window.resetsAt))")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 제한, \(window.remainingPercent)퍼센트 남음, 초기화 \(CodexBarFormatters.resetText(window.resetsAt))")
    }
}

private struct TokenSummaryCard: View {
    let summary: TokenUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("토큰 사용")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 0) {
                TokenMetric(label: "오늘", value: summary.dailyBuckets.last?.tokens)
                Divider().frame(height: 30)
                TokenMetric(label: "누적", value: summary.lifetimeTokens)
                Divider().frame(height: 30)
                TokenMetric(label: "최대 일간", value: summary.peakDailyTokens)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TokenMetric: View {
    let label: String
    let value: Int64?

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(CodexBarFormatters.tokenText(value))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .help(CodexBarFormatters.fullTokenText(value))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

private struct StatusLabel: View {
    let snapshot: AccountUsageSnapshot?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusTint(snapshot))
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            Text(snapshot?.connectionState.displayName ?? "대기 중")
                .lineLimit(1)
        }
        .font(compact ? .caption2 : .caption)
        .foregroundStyle(.secondary)
    }
}

private struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

private struct InlineNotice: View {
    let text: String
    let symbol: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct AddAccountView: View {
    @ObservedObject var store: UsageStore
    let onClose: () -> Void
    @State private var alias = ""
    @State private var activeProfile: AccountProfile?
    @State private var login: DeviceCodeLogin?
    @State private var errorText: String?
    @State private var isStarting = false
    @State private var didCopyCode = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "계정 연결",
                subtitle: login == nil ? "ChatGPT Codex 계정을 CodexBar에 추가합니다" : "브라우저에서 로그인을 완료하세요",
                symbol: "person.badge.plus",
                dismiss: login == nil ? onClose : nil
            )
            Divider()

            Group {
                if let login, let profile = activeProfile {
                    DeviceLoginPanel(
                        accountName: profile.alias,
                        login: login,
                        didCopyCode: $didCopyCode,
                        cancelTitle: "연결 취소",
                        cancel: { cancelLogin(profile: profile, login: login) }
                    )
                } else {
                    addAccountForm
                }
            }
            .padding(24)
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(login != nil)
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("계정 이름")
                    .font(.subheadline.weight(.semibold))
                TextField("예: 개인 Plus", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { beginLogin() }
                Text("메뉴바와 계정 목록에만 표시되는 이름입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label {
                Text("계정마다 별도 로컬 프로필을 사용합니다. CodexBar는 인증 파일 내용을 읽지 않습니다.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("취소", role: .cancel, action: onClose)
                Spacer()
                Button {
                    beginLogin()
                } label: {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("로그인 계속", systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
            }
        }
    }

    private func beginLogin() {
        guard !isStarting, login == nil else { return }
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty else { return }
        isStarting = true
        errorText = nil
        Task {
            do {
                let result = try await store.addManagedAccount(alias: cleanAlias)
                activeProfile = result.0
                login = result.1
                NSWorkspace.shared.open(result.1.verificationURL)
                let completed = await store.waitForDeviceLogin(profile: result.0, loginID: result.1.loginID)
                if completed {
                    onClose()
                } else {
                    login = nil
                    errorText = store.snapshots[result.0.id]?.lastError ?? "로그인을 완료하지 못했습니다."
                }
            } catch {
                errorText = localizedMessage(error, fallback: "로그인을 시작하지 못했습니다.")
            }
            isStarting = false
        }
    }

    private func cancelLogin(profile: AccountProfile, login: DeviceCodeLogin) {
        Task {
            await store.cancelAndDiscardDeviceLogin(profile: profile, loginID: login.loginID)
            onClose()
        }
    }
}

struct ReauthenticateAccountView: View {
    @ObservedObject var store: UsageStore
    let profile: AccountProfile
    let onClose: () -> Void
    @State private var login: DeviceCodeLogin?
    @State private var errorText: String?
    @State private var isStarting = false
    @State private var didCopyCode = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "다시 로그인",
                subtitle: profile.alias,
                symbol: "person.badge.key",
                dismiss: login == nil ? onClose : nil
            )
            Divider()

            Group {
                if let login {
                    DeviceLoginPanel(
                        accountName: profile.alias,
                        login: login,
                        didCopyCode: $didCopyCode,
                        cancelTitle: "로그인 취소",
                        cancel: { cancelLogin(login) }
                    )
                } else if isStarting {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("안전한 로그인 준비 중…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(errorText ?? "로그인을 시작하지 못했습니다.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("닫기", role: .cancel, action: onClose)
                            Spacer()
                            Button("다시 시도") { startLogin() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(login != nil)
        .task { startLogin() }
    }

    private func startLogin() {
        guard !isStarting, login == nil else { return }
        isStarting = true
        errorText = nil
        Task {
            do {
                let nextLogin = try await store.beginReauthentication(profile: profile)
                login = nextLogin
                NSWorkspace.shared.open(nextLogin.verificationURL)
                let completed = await store.waitForDeviceLogin(profile: profile, loginID: nextLogin.loginID)
                if completed {
                    onClose()
                } else {
                    login = nil
                    errorText = store.snapshots[profile.id]?.lastError ?? "로그인을 완료하지 못했습니다."
                }
            } catch {
                errorText = localizedMessage(error, fallback: "로그인을 시작하지 못했습니다.")
            }
            isStarting = false
        }
    }

    private func cancelLogin(_ login: DeviceCodeLogin) {
        Task {
            await store.cancelReauthentication(profile: profile, loginID: login.loginID)
            onClose()
        }
    }
}

private struct SheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("닫기")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct DeviceLoginPanel: View {
    let accountName: String
    let login: DeviceCodeLogin
    @Binding var didCopyCode: Bool
    let cancelTitle: String
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 11) {
                StepNumber(value: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("브라우저에서 ChatGPT 로그인")
                        .font(.subheadline.weight(.semibold))
                    Text("사용할 계정이 \(accountName) 계정인지 확인하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 11) {
                StepNumber(value: 2)
                VStack(alignment: .leading, spacing: 9) {
                    Text("아래 코드 입력")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        Text(login.userCode)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .tracking(1.2)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(login.userCode, forType: .string)
                            didCopyCode = true
                        } label: {
                            Label(didCopyCode ? "복사됨" : "복사", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("로그인 완료를 기다리는 중입니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(cancelTitle, role: .cancel, action: cancel)
                Spacer()
                Button {
                    NSWorkspace.shared.open(login.verificationURL)
                } label: {
                    Label("브라우저 다시 열기", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

}

private struct StepNumber: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.accentColor, in: Circle())
            .accessibilityLabel("\(value)단계")
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPage = .accounts
    @State private var deletionCandidate: AccountProfile?
    @State private var presentsAddAccount = false
    @State private var reauthenticationProfile: AccountProfile?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
                .frame(width: 176)

            Divider()

            VStack(spacing: 0) {
                SettingsHeader(page: selection, dismiss: { dismiss() })
                Divider()
                ScrollView {
                    Group {
                        switch selection {
                        case .accounts:
                            AccountsSettingsPage(
                                store: store,
                                deletionCandidate: $deletionCandidate,
                                addAccount: { presentsAddAccount = true },
                                reauthenticate: { reauthenticationProfile = $0 }
                            )
                        case .general:
                            GeneralSettingsPage(store: store)
                        }
                    }
                    .padding(24)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 570)
        .sheet(isPresented: $presentsAddAccount) {
            AddAccountView(store: store, onClose: { presentsAddAccount = false })
        }
        .sheet(item: $reauthenticationProfile) { profile in
            ReauthenticateAccountView(
                store: store,
                profile: profile,
                onClose: { reauthenticationProfile = nil }
            )
        }
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
                Text(profile.isManagedByApp
                    ? "두 번째 옵션은 이 계정의 Codex 인증 파일만 삭제합니다. 외부 프로필은 건드리지 않습니다."
                    : "외부 프로필의 폴더와 인증 파일은 삭제하지 않습니다.")
            }
        }
    }

    private func remove(_ profile: AccountProfile, deleteFiles: Bool) {
        Task {
            do {
                try await store.remove(profile, deleteManagedFiles: deleteFiles)
            } catch {
                store.transientMessage = "계정을 제거하지 못했습니다. \(localizedMessage(error, fallback: ""))"
            }
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case accounts
    case general

    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: "계정"
        case .general: "일반"
        }
    }
    var symbol: String {
        switch self {
        case .accounts: "person.2"
        case .general: "gearshape"
        }
    }
    var subtitle: String {
        switch self {
        case .accounts: "연결된 계정과 대표 계정을 관리합니다."
        case .general: "Codex 실행 파일과 시작 동작을 설정합니다."
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CodexBar")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ForEach(SettingsPage.allCases) { page in
                Button {
                    selection = page
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.symbol)
                            .frame(width: 18)
                        Text(page.title)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline.weight(selection == page ? .semibold : .regular))
                    .foregroundStyle(selection == page ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("CodexBar 0.1.4")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SettingsHeader: View {
    let page: SettingsPage
    let dismiss: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                Text(page.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("완료", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
    }
}

private struct AccountsSettingsPage: View {
    @ObservedObject var store: UsageStore
    @Binding var deletionCandidate: AccountProfile?
    let addAccount: () -> Void
    let reauthenticate: (AccountProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button(action: addAccount) {
                    Label("계정 연결", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    store.addDefaultCodexProfile(alias: "기본 Codex")
                } label: {
                    Label("기본 ~/.codex 사용", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .disabled(hasDefaultProfile)
                .help(hasDefaultProfile ? "기본 ~/.codex 프로필이 이미 등록되어 있습니다" : "기존 Codex CLI 로그인을 연결합니다")
            }

            if store.profiles.isEmpty {
                ContentUnavailableView(
                    "연결된 계정 없음",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("계정을 연결하면 남은 쿼터와 초기화 시각을 확인할 수 있습니다.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 46)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.profiles) { profile in
                        AccountSettingsRow(
                            profile: profile,
                            snapshot: store.snapshots[profile.id],
                            isPrimary: profile.id == store.primaryProfile?.id,
                            isEnabled: Binding(
                                get: { store.profiles.first(where: { $0.id == profile.id })?.isEnabled ?? false },
                                set: { store.setEnabled(profile.id, enabled: $0) }
                            ),
                            rename: { store.rename(profile.id, to: $0) },
                            makePrimary: { store.makePrimary(profile.id) },
                            reauthenticate: { reauthenticate(profile) },
                            remove: { deletionCandidate = profile }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasDefaultProfile: Bool {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL.path
        return store.profiles.contains { !$0.isManagedByApp && $0.codexHomePath.standardizedFileURL.path == defaultPath }
    }
}

private struct AccountSettingsRow: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?
    let isPrimary: Bool
    @Binding var isEnabled: Bool
    let rename: (String) -> Void
    let makePrimary: () -> Void
    let reauthenticate: () -> Void
    let remove: () -> Void
    @State private var draftAlias: String
    @FocusState private var aliasIsFocused: Bool

    init(
        profile: AccountProfile,
        snapshot: AccountUsageSnapshot?,
        isPrimary: Bool,
        isEnabled: Binding<Bool>,
        rename: @escaping (String) -> Void,
        makePrimary: @escaping () -> Void,
        reauthenticate: @escaping () -> Void,
        remove: @escaping () -> Void
    ) {
        self.profile = profile
        self.snapshot = snapshot
        self.isPrimary = isPrimary
        _isEnabled = isEnabled
        self.rename = rename
        self.makePrimary = makePrimary
        self.reauthenticate = reauthenticate
        self.remove = remove
        _draftAlias = State(initialValue: profile.alias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(statusTint(snapshot).opacity(0.13))
                    Image(systemName: statusSymbol(snapshot))
                        .foregroundStyle(statusTint(snapshot))
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        TextField("계정 이름", text: $draftAlias)
                            .textFieldStyle(.plain)
                            .font(.subheadline.weight(.semibold))
                            .focused($aliasIsFocused)
                            .onSubmit(commitAlias)
                        if isPrimary {
                            SettingsPill(text: "대표", tint: .yellow)
                        }
                        SettingsPill(text: profile.isManagedByApp ? "앱 관리" : "외부", tint: .secondary)
                    }

                    if let email = snapshot?.identity.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(snapshot?.lastError ?? statusDetail)
                        .font(.caption)
                        .foregroundStyle(snapshot?.lastError == nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "—")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Toggle("활성", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel("\(profile.alias) 활성화")
                }
            }

            HStack(spacing: 9) {
                if isPrimary {
                    Label("대표 계정", systemImage: "star.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: makePrimary) {
                        Label("대표로 설정", systemImage: "star")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isEnabled)
                }

                if snapshot?.connectionState == .authRequired {
                    Button(action: reauthenticate) {
                        Label("다시 로그인", systemImage: "key")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Spacer()

                Menu {
                    if snapshot?.connectionState != .authRequired {
                        Button(action: reauthenticate) {
                            Label("다시 로그인", systemImage: "person.badge.key")
                        }
                    }
                    Divider()
                    Button(role: .destructive, action: remove) {
                        Label("계정 제거", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("\(profile.alias) 계정 메뉴")
            }
        }
        .padding(15)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(statusTint(snapshot))
                .frame(width: 3)
                .padding(.vertical, 11)
        }
        .onChange(of: aliasIsFocused) { _, isFocused in
            if !isFocused { commitAlias() }
        }
        .onChange(of: profile.alias) { _, newAlias in
            if !aliasIsFocused { draftAlias = newAlias }
        }
    }

    private var statusDetail: String {
        let status = snapshot?.connectionState.displayName ?? "대기 중"
        let fetched = CodexBarFormatters.fetchedText(snapshot?.fetchedAt)
        return "\(status) · 마지막 갱신 \(fetched)"
    }

    private func commitAlias() {
        let clean = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            draftAlias = profile.alias
        } else {
            draftAlias = clean
            rename(clean)
        }
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Codex") {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "terminal", tint: .blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("실행 파일")
                            .font(.subheadline.weight(.medium))
                        Text(store.preferences.customCodexExecutablePath?.path ?? "ChatGPT 앱 또는 PATH에서 자동으로 찾습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    if store.preferences.customCodexExecutablePath != nil {
                        Button("자동 찾기") { store.setCodexExecutablePath(nil) }
                            .buttonStyle(.borderless)
                    }
                    Button("선택…", action: chooseExecutable)
                }
            }

            SettingsGroup(title: "시작") {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "power", tint: .green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("로그인 시 자동 실행")
                            .font(.subheadline.weight(.medium))
                        Text("Mac에 로그인하면 CodexBar를 메뉴바에서 시작합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("로그인 시 CodexBar 실행", isOn: Binding(
                        get: { store.preferences.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("인증 정보는 Mac에만 보관됩니다")
                        .font(.subheadline.weight(.medium))
                    Text("CodexBar는 인증 파일 내용을 읽거나 별도 서버로 전송하지 않습니다. 로그인은 로컬 Codex가 직접 처리합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "codex 실행 파일을 선택하세요"
        if panel.runModal() == .OK {
            store.setCodexExecutablePath(panel.url)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content
                .padding(15)
                .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SettingsPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(tint == .secondary ? 0.10 : 0.20), in: Capsule())
    }
}

private func activeResetSummary(_ snapshot: AccountUsageSnapshot?) -> String {
    guard let window = snapshot?.activeCodexWindow else {
        return snapshot?.connectionState.displayName ?? "사용량을 불러오는 중"
    }
    return "\(quotaWindowTitle(window)) · 초기화 \(CodexBarFormatters.resetText(window.resetsAt))"
}

private func shortResetText(_ date: Date?) -> String {
    guard let date else { return "초기화 미상" }
    let relative = RelativeDateTimeFormatter()
    relative.locale = .current
    return relative.localizedString(for: date, relativeTo: .now)
}

private func accountSecondaryText(profile: AccountProfile, snapshot: AccountUsageSnapshot?) -> String {
    guard profile.isEnabled else { return "갱신 중지됨" }
    if snapshot?.connectionState == .authRequired { return "로그인 필요" }
    if snapshot?.connectionState == .stale { return "오래된 정보" }
    if let reset = snapshot?.activeCodexWindow?.resetsAt {
        return "초기화 \(shortResetText(reset))"
    }
    return snapshot?.connectionState.displayName ?? "사용량 없음"
}

private func remainingAccessibilityText(_ remaining: Int?, window: RateLimitWindow?) -> String {
    if let remaining { return "\(quotaWindowTitle(window)) 잔여 \(remaining)퍼센트" }
    return "Codex 쿼터 정보 없음"
}

private func quotaWindowTitle(_ window: RateLimitWindow?) -> String {
    guard let minutes = window?.windowDurationMinutes, minutes > 0 else { return "사용량 한도" }
    return "\(CodexBarFormatters.windowText(minutes)) 한도"
}

private func usageColor(_ remaining: Int?) -> Color {
    guard let remaining else { return .secondary }
    switch remaining {
    case 0...20: return .red
    case 21...50: return .orange
    default: return .green
    }
}

private func statusTint(_ snapshot: AccountUsageSnapshot?) -> Color {
    switch snapshot?.connectionState {
    case .ready: return .green
    case .authRequired, .error: return .red
    case .stale: return .orange
    case .refreshing, .authenticating, .starting: return .blue
    default: return .secondary
    }
}

private func statusSymbol(_ snapshot: AccountUsageSnapshot?) -> String {
    switch snapshot?.connectionState {
    case .ready: return "checkmark"
    case .authRequired: return "key.slash"
    case .error, .stale: return "exclamationmark"
    case .refreshing: return "arrow.clockwise"
    case .authenticating: return "key"
    case .starting: return "ellipsis"
    default: return "circle"
    }
}

private func localizedMessage(_ error: Error, fallback: String) -> String {
    (error as? LocalizedError)?.errorDescription ?? fallback
}
