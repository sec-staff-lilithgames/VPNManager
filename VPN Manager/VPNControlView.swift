//
//  VPNControlView.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/12/25.
//

import SwiftUI
import AppKit
import SystemConfiguration
import Foundation

protocol VPNControlDelegate: AnyObject {
    func setConnectedVPNService(_ service: SystemVPNService?)
    func getConnectedVPNService() -> SystemVPNService?
}

class VPNControlView: NSView {
    private let vpnService: SystemVPNService
    private let vpnManager: VPNManager
    private var statusChangedHandler: (() -> Void)?
    
    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var timeLabel: NSTextField!
    private var switchControl: NSSwitch!
    
    // 记录连接开始时间
    private var connectionStartTime: Date?
    private var connectionTimer: Timer?
    
    init(vpnService: SystemVPNService, vpnManager: VPNManager, statusChangedHandler: @escaping (() -> Void)) {
        self.vpnService = vpnService
        self.vpnManager = vpnManager
        self.statusChangedHandler = statusChangedHandler
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        
        AppLogger.shared.log("Initializing VPNControlView for service: \(vpnService.name) (ID: \(vpnService.id))")
        setupUI()
        updateUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopConnectionTimer()
    }
    
    private func setupUI() {
        // 设置整体视图
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        
        // 创建图标视图
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = NSImage(systemSymbolName: "network", accessibilityDescription: "VPN Icon")
        iconView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        addSubview(iconView)
        
        // 创建名称标签
        nameLabel = NSTextField(labelWithString: vpnService.name.isEmpty ? "Unknown VPN" : vpnService.name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        nameLabel.toolTip = vpnService.interfaceDescription
        addSubview(nameLabel)
        
        // 创建状态标签
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize - 2)
        statusLabel.textColor = NSColor.secondaryLabelColor
        addSubview(statusLabel)
        
        // 创建时间标签
        timeLabel = NSTextField(labelWithString: "")
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize - 2)
        timeLabel.textColor = NSColor.tertiaryLabelColor
        timeLabel.isHidden = true
        addSubview(timeLabel)
        
        // 创建开关控件
        switchControl = NSSwitch()
        switchControl.translatesAutoresizingMaskIntoConstraints = false
        switchControl.target = self
        switchControl.action = #selector(switchToggled)
        addSubview(switchControl)
        
        // 设置约束
        NSLayoutConstraint.activate([
            // 图标约束
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            
            // 名称标签约束
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -8),
            
            // 状态标签约束
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: switchControl.leadingAnchor, constant: -8),
            
