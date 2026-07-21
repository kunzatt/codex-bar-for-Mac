import AppKit
import SwiftUI
import Combine

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var statusBarController: StatusBarController?
    private var wakeObserver: NSObjectProtocol?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(store: store)
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
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let compactPopover = NSPopover()
    private let fullPopover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var pointerInButton = false
    private var pointerInCompactPopover = false
    private var globalClickMonitor: Any?

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopovers()
        configureOutsideClickDismissal()
        observeStore()
        updateButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(toggleFullPopover)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex 사용량")
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: ["area": "button"]
        )
        button.addTrackingArea(tracking)
    }

    private func configurePopovers() {
        compactPopover.behavior = .transient
        compactPopover.appearance = NSAppearance(named: .aqua)
        compactPopover.contentViewController = lightHostingController(rootView: CompactHoverView(store: store))
        fullPopover.behavior = .transient
        fullPopover.appearance = NSAppearance(named: .aqua)
        fullPopover.contentViewController = lightHostingController(rootView: UsagePopoverView(store: store))
    }

    private func lightHostingController<Content: View>(rootView: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: rootView)
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        return controller
    }

    /// `NSPopover.transient` should close by itself, but status-item popovers do not always
    /// receive an outside click when another app owns it. These monitors make that behavior explicit.
    private func configureOutsideClickDismissal() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissFullPopoverIfNeeded() }
        }
    }

    private func dismissFullPopoverIfNeeded() {
        guard fullPopover.isShown else { return }
        let point = NSEvent.mouseLocation
        if let popoverWindow = fullPopover.contentViewController?.view.window,
           popoverWindow.frame.contains(point) { return }
        if let button = statusItem.button,
           let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonRect.contains(point) { return }
        }
        fullPopover.performClose(nil)
    }

    private func observeStore() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &subscriptions)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let snapshot = store.primarySnapshot
        let title: String
        let symbol: String
        if snapshot?.connectionState == .authRequired {
            title = "C !"
            symbol = "exclamationmark.triangle"
        } else if let remaining = snapshot?.remainingPercent {
            title = "C \(remaining)%"
            symbol = snapshot?.isStale == true ? "clock.badge.exclamationmark" : "chart.bar.fill"
        } else {
            title = "C --"
            symbol = "chart.bar"
        }
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Codex 사용량")
        button.toolTip = tooltip(for: snapshot)
        button.setAccessibilityLabel("CodexBar \(title)")
        button.setAccessibilityValue(tooltip(for: snapshot))
    }

    private func tooltip(for snapshot: AccountUsageSnapshot?) -> String {
        guard let profile = store.primaryProfile else { return "대표 계정을 추가하세요." }
        guard let snapshot else { return "\(profile.alias): 아직 사용량 정보가 없습니다." }
        let usage = snapshot.remainingPercent.map { "잔여 \($0)%" } ?? "사용량 없음"
        let freshness = CodexBarFormatters.fetchedText(snapshot.fetchedAt)
        return "\(profile.alias): \(usage), \(freshness)"
    }

    @objc private func toggleFullPopover() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        if fullPopover.isShown {
            fullPopover.performClose(nil)
        } else {
            compactPopover.performClose(nil)
            show(fullPopover)
        }
    }

    @objc func mouseEntered(with event: NSEvent) {
        let area = event.trackingArea?.userInfo?["area"] as? String
        if area == "compact" {
            pointerInCompactPopover = true
            hoverCloseTask?.cancel()
            return
        }
        pointerInButton = true
        hoverCloseTask?.cancel()
        guard !fullPopover.isShown else { return }
        hoverOpenTask?.cancel()
        hoverOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard let self, !Task.isCancelled, self.pointerInButton, !self.fullPopover.isShown else { return }
            self.show(self.compactPopover)
            self.trackCompactPopover()
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        let area = event.trackingArea?.userInfo?["area"] as? String
        if area == "compact" { pointerInCompactPopover = false }
        else { pointerInButton = false }
        scheduleCompactClose()
    }

    private func show(_ popover: NSPopover) {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func trackCompactPopover() {
        guard let view = compactPopover.contentViewController?.view else { return }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: ["area": "compact"]
        )
        view.addTrackingArea(tracking)
    }

    private func scheduleCompactClose() {
        guard !fullPopover.isShown else { return }
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        hoverCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.pointerInButton, !self.pointerInCompactPopover else { return }
            self.compactPopover.performClose(nil)
        }
    }
}
