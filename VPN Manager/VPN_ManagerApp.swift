//
//  VPN_ManagerApp.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/11/25.
//

import SwiftUI
import AppKit
import SystemConfiguration
import Foundation
import Carbon

@main
struct VPN_ManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class VPNManager: NSObject {
    enum VPNConnectionStatus {
        case connected
        case connecting
        case disconnecting
        case disconnected
        case unknown
    }

    private let appVPNInterfaceType = "VPN" // kSCNetworkInterfaceTypeVPN lacks a Swift symbol on macOS

    private lazy var vpnInterfaceTypes: Set<String> = [
        kSCNetworkInterfaceTypePPP as String,
        kSCNetworkInterfaceTypeIPSec as String,
        kSCNetworkInterfaceTypeL2TP as String,
        appVPNInterfaceType
    ]

    func loadVPNs(completion: @escaping ([SystemVPNService]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let services = self.fetchSystemVPNServices()
            DispatchQueue.main.async {
                completion(services)
            }
        }
    }

    func connectVPN(_ service: SystemVPNService, completion: ((Error?) -> Void)? = nil) {
        AppLogger.shared.log("Attempting to connect VPN: \(service.name) (ID: \(service.id))")
        runScutilCommand(arguments: ["--nc", "start", service.name]) { error in
            if let error = error {
                AppLogger.shared.log("Failed to connect VPN \(service.name): \(error.localizedDescription)")
            } else {
                AppLogger.shared.log("Successfully initiated connection for VPN: \(service.name)")
            }
            completion?(error)
        }
    }

    func disconnectVPN(_ service: SystemVPNService, completion: ((Error?) -> Void)? = nil) {
        AppLogger.shared.log("Attempting to disconnect VPN: \(service.name) (ID: \(service.id))")
        runScutilCommand(arguments: ["--nc", "stop", service.name]) { error in
            if let error = error {
                AppLogger.shared.log("Failed to disconnect VPN \(service.name): \(error.localizedDescription)")
            } else {
                AppLogger.shared.log("Successfully initiated disconnection for VPN: \(service.name)")
            }
            completion?(error)
        }
    }

    func connectionStatus(for service: SystemVPNService) -> VPNConnectionStatus {
        return vpnStatus(for: service)
    }
    
    func getVPNStatusText(_ service: SystemVPNService) -> String {
        switch connectionStatus(for: service) {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnecting:
            return "Disconnecting..."
        case .disconnected:
            return "Not Connected"
        case .unknown:
            return "Unknown"
        }
    }

