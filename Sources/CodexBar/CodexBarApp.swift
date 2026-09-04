import AppKit
import CoreImage
import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(
                store: appDelegate.store,
                addAccount: { appDelegate.showAddAccount() },
                reauthenticate: { appDelegate.showReauthentication(for: $0) }
            )
        } label: {
            CodexBarMenuLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private lazy var accountFlowWindow = AccountFlowWindowController(store: store)
    private var wakeObserver: NSObjectProtocol?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.store.refreshAll(includeUsage: true) }
        }
        store.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func showAddAccount() {
        accountFlowWindow.showAddAccount()
    }

    func showReauthentication(for profile: AccountProfile) {
        accountFlowWindow.showReauthentication(for: profile)
    }
}

private struct CodexBarMenuLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 0) {
            CodexMenuGlyph()
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .monospacedDigit()
        }
        .fixedSize()
        .help(tooltip)
        .accessibilityLabel("CodexBar \(title)")
        .accessibilityValue(tooltip)
    }

    private var title: String {
        let snapshot = store.primarySnapshot
        if let remaining = snapshot?.remainingPercent {
            return "\(remaining)%"
        }
        if snapshot?.connectionState == .authRequired { return "!" }
        return "--"
    }

    private var tooltip: String {
        guard let profile = store.primaryProfile else { return "대표 계정을 추가하세요." }
        guard let snapshot = store.primarySnapshot else {
            return "\(profile.alias): 아직 사용량 정보가 없습니다."
        }
        if snapshot.connectionState == .authRequired {
            return "\(profile.alias): 로그인이 필요합니다."
        }
        let usage = snapshot.primaryCodexBucket?.windows
            .sorted { lhs, rhs in
                (lhs.windowDurationMinutes ?? .max) < (rhs.windowDurationMinutes ?? .max)
            }
            .map { "\(CodexBarFormatters.windowText($0.windowDurationMinutes)) \($0.remainingPercent)% 남음" }
            .joined(separator: " · ") ?? "사용량 없음"
        return "\(profile.alias): \(usage), \(CodexBarFormatters.fetchedText(snapshot.fetchedAt))"
    }

}

/// The OpenAI Blossom rendered from vector data as a monochrome menu-bar template.
private struct CodexMenuGlyph: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 17.5, height: 15)
        .accessibilityHidden(true)
    }

    private static let templateImage: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 23.333333 20">
          <path fill="#000" d="M11.248 18.25q-.825 0-1.568-.314a4.3 4.3 0 0 1-1.32-.874 4 4 0 0 1-1.304.214 4 4 0 0 1-2.046-.544 4.27 4.27 0 0 1-1.518-1.485 4 4 0 0 1-.56-2.095q0-.48.131-1.04A4.4 4.4 0 0 1 2.04 10.71a4.07 4.07 0 0 1 .017-3.4 4.2 4.2 0 0 1 1.056-1.418 3.8 3.8 0 0 1 1.6-.842 3.9 3.9 0 0 1 .76-1.683q.593-.759 1.451-1.188a4.04 4.04 0 0 1 1.832-.429q.825 0 1.567.313.742.314 1.32.875a4 4 0 0 1 1.304-.215q1.106 0 2.046.545a4.14 4.14 0 0 1 1.501 1.485q.578.941.578 2.095 0 .48-.132 1.04.66.61 1.023 1.419.363.792.363 1.666 0 .892-.38 1.717a4.3 4.3 0 0 1-1.072 1.435 3.8 3.8 0 0 1-1.584.825 3.8 3.8 0 0 1-.775 1.683 4.06 4.06 0 0 1-1.436 1.188 4.04 4.04 0 0 1-1.832.429m-4.076-2.062q.825 0 1.435-.347l3.103-1.782a.36.36 0 0 0 .164-.313v-1.42L7.881 14.62a.67.67 0 0 1-.726 0l-3.118-1.798a.5.5 0 0 1-.017.115v.198q0 .841.396 1.551.413.693 1.139 1.089a3.2 3.2 0 0 0 1.617.412m.165-2.69a.4.4 0 0 0 .181.05q.083 0 .165-.05l1.238-.71-3.977-2.31a.7.7 0 0 1-.363-.643v-3.58q-.825.362-1.32 1.122a2.9 2.9 0 0 0-.495 1.65q0 .809.413 1.55.412.743 1.072 1.123zm3.91 3.663q.875 0 1.585-.396a2.96 2.96 0 0 0 1.534-2.64v-3.564a.32.32 0 0 0-.165-.297l-1.254-.726v4.604a.7.7 0 0 1-.363.643l-3.119 1.799a3 3 0 0 0 1.783.577m.627-6.039V8.878L10.01 7.822 8.129 8.878v2.244l1.881 1.056zM7.057 5.859a.7.7 0 0 1 .363-.644l3.119-1.798a3 3 0 0 0-1.782-.578q-.874 0-1.584.396A2.96 2.96 0 0 0 6.05 4.324a3.07 3.07 0 0 0-.396 1.551v3.547q0 .199.165.314l1.237.726zm8.383 7.887q.825-.364 1.303-1.123.495-.758.495-1.65a3.15 3.15 0 0 0-.412-1.55q-.413-.743-1.073-1.123l-3.086-1.782q-.099-.065-.181-.049a.3.3 0 0 0-.165.05l-1.238.692 3.993 2.327a.6.6 0 0 1 .264.264.64.64 0 0 1 .1.363zm-3.317-8.382a.63.63 0 0 1 .726 0l3.135 1.831v-.297q0-.792-.396-1.501a2.86 2.86 0 0 0-1.105-1.155q-.71-.43-1.65-.43-.825 0-1.436.347L8.294 5.941a.36.36 0 0 0-.165.314v1.418z"/>
        </svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else {
            return legacyTemplateImage
        }
        image.size = NSSize(width: 17.5, height: 15)
        image.isTemplate = true
        return image
    }()

    private static let legacyTemplateImage: NSImage = {
        let encoded = "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"
        guard let data = Data(base64Encoded: encoded),
              let source = CIImage(data: data) else {
            return NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil) ?? NSImage()
        }

        // Crop to the knot itself. The source screenshot has a wide dark tile around it;
        // keeping that tile made the visible mark undersized and visually crowded the text.
        let crop = source.cropped(to: CGRect(x: 14, y: 13, width: 32, height: 32))
        let monochrome = crop.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0
        ])
        let threshold = monochrome.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": 0.27
        ])
        let strengthened = threshold.applyingFilter("CIMorphologyMaximum", parameters: [
            "inputRadius": 0.6
        ])
        let alpha = strengthened.applyingFilter("CIMaskToAlpha")
        let context = CIContext(options: [.useSoftwareRenderer: false])
        // Bake the gap into the bitmap. MenuBarExtra can collapse SwiftUI padding in
        // its label, but it cannot discard transparent pixels inside the image itself.
        let paddedExtent = CGRect(
            x: alpha.extent.minX,
            y: alpha.extent.minY,
            width: alpha.extent.width * (17.5 / 15.0),
            height: alpha.extent.height
        )
        guard let cgImage = context.createCGImage(alpha, from: paddedExtent) else {
            return NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil) ?? NSImage()
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: 17.5, height: 15))
        image.isTemplate = true
        return image
    }()
}