            // 时间标签约束
            timeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 1),
            timeLabel.trailingAnchor.constraint(equalTo: switchControl.leadingAnchor, constant: -8),
            
            // 开关约束
            switchControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            switchControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        
        // 调整视图高度以适应新标签
        setFrameSize(NSSize(width: 300, height: 60))
    }
    
    func updateUI() {
        let status = vpnManager.connectionStatus(for: vpnService)
        AppLogger.shared.log("Updating UI for VPN \(vpnService.name), current status: \(describeStatus(status))")
        
        // 更新图标
        if let image = NSImage(systemSymbolName: status == .connected ? "network" : "network.slash", 
                              accessibilityDescription: status == .connected ? "Connected" : "Disconnected") {
            iconView.image = image
            iconView.symbolConfiguration = .init(pointSize: 16, weight: .regular, scale: .medium)
            if status == .connected {
                iconView.contentTintColor = NSColor.systemGreen
            } else {
                iconView.contentTintColor = NSColor.secondaryLabelColor
            }
        }
        
        // 更新开关状态
        switchControl.state = status == .connected ? .on : .off
        
        // 根据状态设置开关是否可用
        switchControl.isEnabled = (status != .connecting && status != .disconnecting)
        
        // 更新时间标签
        updateTimeLabel()
    }
    
    private func updateTimeLabel() {
        let status = vpnManager.connectionStatus(for: vpnService)
        
        if status == .connected {
            startConnectionTimer()

            if connectionStartTime == nil {
                // 如果是刚连接，记录开始时间
                connectionStartTime = Date()
            }
            
            // 计算连接时长并显示
            if let startTime = connectionStartTime {
                let interval = Int(Date().timeIntervalSince(startTime))
                let hours = interval / 3600
                let minutes = (interval % 3600) / 60
                let seconds = interval % 60
                
                var timeString = ""
                if hours > 0 {
                    timeString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
                } else {
                    timeString = String(format: "%02d:%02d", minutes, seconds)
                }
                
                timeLabel.stringValue = "Connected for: \(timeString)"
                timeLabel.isHidden = false
            } else {
                timeLabel.isHidden = true
            }
        } else {
            // 断开连接时隐藏时间标签
            timeLabel.isHidden = true
            // 重置连接时间
            connectionStartTime = nil
            stopConnectionTimer()
        }
    }

    private func startConnectionTimer() {
        guard connectionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimeLabel()
        }
        connectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func stopConnectionTimer() {
        connectionTimer?.invalidate()
        connectionTimer = nil
    }
    
    @objc private func switchToggled() {
        let status = vpnManager.connectionStatus(for: vpnService)
        AppLogger.shared.log("Switch toggled for VPN \(vpnService.name), current status: \(describeStatus(status))")
        
        if switchControl.state == .on {
            handleConnectRequest(currentStatus: status)
        } else {
            handleDisconnectRequest(currentStatus: status)
        }
    }
    
    private func handleError(_ error: Error, action: String) {
        AppLogger.shared.log("VPN \(action) error: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "VPN \(action.capitalized) Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
    
    private weak var parentDelegate: VPNControlDelegate?
    
    func setParentDelegate(_ delegate: VPNControlDelegate) {
        parentDelegate = delegate
    }
    
    private func updateParentConnectionStatus(_ service: SystemVPNService?, isConnected: Bool) {
        if isConnected {
            parentDelegate?.setConnectedVPNService(service)
        } else if parentDelegate?.getConnectedVPNService() == service {
            parentDelegate?.setConnectedVPNService(nil)
        }
    }

    private func handleConnectRequest(currentStatus: VPNManager.VPNConnectionStatus) {
        AppLogger.shared.log("Handling connect request for VPN \(vpnService.name), current status: \(describeStatus(currentStatus))")
        guard currentStatus != .connected && currentStatus != .connecting else {
            AppLogger.shared.log("VPN \(vpnService.name) is already connected/connecting, skipping connect request")
            updateUI()
            return
        }

        switchControl.isEnabled = false
        vpnManager.connectVPN(vpnService) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                AppLogger.shared.log("Error connecting VPN \(self.vpnService.name): \(error.localizedDescription)")
                self.switchControl.isEnabled = true
                self.switchControl.state = .off
                self.handleError(error, action: "connect")
                self.updateUI()
                self.statusChangedHandler?()
                return
            }

            AppLogger.shared.log("VPN '\(self.vpnService.name)' start command completed, waiting for connected state.")
            self.waitForServiceStatus(.connected) { [weak self] in
                guard let self = self else { return }
                self.parentDelegate?.setConnectedVPNService(self.vpnService)
                self.connectionStartTime = Date() // 记录连接开始时间
                self.updateTimeLabel() // 更新时间显示
                AppLogger.shared.log("VPN '\(self.vpnService.name)' reported connected.")
            } failure: { [weak self] status in
                guard let self = self else { return }
                self.switchControl.state = .off
                AppLogger.shared.log("VPN '\(self.vpnService.name)' did not reach connected state (last status: \(self.describeStatus(status))).")
            }
        }
    }

    private func handleDisconnectRequest(currentStatus: VPNManager.VPNConnectionStatus) {
        AppLogger.shared.log("Handling disconnect request for VPN \(vpnService.name), current status: \(describeStatus(currentStatus))")
        guard currentStatus == .connected || currentStatus == .connecting else {
            AppLogger.shared.log("VPN \(vpnService.name) is not connected/connecting, skipping disconnect request")
            updateUI()
            return
        }

        switchControl.isEnabled = false
        vpnManager.disconnectVPN(vpnService) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                AppLogger.shared.log("Error disconnecting VPN \(self.vpnService.name): \(error.localizedDescription)")
                self.switchControl.isEnabled = true
                self.switchControl.state = .on
                self.handleError(error, action: "disconnect")
                self.updateUI()
                self.statusChangedHandler?()
                return
            }

            AppLogger.shared.log("VPN '\(self.vpnService.name)' stop command completed, waiting for disconnected state.")
            self.waitForServiceStatus(.disconnected) { [weak self] in
                guard let self = self else { return }
                if self.parentDelegate?.getConnectedVPNService() == self.vpnService {
                    self.parentDelegate?.setConnectedVPNService(nil)
                }
                self.connectionStartTime = nil // 清除连接时间
                self.updateTimeLabel() // 更新时间显示
                AppLogger.shared.log("VPN '\(self.vpnService.name)' reported disconnected.")
            } failure: { [weak self] status in
                guard let self = self else { return }
                self.switchControl.state = .on
                AppLogger.shared.log("VPN '\(self.vpnService.name)' did not reach disconnected state (last status: \(self.describeStatus(status))).")
            }
        }
    }

    private func waitForServiceStatus(_ desiredStatus: VPNManager.VPNConnectionStatus,
                                      success: @escaping () -> Void,
                                      failure: @escaping (VPNManager.VPNConnectionStatus) -> Void) {
        AppLogger.shared.log("Waiting for VPN \(vpnService.name) to reach status: \(describeStatus(desiredStatus))")
        vpnManager.waitForStatus(for: vpnService, desiredStatus: desiredStatus) { [weak self] finalStatus in
            guard let self = self else { return }
            self.switchControl.isEnabled = true
            if finalStatus == desiredStatus {
                AppLogger.shared.log("VPN \(self.vpnService.name) successfully reached desired status: \(self.describeStatus(desiredStatus))")
                success()
            } else {
                AppLogger.shared.log("VPN \(self.vpnService.name) failed to reach desired status \(self.describeStatus(desiredStatus)), final status: \(self.describeStatus(finalStatus))")
                failure(finalStatus)
            }
            self.updateUI()
            self.statusChangedHandler?()
        }
    }

    private func describeStatus(_ status: VPNManager.VPNConnectionStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .unknown: return "unknown"
        }
    }
}
