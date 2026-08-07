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
    // A single popover owns both hover and click presentation. Keeping two AppKit popover
    // windows alive at the same anchor can leave the compact window above the full view and
    // swallow every click during a rapid hover-to-click transition.
    private let usagePopover = NSPopover()
    private let popoverPresentation = PopoverPresentation()
    private var subscriptions = Set<AnyCancellable>()
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var pointerInButton = false
    private var pointerInCompactPopover = false
    private var compactTrackingArea: NSTrackingArea?
    private var globalClickMonitor: Any?
    private var popoverShownAt: TimeInterval = 0

    init(store: UsageStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopover()
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

    private func configurePopover() {
        // Native transient behavior owns all clicks inside this app's popover. A separate
        // global monitor only supplements it for clicks delivered to other apps or the desktop.
        usagePopover.behavior = .transient
        usagePopover.appearance = NSAppearance(named: .aqua)
        usagePopover.delegate = self
        usagePopover.contentViewController = lightHostingController(
            rootView: StatusPopoverContent(store: store, presentation: popoverPresentation)
        )
    }

    private func lightHostingController<Content: View>(rootView: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: rootView)
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
        return controller
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
        if snapshot.connectionState == .authRequired {
            return "\(profile.alias): 로그인이 필요합니다. 팝오버에서 다시 로그인하세요."
        }
        let usage = snapshot.remainingPercent.map { "잔여 \($0)%" } ?? "사용량 없음"
        let freshness = CodexBarFormatters.fetchedText(snapshot.fetchedAt)
        return "\(profile.alias): \(usage), \(freshness)"
    }

    @objc private func toggleFullPopover() {
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        if usagePopover.isShown {
            if popoverPresentation.mode == .compact {
                pointerInCompactPopover = false
                popoverPresentation.mode = .full
                activateUsagePopover()
            } else {
                closeUsagePopover()
            }
        } else {
            pointerInCompactPopover = false
            popoverPresentation.mode = .full
            showUsagePopover(activating: true)
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
        guard !usagePopover.isShown else { return }
        hoverOpenTask?.cancel()
        hoverOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard let self, !Task.isCancelled, self.pointerInButton, !self.usagePopover.isShown else { return }
            self.popoverPresentation.mode = .compact
            self.showUsagePopover(activating: false)
            self.trackCompactPopover()
        }
    }

    @objc func mouseExited(with event: NSEvent) {
        let area = event.trackingArea?.userInfo?["area"] as? String
        if area == "compact" { pointerInCompactPopover = false }
        else { pointerInButton = false }
        scheduleCompactClose()
    }

    private func showUsagePopover(activating: Bool) {
        guard let button = statusItem.button else { return }
        if activating { NSApp.activate(ignoringOtherApps: true) }
        usagePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverShownAt = ProcessInfo.processInfo.systemUptime
        installOutsideClickMonitor()
        if activating { activateUsagePopover() }
    }

    /// A status-item click does not always make an accessory app's popover key. Without this,
    /// the first click inside the just-opened view can be consumed only to activate it.
    private func activateUsagePopover() {
        NSApp.activate(ignoringOtherApps: true)
        usagePopover.contentViewController?.view.window?.makeKey()
    }

    private func closeUsagePopover() {
        guard usagePopover.isShown else { return }
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        // `close()` cannot be vetoed by a nested presentation, so it never leaves an
        // invisible popover window above the interactive SwiftUI content.
        usagePopover.close()
    }

    private func installOutsideClickMonitor() {
        guard globalClickMonitor == nil else { return }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            // Global events are asynchronous. Capture the point and timestamp at delivery so a
            // click that happened before this popover was shown cannot close a later one.
            let clickPoint = NSEvent.mouseLocation
            let eventTimestamp = event.timestamp
            MainActor.assumeIsolated {
                self?.closeUsagePopoverIfClickedOutside(at: clickPoint, eventTimestamp: eventTimestamp)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func closeUsagePopoverIfClickedOutside(at point: NSPoint, eventTimestamp: TimeInterval) {
        guard usagePopover.isShown, eventTimestamp >= popoverShownAt, !popoverWindowContains(point) else { return }
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonFrame.contains(point) { return }
        }
        closeUsagePopover()
    }

    private func popoverWindowContains(_ point: NSPoint) -> Bool {
        guard let popoverWindow = usagePopover.contentViewController?.view.window else { return false }
        return windowTree(popoverWindow, contains: point)
    }

    private func windowTree(_ window: NSWindow, contains point: NSPoint) -> Bool {
        if window.frame.contains(point) { return true }
        return window.childWindows?.contains { windowTree($0, contains: point) } ?? false
    }

    private func trackCompactPopover() {
        guard let view = usagePopover.contentViewController?.view else { return }
        if let compactTrackingArea { view.removeTrackingArea(compactTrackingArea) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: ["area": "compact"]
        )
        view.addTrackingArea(tracking)
        compactTrackingArea = tracking
    }

    private func scheduleCompactClose() {
        guard popoverPresentation.mode == .compact else { return }
        hoverOpenTask?.cancel()
        hoverCloseTask?.cancel()
        hoverCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.pointerInButton, !self.pointerInCompactPopover else { return }
            self.closeUsagePopover()
            self.pointerInCompactPopover = false
        }
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        popoverShownAt = 0
        pointerInCompactPopover = false
    }
}

@MainActor
private final class PopoverPresentation: ObservableObject {
    enum Mode {
        case compact
        case full
    }

    @Published var mode: Mode = .compact
}

private struct StatusPopoverContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var presentation: PopoverPresentation

    var body: some View {
        switch presentation.mode {
        case .compact:
            CompactHoverView(store: store)
        case .full:
            UsagePopoverView(store: store)
        }
    }
}
