import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store = UsageStore()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTimer: Timer?
    private var costRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()

        store.$statusSummary
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                self?.applyStatus(summary)
            }
            .store(in: &cancellables)

        store.refresh(cached: true)
        store.refresh(cached: false)
        store.refreshCostHistory()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.store.refresh(cached: false)
        }
        costRefreshTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.store.refreshCostHistory()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        costRefreshTimer?.invalidate()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        button.setButtonType(.momentaryChange)
        applyStatus(store.statusSummary)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 440, height: 720)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(
                store: store,
                onHide: { [weak self] in self?.popover.performClose(nil) },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    private func applyStatus(_ summary: StatusSummary) {
        guard let button = statusItem.button else { return }
        button.title = summary.title
        button.toolTip = summary.tooltip
        button.image = nil
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        store.refresh(cached: true)
        store.refresh(cached: false)
        store.refreshCostHistory()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
