//
//  VPNStatusBarController.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 3/30/26.
//

import AppKit
import SwiftUI

final class VPNStatusBarController: NSObject, NSMenuDelegate {
    private let interactionController: VPNInteractionController
    private var statusBarItem: NSStatusItem?
    private var vpnMenuItems: [NSMenuItem] = []
    private var vpnControlViews: [VPNControlView] = []
    private var shortcutsWindow: NSWindow?

    private var currentVPNStatus: VPNManager.VPNConnectionStatus = .disconnected {
        didSet {
            if oldValue != currentVPNStatus {
                AppLogger.shared.log("VPN status changed from \(statusDescription(oldValue)) to \(statusDescription(currentVPNStatus))")
            }
            updateStatusBarIcon()
        }
    }

    init(interactionController: VPNInteractionController) {
        self.interactionController = interactionController
        super.init()
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBarItem = item

        updateStatusBarIcon()

        if let button = item.button {
            button.action = #selector(statusBarButtonClicked)
        }

        item.menu = buildMenu()
    }

    func performShortcutAction(_ action: ShortcutAction) {
        switch action {
        case .toggleCurrentVPN:
            interactionController.toggleCurrentVPN { [weak self] result in
                guard let self = self else { return }
                self.handleInteractionResult(result)
                self.refreshMenuUI()
            }
        }
    }
}

extension VPNStatusBarController {
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "VPN Manager", action: nil, keyEquivalent: ""))

        let shortcutsMenuItem = NSMenuItem(title: "Shortcuts", action: #selector(showShortcuts), keyEquivalent: "")
        shortcutsMenuItem.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Shortcuts")
        menu.addItem(shortcutsMenuItem)

        menu.addItem(NSMenuItem.separator())
        loadVPNConfigurations(menu: menu)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Network Preferences...", action: #selector(openNetworkPreferences), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VPN Manager", action: #selector(quitApp), keyEquivalent: "q"))

        return menu
    }

    func updateStatusBarIcon() {
        guard let button = statusBarItem?.button else { return }

        if currentVPNStatus == .connected {
            applySymbolImage(
                to: button,
                symbolName: "network",
                description: "VPN Manager (Connected)",
                paletteColors: [NSColor.systemGreen]
            )
        } else {
            applySymbolImage(
                to: button,
                symbolName: "network",
                description: "VPN Manager (Disconnected)",
                paletteColors: nil
            )
        }
    }

    func applySymbolImage(
        to button: NSStatusBarButton,
        symbolName: String,
        description: String,
        paletteColors: [NSColor]?
    ) {
        guard var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) else {
            return
        }

        if let paletteColors = paletteColors {
            if let configured = image.withSymbolConfiguration(.init(paletteColors: paletteColors)) {
                image = configured
            }
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }

        button.image = image
        button.contentTintColor = paletteColors?.first
    }

    @objc func showShortcuts() {
        if shortcutsWindow == nil {
            let contentView = ShortcutsView(
                onAction: { [weak self] action in
                    self?.performShortcutAction(action)
                },
                onClose: { [weak self] in
                    self?.shortcutsWindow?.close()
                }
            )
            let controller = NSHostingController(rootView: contentView)

            let window = NSWindow(
                contentRect: NSMakeRect(0, 0, 300, 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Shortcuts"
            window.isReleasedWhenClosed = false
            window.contentViewController = controller

            shortcutsWindow = window
        }

        shortcutsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func statusBarButtonClicked() {
        refreshMenuUI()
    }

    func menuWillOpen(_ menu: NSMenu) {
        AppLogger.shared.log("Menu will open, reloading VPN configurations")
        guard menu == statusBarItem?.menu else {
            AppLogger.shared.log("Menu is not the status bar menu, skipping reload")
            return
        }
        loadVPNConfigurations(menu: menu)
    }

    @objc func openNetworkPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.network")!)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func presentInformationalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func presentVPNError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    func handleInteractionResult(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            AppLogger.shared.log("VPN interaction failed: \(error.localizedDescription)")
            presentVPNError(title: "VPN Error", error: error)
        }
    }

    func loadVPNConfigurations(menu: NSMenu) {
        AppLogger.shared.log("Requesting VPN configurations...")
        interactionController.loadVPNs { [weak self] vpnServices in
            guard let self = self else { return }
            AppLogger.shared.log("Received \(vpnServices.count) VPN configurations.")

            let servicesSnapshot = vpnServices
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let servicesWithStatus = servicesSnapshot.map { service in
                    (service, self.interactionController.connectionStatus(for: service))
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.applyVPNConfigurations(servicesWithStatus: servicesWithStatus, menu: menu)
                }
            }
        }
    }

    func applyVPNConfigurations(servicesWithStatus: [(SystemVPNService, VPNManager.VPNConnectionStatus)], menu: NSMenu) {
        AppLogger.shared.log("Applying VPN configurations, count: \(servicesWithStatus.count)")
        let observedState = interactionController.observe(servicesWithStatus: servicesWithStatus)

        for item in vpnMenuItems {
            menu.removeItem(item)
        }
        vpnMenuItems.removeAll()
        vpnControlViews.removeAll()

        if observedState.availableServices.isEmpty {
            AppLogger.shared.log("No VPN configurations found")
            let noVPNItem = NSMenuItem(title: "No VPN Configurations", action: nil, keyEquivalent: "")
            noVPNItem.isEnabled = false
            menu.insertItem(noVPNItem, at: menu.items.count - 5)
            vpnMenuItems.append(noVPNItem)
            currentVPNStatus = observedState.overallStatus
            return
        }

        for service in observedState.availableServices {
            AppLogger.shared.log("Rendering VPN service: \(service.name) (ID: \(service.id))")
            let vpnControlView = VPNControlView(
                vpnService: service,
                interactionController: interactionController,
                statusChangedHandler: { [weak self] in
                    self?.refreshMenuUI()
                },
                errorPresenter: { [weak self] title, error in
                    self?.presentVPNError(title: title, error: error)
                }
            )

            let vpnItem = NSMenuItem()
            vpnItem.view = vpnControlView
            vpnItem.toolTip = service.name
            menu.insertItem(vpnItem, at: menu.items.count - 5)
            vpnMenuItems.append(vpnItem)
            vpnControlViews.append(vpnControlView)

            let separator = NSMenuItem.separator()
            menu.insertItem(separator, at: menu.items.count - 5)
            vpnMenuItems.append(separator)
        }

        currentVPNStatus = observedState.overallStatus
        AppLogger.shared.log("Post-refresh status: \(statusDescription(observedState.overallStatus)), connected service: \(observedState.connectedService?.name ?? "none")")
    }

    func refreshMenuUI() {
        guard let menu = statusBarItem?.menu else { return }
        loadVPNConfigurations(menu: menu)
    }

    func statusDescription(_ status: VPNManager.VPNConnectionStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .unknown: return "unknown"
        }
    }
}
