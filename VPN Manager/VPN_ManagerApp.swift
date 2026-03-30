//
//  VPN_ManagerApp.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/11/25.
//

import SwiftUI
import AppKit

@main
struct VPN_ManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vpnManager = VPNManager()
    private lazy var interactionController = VPNInteractionController(vpnManager: vpnManager)
    private lazy var statusBarController = VPNStatusBarController(interactionController: interactionController)
    private lazy var shortcutController = VPNShortcutController { [weak self] action in
        self?.statusBarController.performShortcutAction(action)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppLogger.shared.log("Application launched.")
        statusBarController.start()
        shortcutController.start()
    }
}