    private func fetchSystemVPNServices() -> [SystemVPNService] {
        AppLogger.shared.log("Starting to fetch system VPN services")
        guard
            let preferences = SCPreferencesCreate(nil, "VPN Manager" as CFString, nil),
            let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
        else {
            AppLogger.shared.log("Failed to fetch system VPN services - could not create preferences or services")
            return []
        }

        let result = services.compactMap { service -> SystemVPNService? in
            guard
                let interface = SCNetworkServiceGetInterface(service),
                self.isVPNInterface(interface)
            else {
                return nil
            }

            let name = SCNetworkServiceGetName(service) as String? ?? "VPN"
            let serviceID = SCNetworkServiceGetServiceID(service) as String? ?? UUID().uuidString
            let description = self.interfaceDisplayName(for: interface)
            let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?

            AppLogger.shared.log("Found VPN service: \(name) (ID: \(serviceID)), interface: \(description), BSD name: \(bsdName ?? "N/A")")
            
            return SystemVPNService(
                id: serviceID,
                name: name,
                interfaceDescription: description,
                interfaceBSDName: bsdName
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        AppLogger.shared.log("Finished fetching system VPN services, found \(result.count) VPN services")
        return result
    }

    private func isVPNInterface(_ interface: SCNetworkInterface) -> Bool {
        var currentInterface: SCNetworkInterface? = interface

        while let candidate = currentInterface {
            if
                let type = SCNetworkInterfaceGetInterfaceType(candidate) as String?,
                vpnInterfaceTypes.contains(type)
            {
                return true
            }

            currentInterface = SCNetworkInterfaceGetInterface(candidate)
        }

        return false
    }

    private func interfaceDisplayName(for interface: SCNetworkInterface) -> String {
        if let localized = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?, !localized.isEmpty {
            return localized
        }

        if let type = SCNetworkInterfaceGetInterfaceType(interface) as String?, !type.isEmpty {
            return type == appVPNInterfaceType ? "App VPN" : type
        }

        return "VPN"
    }

    private func runScutilCommand(arguments: [String], completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            AppLogger.shared.log("Executing scutil command: \(arguments.joined(separator: " "))")
            do {
                let output = try self.executeScutil(arguments: arguments)
                AppLogger.shared.log("Scutil command completed successfully: \(arguments.joined(separator: " ")), output: \(output.prefix(200))...")
                DispatchQueue.main.async {
                    completion(nil)
                }
            } catch {
                AppLogger.shared.log("Scutil command failed: \(arguments.joined(separator: " ")), error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(error)
                }
            }
        }
    }

    private func executeScutil(arguments: [String]) throws -> String {
        let process = Process()
        process.launchPath = "/usr/sbin/scutil"
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        AppLogger.shared.log("Starting scutil process with arguments: \(arguments)")
        try process.run()
        process.waitUntilExit()
        AppLogger.shared.log("Scutil process terminated with status: \(process.terminationStatus)")

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            AppLogger.shared.log("Scutil command failed with termination status \(process.terminationStatus), output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            throw NSError(
                domain: "VPNManager",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }

        AppLogger.shared.log("Scutil command succeeded, output length: \(output.count) characters")
        return output
    }

    private func vpnStatus(for service: SystemVPNService) -> VPNConnectionStatus {
        AppLogger.shared.log("Checking status for VPN: \(service.name)")
        do {
            let output = try executeScutil(arguments: ["--nc", "status", service.name])
            guard let firstLine = output.components(separatedBy: .newlines).first else {
                AppLogger.shared.log("Could not get status from output for VPN: \(service.name)")
                return .unknown
            }

            let status = firstLine.lowercased()
            AppLogger.shared.log("Got status for VPN \(service.name): \(status)")
            
            switch status {
            case "connected":
                return .connected
            case "connecting":
                return .connecting
            case "disconnecting":
                return .disconnecting
            case "disconnected":
                return .disconnected
            default:
                return .unknown
            }
        } catch {
            AppLogger.shared.log("Error checking status for VPN \(service.name): \(error.localizedDescription)")
            return .unknown
        }
    }

    func waitForStatus(for service: SystemVPNService,
                       desiredStatus: VPNConnectionStatus,
                       timeout: TimeInterval = 15,
                       pollInterval: TimeInterval = 0.5,
                       completion: @escaping (VPNConnectionStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            var currentStatus = self.connectionStatus(for: service)

            while Date() < deadline && currentStatus != desiredStatus {
                Thread.sleep(forTimeInterval: pollInterval)
                currentStatus = self.connectionStatus(for: service)
            }

            DispatchQueue.main.async {
                completion(currentStatus)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, VPNControlDelegate {
    private var statusBarItem: NSStatusItem?
    private var splittingTunnelMenuItem: NSMenuItem?
    private var isSplittingTunnelEnabled = false
    private let vpnManager = VPNManager()
    private let splittingTunnelManager: SplittingTunnelManager = {
        let manager = SplittingTunnelManager()
        manager.onError = { title, message in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        return manager
    }()
    private var connectedVPNService: SystemVPNService?
    private var preferredVPNService: SystemVPNService?
    private var splittingTunnelOperationInProgress = false
    private var vpnMenuItems: [NSMenuItem] = []
    private var vpnStatusItems: [NSMenuItem] = []
    private var vpnControlViews: [VPNControlView] = []
    private var availableVPNServices: [SystemVPNService] = []
    private var shortcutsWindow: NSWindow?
    
    private enum ShortcutHotKey: UInt32 {
        case toggleCurrentVPN = 1
    }
    
    private let shortcutHotKeySignature: OSType = 0x56504E4D // 'VPNM'
    private var hotKeyEventHandler: EventHandlerRef?
    private var registeredHotKeys: [ShortcutHotKey: EventHotKeyRef?] = [:]
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        unregisterHotKeys()
    }
    
    // MARK: - VPNControlDelegate
    func setConnectedVPNService(_ service: SystemVPNService?) {
        connectedVPNService = service
        if let service = service {
            preferredVPNService = service
        }
        // 更新状态栏图标
        currentVPNStatus = service != nil ? .connected : .disconnected
    }
    
    func getConnectedVPNService() -> SystemVPNService? {
        return connectedVPNService
    }
    
    private var currentVPNStatus: VPNManager.VPNConnectionStatus = .disconnected {
        didSet {
            if oldValue != currentVPNStatus {
                AppLogger.shared.log("VPN status changed from \(statusDescription(oldValue)) to \(statusDescription(currentVPNStatus))")
            }
            updateStatusBarIcon()
        }
    }
    
    private func updateStatusBarIcon() {
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

    private func applySymbolImage(
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
        button.contentTintColor = paletteColors == nil ? nil : paletteColors!.first
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory (menu bar only) so the Dock icon is hidden
        NSApplication.shared.setActivationPolicy(.accessory)
        AppLogger.shared.log("Application launched. Splitting tunnel enabled: \(isSplittingTunnelEnabled)")

        // 创建菜单栏图标
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // 初始化图标状态
        updateStatusBarIcon()
        
        if let button = statusBarItem?.button {
            button.action = #selector(statusBarButtonClicked)
        }
        
        // 创建菜单
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "VPN Manager", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // 添加Splitting Tunnel选项
        splittingTunnelMenuItem = NSMenuItem(title: "Splitting Tunnel", action: #selector(toggleSplittingTunnel), keyEquivalent: "")
        splittingTunnelMenuItem?.state = isSplittingTunnelEnabled ? .on : .off
        menu.addItem(splittingTunnelMenuItem!)
        
        // 添加快捷方式菜单项
        let shortcutsMenuItem = NSMenuItem(title: "Shortcuts", action: #selector(showShortcuts), keyEquivalent: "")
        shortcutsMenuItem.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Shortcuts")
        menu.addItem(shortcutsMenuItem)
        
        // 添加VPN列表分隔符
        menu.addItem(NSMenuItem.separator())
        
        // 加载VPN配置
        loadVPNConfigurations(menu: menu)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Network Preferences...", action: #selector(openNetworkPreferences), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VPN Manager", action: #selector(quitApp), keyEquivalent: "q"))

        statusBarItem?.menu = menu
        
        setupShortcutIntegration()
    }
    
    @objc func showShortcuts() {
        // 创建快捷方式面板窗口
        if shortcutsWindow == nil {
            let contentView = ShortcutsView()
            let controller = NSHostingController(rootView: contentView)
            
            let window = NSWindow(
                contentRect: NSMakeRect(0, 0, 300, 400),
                styleMask: [.titled, .closable, .resizable],
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
    
    private func setupShortcutIntegration() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutNotification(_:)),
            name: .shortcutActionRequested,
            object: nil
        )
        registerDefaultHotkeysIfPossible()
    }
    
    private func registerDefaultHotkeysIfPossible() {
        installHotKeyHandlerIfNeeded()
        let status = registerHotKey(identifier: .toggleCurrentVPN,
                                    keyCode: UInt32(kVK_ANSI_A),
                                    modifiers: UInt32(controlKey))
        if status == noErr {
            AppLogger.shared.log("Registered Control + A shortcut for toggling current VPN.")
        } else if status == eventHotKeyExistsErr {
            AppLogger.shared.log("Control + A shortcut registration skipped because the combination is already used by another application.")
        } else {
            AppLogger.shared.log("Failed to register Control + A shortcut. OSStatus=\(status)")
        }
    }
    
    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyEventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData = userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            return delegate.handleHotKey(eventRef: eventRef)
        }
        
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyEventHandler
        )
    }
    
    @discardableResult
    private func registerHotKey(identifier: ShortcutHotKey,
                                keyCode: UInt32,
                                modifiers: UInt32) -> OSStatus {
        var hotKeyRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID(signature: shortcutHotKeySignature, id: identifier.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr {
            registeredHotKeys[identifier] = hotKeyRef
        }
        
        return status
    }
    
    private func unregisterHotKeys() {
        for (_, hotKeyRef) in registeredHotKeys {
            if let hotKeyRef = hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        registeredHotKeys.removeAll()
    }
    
    @objc private func handleShortcutNotification(_ notification: Notification) {
        guard
            let rawValue = notification.userInfo?["action"] as? String,
            let action = ShortcutAction(rawValue: rawValue)
        else {
            return
        }
        performShortcutAction(action)
    }
    
    private func performShortcutAction(_ action: ShortcutAction, preferredService: SystemVPNService? = nil) {
        switch action {
        case .connectCurrentVPN:
            guard let target = resolveServiceForShortcutConnection(preferredService: preferredService) else {
                AppLogger.shared.log("Connect shortcut ignored because no VPN service is available.")
                presentInformationalAlert(title: "没有可用的VPN", message: "无法触发连接操作，因为当前没有发现任何VPN配置。")
                return
            }
            AppLogger.shared.log("Shortcut connect request for VPN: \(target.name)")
            connectServiceViaShortcut(target)
        case .disconnectCurrentVPN:
            guard let target = resolveServiceForShortcutDisconnection(preferredService: preferredService) else {
                AppLogger.shared.log("Disconnect shortcut ignored because no VPN connection is active.")
                presentInformationalAlert(title: "没有正在连接的VPN", message: "当前没有需要断开的VPN连接。")
                return
            }
            AppLogger.shared.log("Shortcut disconnect request for VPN: \(target.name)")
            disconnectServiceViaShortcut(target)
        }
    }
    
    private func resolveServiceForShortcutConnection(preferredService: SystemVPNService?) -> SystemVPNService? {
        if let preferredService = preferredService {
            return preferredService
        }
        if let connected = connectedVPNService {
            let status = vpnManager.connectionStatus(for: connected)
            if status == .disconnected || status == .unknown {
                return connected
            }
        }
        if let lastPreferred = preferredVPNService {
            return lastPreferred
        }
        return availableVPNServices.first
    }
    
    private func resolveServiceForShortcutDisconnection(preferredService: SystemVPNService?) -> SystemVPNService? {
        if let preferredService = preferredService {
            return preferredService
        }
        if let connected = connectedVPNService {
            return connected
        }
        if let lastPreferred = preferredVPNService {
            let status = vpnManager.connectionStatus(for: lastPreferred)
            if status == .connected || status == .connecting {
                return lastPreferred
            }
        }
        return nil
    }
    
    private func connectServiceViaShortcut(_ service: SystemVPNService) {
        currentVPNStatus = .connecting
        vpnManager.connectVPN(service) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.currentVPNStatus = .disconnected
                self.presentVPNError(title: "VPN Connection Error", error: error)
                return
            }
            self.vpnManager.waitForStatus(for: service, desiredStatus: .connected) { [weak self] finalStatus in
                guard let self = self else { return }
                if finalStatus == .connected {
                    self.setConnectedVPNService(service)
                    AppLogger.shared.log("Shortcut connect confirmed for \(service.name).")
                } else {
                    self.presentInformationalAlert(title: "连接未完成", message: "VPN \(service.name) 未能在超时时间内建立连接。")
                    self.currentVPNStatus = .disconnected
                }
                self.refreshMenuUI()
            }
        }
    }
    
    private func disconnectServiceViaShortcut(_ service: SystemVPNService) {
        currentVPNStatus = .disconnecting
        vpnManager.disconnectVPN(service) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.currentVPNStatus = .connected
                self.presentVPNError(title: "VPN Disconnect Error", error: error)
                return
            }
            self.vpnManager.waitForStatus(for: service, desiredStatus: .disconnected) { [weak self] finalStatus in
                guard let self = self else { return }
                if finalStatus == .disconnected {
                    self.setConnectedVPNService(nil)
                    AppLogger.shared.log("Shortcut disconnect confirmed for \(service.name).")
                } else {
                    self.presentInformationalAlert(title: "断开未完成", message: "VPN \(service.name) 未能在超时时间内断开。")
                    self.currentVPNStatus = .connected
                }
                self.refreshMenuUI()
            }
        }
    }
    
    private func refreshMenuUI() {
        guard let menu = statusBarItem?.menu else { return }
        loadVPNConfigurations(menu: menu)
    }
    
    private func handleHotKey(eventRef: EventRef?) -> OSStatus {
        guard let eventRef = eventRef else { return noErr }
        var hotKeyID = EventHotKeyID()
        let result = GetEventParameter(
            eventRef,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        
        guard result == noErr,
              hotKeyID.signature == shortcutHotKeySignature,
              let identifier = ShortcutHotKey(rawValue: hotKeyID.id)
        else {
            return noErr
        }
        
        switch identifier {
        case .toggleCurrentVPN:
            handleToggleCurrentVPNShortcut()
        }
        
        return noErr
    }
    
    private func handleToggleCurrentVPNShortcut() {
        if let connectedService = connectedVPNService {
            let status = vpnManager.connectionStatus(for: connectedService)
            if status == .connected || status == .connecting {
                performShortcutAction(.disconnectCurrentVPN, preferredService: connectedService)
                return
            }
        }
        performShortcutAction(.connectCurrentVPN)
    }
    
    private func presentInformationalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func loadVPNConfigurations(menu: NSMenu) {
        AppLogger.shared.log("Requesting VPN configurations...")
        vpnManager.loadVPNs { [weak self] vpnServices in
            guard let self = self else { return }
            AppLogger.shared.log("Received \(vpnServices.count) VPN configurations.")

            let servicesSnapshot = vpnServices
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let servicesWithStatus = servicesSnapshot.map { service in
                    (service, self.vpnManager.connectionStatus(for: service))
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.applyVPNConfigurations(servicesWithStatus: servicesWithStatus, menu: menu)
                }
            }
        }
    }

    private func applyVPNConfigurations(servicesWithStatus: [(SystemVPNService, VPNManager.VPNConnectionStatus)], menu: NSMenu) {
        AppLogger.shared.log("Applying VPN configurations, count: \(servicesWithStatus.count)")
        availableVPNServices = servicesWithStatus.map { $0.0 }
        var detectedConnectedService: SystemVPNService?
        var prioritizedStatus: VPNManager.VPNConnectionStatus = .disconnected

        // 清除旧的VPN菜单项
        for item in vpnMenuItems {
            menu.removeItem(item)
        }
        vpnMenuItems.removeAll()

        // 清除旧的VPN状态菜单项
        for item in vpnStatusItems {
            menu.removeItem(item)
        }
        vpnStatusItems.removeAll()

        // 清除旧的VPN控制视图
        vpnControlViews.removeAll()

        // 如果没有VPN配置，显示提示信息
        if servicesWithStatus.isEmpty {
            AppLogger.shared.log("No VPN configurations found")
            let noVPNItem = NSMenuItem(title: "No VPN Configurations", action: nil, keyEquivalent: "")
            noVPNItem.isEnabled = false
            menu.insertItem(noVPNItem, at: menu.items.count - 5)
            vpnMenuItems.append(noVPNItem)
            return
        }

        // 添加新的VPN控制视图
        for (service, status) in servicesWithStatus {
            AppLogger.shared.log("Processing VPN service: \(service.name) (ID: \(service.id)), status: \(statusDescription(status))")
            if status == .connected {
                detectedConnectedService = service
                prioritizedStatus = .connected
            } else if prioritizedStatus != .connected {
                if status == .connecting || status == .disconnecting {
                    prioritizedStatus = status
                }
            }

            // 创建VPN控制视图
            let vpnControlView = VPNControlView(vpnService: service, vpnManager: vpnManager) { [weak self] in
                // 状态改变后的回调
                AppLogger.shared.log("VPN status changed for service: \(service.name), reloading configurations")
                self?.loadVPNConfigurations(menu: menu)
            }

            // 设置代理
            vpnControlView.setParentDelegate(self)

            // 创建包含自定义视图的菜单项
            let vpnItem = NSMenuItem()
            vpnItem.view = vpnControlView
            vpnItem.toolTip = service.name // 添加工具提示
            menu.insertItem(vpnItem, at: menu.items.count - 5)
            vpnMenuItems.append(vpnItem)
            vpnControlViews.append(vpnControlView)

            // 分隔符
            let separator = NSMenuItem.separator()
            menu.insertItem(separator, at: menu.items.count - 5)
            vpnMenuItems.append(separator)
        }

        connectedVPNService = detectedConnectedService
        currentVPNStatus = prioritizedStatus
        ensureSplittingTunnelAvailability()
        AppLogger.shared.log("Post-refresh status: \(statusDescription(prioritizedStatus)), connected service: \(detectedConnectedService?.name ?? "none"), splitting enabled: \(isSplittingTunnelEnabled)")
    }

    private func ensureSplittingTunnelAvailability() {
        AppLogger.shared.log("Ensuring splitting tunnel availability, current state: \(isSplittingTunnelEnabled), VPN status: \(statusDescription(currentVPNStatus))")
        guard isSplittingTunnelEnabled else { 
            AppLogger.shared.log("Splitting tunnel is not enabled, nothing to check")
            return 
        }
        guard let connectedService = connectedVPNService, currentVPNStatus == .connected else {
            AppLogger.shared.log("Splitting tunnel auto-disable: VPN not connected. Connected service: \(connectedVPNService?.name ?? "none"), VPN status: \(statusDescription(currentVPNStatus))")
            if splittingTunnelManager.isActive {
                AppLogger.shared.log("Splitting tunnel is active, disabling it due to VPN disconnection")
                splittingTunnelManager.disable { result in
                    switch result {
                    case .success:
                        AppLogger.shared.log("Splitting tunnel successfully disabled after VPN disconnection")
                    case .failure(let error):
                        AppLogger.shared.log("Failed to disable splitting tunnel after VPN disconnection: \(error.localizedDescription)")
                    }
                }
            } else {
                AppLogger.shared.log("Splitting tunnel is not active, no need to disable")
            }
            isSplittingTunnelEnabled = false
            splittingTunnelMenuItem?.state = .off
            return
        }
        AppLogger.shared.log("Splitting tunnel availability check passed: VPN is connected (\(connectedService.name))")
    }

    @objc func statusBarButtonClicked() {
        guard let menu = statusBarItem?.menu else { return }
        loadVPNConfigurations(menu: menu)
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        AppLogger.shared.log("Menu will open, reloading VPN configurations")
        guard menu == statusBarItem?.menu else { 
            AppLogger.shared.log("Menu is not the status bar menu, skipping reload")
            return 
        }
        loadVPNConfigurations(menu: menu)
    }
    
    @objc func toggleVPNConnection(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? SystemVPNService else { 
            AppLogger.shared.log("Failed to get VPN service from menu item")
            return 
        }
        let status = vpnManager.connectionStatus(for: service)
        AppLogger.shared.log("Toggle VPN action for '\(service.name)' current status=\(statusDescription(status))")
        
        switch status {
        case .connected:
            vpnManager.disconnectVPN(service) { [weak self] error in
                if let error = error {
                    self?.presentVPNError(title: "VPN Disconnect Error", error: error)
                } else {
                    self?.connectedVPNService = nil
                    self?.currentVPNStatus = .disconnected
                    AppLogger.shared.log("VPN '\(service.name)' disconnected successfully.")
                }
            }
        case .connecting, .disconnecting:
            return
        case .disconnected, .unknown:
            vpnManager.connectVPN(service) { [weak self] error in
                if let error = error {
                    self?.presentVPNError(title: "VPN Connection Error", error: error)
                } else {
                    self?.connectedVPNService = service
                    self?.currentVPNStatus = .connected
                    AppLogger.shared.log("VPN '\(service.name)' connected successfully.")
                }
            }
        }
        
        if let menu = statusBarItem?.menu {
            loadVPNConfigurations(menu: menu)
        }
    }
    
    private func connectMenuConfiguration(for status: VPNManager.VPNConnectionStatus) -> (title: String, enabled: Bool) {
        switch status {
        case .connected:
            return ("Disconnect", true)
        case .disconnected:
            return ("Connect", true)
        case .connecting:
            return ("Connecting...", false)
        case .disconnecting:
            return ("Disconnecting...", false)
        case .unknown:
            return ("Connect", true)
        }
    }

    private func statusDescription(_ status: VPNManager.VPNConnectionStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .unknown: return "unknown"
        }
    }
    
    private func presentVPNError(title: String, error: Error) {
        print("\(title): \(error)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
    
    @objc func toggleSplittingTunnel() {
        AppLogger.shared.log("Toggle Splitting Tunnel requested. Current state: \(isSplittingTunnelEnabled), operation in progress: \(splittingTunnelOperationInProgress), VPN status: \(statusDescription(currentVPNStatus)), connected service: \(connectedVPNService?.name ?? "none")")
        guard !splittingTunnelOperationInProgress else { 
            AppLogger.shared.log("Splitting tunnel operation already in progress, skipping request")
            return 
        }
        let targetState = !isSplittingTunnelEnabled
        let previousState = isSplittingTunnelEnabled
        AppLogger.shared.log("User toggled Splitting Tunnel -> \(targetState ? "Enable" : "Disable")")
        
        splittingTunnelOperationInProgress = true
        splittingTunnelMenuItem?.isEnabled = false
        splittingTunnelMenuItem?.state = .mixed
        
        if targetState {
            AppLogger.shared.log("Attempting to enable Splitting Tunnel")
            guard currentVPNStatus == .connected, let service = connectedVPNService else {
                AppLogger.shared.log("Splitting tunnel enable aborted: no connected VPN. Current status: \(statusDescription(currentVPNStatus)), connected service: \(connectedVPNService?.name ?? "none")")
                splittingTunnelOperationInProgress = false
                splittingTunnelMenuItem?.isEnabled = true
                splittingTunnelMenuItem?.state = previousState ? .on : .off
                presentVPNError(title: "Splitting Tunnel Error", error: SplittingTunnelError.noConnectedVPN)
                return
            }
            
            AppLogger.shared.log("Calling SplittingTunnelManager.enable for service: \(service.name) (ID: \(service.id))")
            splittingTunnelManager.enable(for: service) { [weak self] result in
                DispatchQueue.main.async {
                    AppLogger.shared.log("SplittingTunnelManager.enable completed with result: \(result), calling completion handler")
                    self?.handleSplittingTunnelCompletion(result, targetState: targetState, previousState: previousState)
                }
            }
        } else {
            AppLogger.shared.log("Calling SplittingTunnelManager.disable")
            splittingTunnelManager.disable { [weak self] result in
                DispatchQueue.main.async {
                    AppLogger.shared.log("SplittingTunnelManager.disable completed with result: \(result), calling completion handler")
                    self?.handleSplittingTunnelCompletion(result, targetState: targetState, previousState: previousState)
                }
            }
        }
    }
    
    private func handleSplittingTunnelCompletion(_ result: Result<Void, Error>, targetState: Bool, previousState: Bool) {
        AppLogger.shared.log("Handling splitting tunnel completion, target state: \(targetState), previous state: \(previousState)")
        splittingTunnelOperationInProgress = false
        splittingTunnelMenuItem?.isEnabled = true
        
        switch result {
        case .success:
            isSplittingTunnelEnabled = targetState
            splittingTunnelMenuItem?.state = targetState ? .on : .off
            AppLogger.shared.log("Splitting tunnel is now \(targetState ? "enabled" : "disabled").")
        case .failure(let error):
            isSplittingTunnelEnabled = previousState
            splittingTunnelMenuItem?.state = previousState ? .on : .off
            presentVPNError(title: "Splitting Tunnel Error", error: error)
            AppLogger.shared.log("Splitting tunnel toggle failed: \(error.localizedDescription)")
        }
        
        // 验证最终状态
        AppLogger.shared.log("Splitting tunnel final state verification - enabled flag: \(isSplittingTunnelEnabled), menu item state: \(splittingTunnelMenuItem?.state.rawValue ?? -1), manager active: \(splittingTunnelManager.isActive)")
    }
    
    @objc func openNetworkPreferences() {
        // 打开系统网络偏好设置
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.network")!)
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
