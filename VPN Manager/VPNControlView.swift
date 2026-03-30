//
//  VPNControlView.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/12/25.
//

import AppKit
import Foundation

final class VPNControlView: NSView {
    private let vpnService: SystemVPNService
    private let interactionController: VPNInteractionController
    private let statusChangedHandler: () -> Void
    private let errorPresenter: (String, Error) -> Void

    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var timeLabel: NSTextField!
    private var switchControl: NSSwitch!

    private var connectionTimer: Timer?

    init(vpnService: SystemVPNService,
         interactionController: VPNInteractionController,
         statusChangedHandler: @escaping () -> Void,
         errorPresenter: @escaping (String, Error) -> Void) {
        self.vpnService = vpnService
        self.interactionController = interactionController
        self.statusChangedHandler = statusChangedHandler
        self.errorPresenter = errorPresenter
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
}

private extension VPNControlView {
    func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = NSImage(systemSymbolName: "network", accessibilityDescription: "VPN Icon")
        iconView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        addSubview(iconView)

        nameLabel = NSTextField(labelWithString: vpnService.name.isEmpty ? "Unknown VPN" : vpnService.name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        nameLabel.toolTip = vpnService.interfaceDescription
        addSubview(nameLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize - 2)
        statusLabel.textColor = NSColor.secondaryLabelColor
        addSubview(statusLabel)

        timeLabel = NSTextField(labelWithString: "")
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize - 2)
        timeLabel.textColor = NSColor.tertiaryLabelColor
        timeLabel.isHidden = true
        addSubview(timeLabel)

        switchControl = NSSwitch()
        switchControl.translatesAutoresizingMaskIntoConstraints = false
        switchControl.target = self
        switchControl.action = #selector(switchToggled)
        addSubview(switchControl)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchControl.leadingAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: switchControl.leadingAnchor, constant: -8),

            timeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 1),
            timeLabel.trailingAnchor.constraint(equalTo: switchControl.leadingAnchor, constant: -8),

            switchControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            switchControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setFrameSize(NSSize(width: 300, height: 60))
    }

    func updateUI() {
        let snapshot = interactionController.connectionSnapshot(for: vpnService)
        let status = snapshot.status
        AppLogger.shared.log("Updating UI for VPN \(vpnService.name), current status: \(describeStatus(status))")

        statusLabel.stringValue = displayText(for: status)

        if let image = NSImage(systemSymbolName: status == .connected ? "network" : "network.slash",
                               accessibilityDescription: status == .connected ? "Connected" : "Disconnected") {
            iconView.image = image
            iconView.symbolConfiguration = .init(pointSize: 16, weight: .regular, scale: .medium)
            iconView.contentTintColor = status == .connected ? NSColor.systemGreen : NSColor.secondaryLabelColor
        }

        switchControl.state = status == .connected ? .on : .off
        switchControl.isEnabled = (status != .connecting && status != .disconnecting)
        updateTimeLabel(for: snapshot)
    }

    func updateTimeLabel(for snapshot: VPNManager.VPNConnectionSnapshot) {
        let status = snapshot.status
        if status == .connected {
            startConnectionTimer()

            if let startTime = snapshot.lastStatusChangeTime {
                let interval = Int(Date().timeIntervalSince(startTime))
                let hours = interval / 3600
                let minutes = (interval % 3600) / 60
                let seconds = interval % 60

                let timeString: String
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
            timeLabel.isHidden = true
            stopConnectionTimer()
        }
    }

    func startConnectionTimer() {
        guard connectionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateTimeLabel(for: self.interactionController.connectionSnapshot(for: self.vpnService))
        }
        connectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopConnectionTimer() {
        connectionTimer?.invalidate()
        connectionTimer = nil
    }

    @objc func switchToggled() {
        let status = interactionController.connectionStatus(for: vpnService)
        AppLogger.shared.log("Switch toggled for VPN \(vpnService.name), current status: \(describeStatus(status))")

        if switchControl.state == .on {
            handleConnectRequest(currentStatus: status)
        } else {
            handleDisconnectRequest(currentStatus: status)
        }
    }

    func handleConnectRequest(currentStatus: VPNManager.VPNConnectionStatus) {
        AppLogger.shared.log("Handling connect request for VPN \(vpnService.name), current status: \(describeStatus(currentStatus))")
        guard currentStatus != .connected && currentStatus != .connecting else {
            AppLogger.shared.log("VPN \(vpnService.name) is already connected/connecting, skipping connect request")
            updateUI()
            return
        }

        switchControl.isEnabled = false
        interactionController.connect(vpnService) { [weak self] result in
            guard let self = self else { return }
            self.handleOperationCompletion(result, fallbackState: .off)
        }
    }

    func handleDisconnectRequest(currentStatus: VPNManager.VPNConnectionStatus) {
        AppLogger.shared.log("Handling disconnect request for VPN \(vpnService.name), current status: \(describeStatus(currentStatus))")
        guard currentStatus == .connected || currentStatus == .connecting else {
            AppLogger.shared.log("VPN \(vpnService.name) is not connected/connecting, skipping disconnect request")
            updateUI()
            return
        }

        switchControl.isEnabled = false
        interactionController.disconnect(vpnService) { [weak self] result in
            guard let self = self else { return }
            self.handleOperationCompletion(result, fallbackState: .on)
        }
    }

    func handleOperationCompletion(_ result: Result<Void, Error>, fallbackState: NSControl.StateValue) {
        switch result {
        case .success:
            AppLogger.shared.log("VPN '\(vpnService.name)' operation completed successfully.")
        case .failure(let error):
            AppLogger.shared.log("VPN '\(vpnService.name)' operation failed: \(error.localizedDescription)")
            switchControl.state = fallbackState
            errorPresenter("VPN Error", error)
        }

        updateUI()
        statusChangedHandler()
    }

    func displayText(for status: VPNManager.VPNConnectionStatus) -> String {
        switch status {
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

    func describeStatus(_ status: VPNManager.VPNConnectionStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .unknown: return "unknown"
        }
    }
}
