import AppKit
import SwiftUI

/// Device-code authentication must not be hosted by MenuBarExtra. Menu-bar windows are
/// intentionally transient and close as soon as AppKit changes first responder or focus.
@MainActor
final class AccountFlowWindowController: NSObject, NSWindowDelegate {
    private let store: UsageStore
    private var window: NSWindow?

    init(store: UsageStore) {
        self.store = store
    }

    func showAddAccount() {
        guard window == nil else {
            bringWindowForward()
            return
        }
        show(
            title: "CodexBar 계정 연결",
            rootView: AnyView(
                AddAccountView(store: store, onClose: { [weak self] in
                    self?.close()
                })
            )
        )
    }

    func showReauthentication(for profile: AccountProfile) {
        guard window == nil else {
            bringWindowForward()
            return
        }
        show(
            title: "CodexBar 다시 로그인",
            rootView: AnyView(
                ReauthenticateAccountView(store: store, profile: profile, onClose: { [weak self] in
                    self?.close()
                })
            )
        )
    }

    private func show(title: String, rootView: AnyView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        window.delegate = self
        window.center()
        self.window = window
        bringWindowForward()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func close() {
        window?.close()
    }

    private func bringWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
