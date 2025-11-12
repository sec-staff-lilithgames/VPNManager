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
    private var switchControl: NSSwitch!
    
    init(vpnService: SystemVPNService, vpnManager: VPNManager, statusChangedHandler: @escaping (() -> Void)) {
        self.vpnService = vpnService
        self.vpnManager = vpnManager
        self.statusChangedHandler = statusChangedHandler
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        
        setupUI()
        updateUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            
            // 开关约束
            switchControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            switchControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    
    func updateUI() {
        let status = vpnManager.connectionStatus(for: vpnService)
        
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
        
        // 更新状态标签
        statusLabel.stringValue = vpnManager.getVPNStatusText(vpnService)
        
        // 更新开关状态
        switchControl.state = status == .connected ? .on : .off
        
        // 根据状态设置开关是否可用
        switchControl.isEnabled = (status != .connecting && status != .disconnecting)
    }
    
    @objc private func switchToggled() {
        let status = vpnManager.connectionStatus(for: vpnService)
        
        if switchControl.state == .on {
            // 用户想连接
            if status != .connected && status != .connecting {
                vpnManager.connectVPN(vpnService) { [weak self] error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self?.handleError(error, action: "connect")
                            // 连接失败，重置开关状态
                            self?.switchControl.state = .off
                        } else {
                            AppLogger.shared.log("VPN '\(self?.vpnService.name ?? "")' connected successfully.")
                            // 通知父级更新连接状态
                            self?.parentDelegate?.setConnectedVPNService(self?.vpnService)
                        }
                        self?.updateUI()
                        self?.statusChangedHandler?()
                    }
                }
            }
        } else {
            // 用户想断开
            if status == .connected || status == .connecting {
                vpnManager.disconnectVPN(vpnService) { [weak self] error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self?.handleError(error, action: "disconnect")
                            // 断开失败，保持开关状态
                            self?.switchControl.state = .on
                        } else {
                            AppLogger.shared.log("VPN '\(self?.vpnService.name ?? "")' disconnected successfully.")
                            // 通知父级更新连接状态
                            if self?.parentDelegate?.getConnectedVPNService() == self?.vpnService {
                                self?.parentDelegate?.setConnectedVPNService(nil)
                            }
                        }
                        self?.updateUI()
                        self?.statusChangedHandler?()
                    }
                }
            }
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
}