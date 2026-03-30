//
//  VPNInteractionController.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 3/30/26.
//

import Foundation

enum VPNInteractionError: LocalizedError {
    case noAvailableVPN
    case connectTimeout(String)
    case disconnectTimeout(String)

    var errorDescription: String? {
        switch self {
        case .noAvailableVPN:
            return "当前没有可操作的 VPN 配置。"
        case .connectTimeout(let serviceName):
            return "VPN \(serviceName) 未能在超时时间内建立连接。"
        case .disconnectTimeout(let serviceName):
            return "VPN \(serviceName) 未能在超时时间内断开。"
        }
    }
}

struct VPNObservedState {
    let connectedService: SystemVPNService?
    let overallStatus: VPNManager.VPNConnectionStatus
    let availableServices: [SystemVPNService]
}

final class VPNInteractionController {
    private let vpnManager: VPNManager

    private(set) var connectedVPNService: SystemVPNService?
    private(set) var preferredVPNService: SystemVPNService?
    private(set) var currentVPNStatus: VPNManager.VPNConnectionStatus = .disconnected
    private(set) var availableVPNServices: [SystemVPNService] = []

    init(vpnManager: VPNManager) {
        self.vpnManager = vpnManager
    }

    func loadVPNs(completion: @escaping ([SystemVPNService]) -> Void) {
        vpnManager.loadVPNs(completion: completion)
    }

    func connectionStatus(for service: SystemVPNService) -> VPNManager.VPNConnectionStatus {
        vpnManager.connectionStatus(for: service)
    }

    func connectionSnapshot(for service: SystemVPNService) -> VPNManager.VPNConnectionSnapshot {
        vpnManager.connectionSnapshot(for: service)
    }

    @discardableResult
    func observe(servicesWithStatus: [(SystemVPNService, VPNManager.VPNConnectionStatus)]) -> VPNObservedState {
        availableVPNServices = servicesWithStatus.map(\.0)

        var detectedConnectedService: SystemVPNService?
        var prioritizedStatus: VPNManager.VPNConnectionStatus = .disconnected

        for (service, status) in servicesWithStatus {
            if status == .connected {
                detectedConnectedService = service
                prioritizedStatus = .connected
            } else if prioritizedStatus != .connected, status == .connecting || status == .disconnecting {
                prioritizedStatus = status
            }
        }

        connectedVPNService = detectedConnectedService
        if let detectedConnectedService = detectedConnectedService {
            preferredVPNService = detectedConnectedService
        }
        currentVPNStatus = prioritizedStatus

        return VPNObservedState(
            connectedService: detectedConnectedService,
            overallStatus: prioritizedStatus,
            availableServices: availableVPNServices
        )
    }

    func connect(_ service: SystemVPNService, completion: @escaping (Result<Void, Error>) -> Void) {
        AppLogger.shared.log("Interaction controller connecting VPN: \(service.name)")
        currentVPNStatus = .connecting

        vpnManager.connectVPN(service) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.currentVPNStatus = .disconnected
                completion(.failure(error))
                return
            }

            self.vpnManager.waitForStatus(for: service, desiredStatus: .connected) { [weak self] finalStatus in
                guard let self = self else { return }
                if finalStatus == .connected {
                    self.connectedVPNService = service
                    self.preferredVPNService = service
                    self.currentVPNStatus = .connected
                    completion(.success(()))
                } else {
                    self.currentVPNStatus = .disconnected
                    completion(.failure(VPNInteractionError.connectTimeout(service.name)))
                }
            }
        }
    }

    func disconnect(_ service: SystemVPNService, completion: @escaping (Result<Void, Error>) -> Void) {
        AppLogger.shared.log("Interaction controller disconnecting VPN: \(service.name)")
        currentVPNStatus = .disconnecting

        vpnManager.disconnectVPN(service) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.currentVPNStatus = .connected
                completion(.failure(error))
                return
            }

            self.vpnManager.waitForStatus(for: service, desiredStatus: .disconnected) { [weak self] finalStatus in
                guard let self = self else { return }
                if finalStatus == .disconnected {
                    if self.connectedVPNService == service {
                        self.connectedVPNService = nil
                    }
                    self.currentVPNStatus = .disconnected
                    completion(.success(()))
                } else {
                    self.currentVPNStatus = .connected
                    completion(.failure(VPNInteractionError.disconnectTimeout(service.name)))
                }
            }
        }
    }

    func toggleCurrentVPN(completion: @escaping (Result<Void, Error>) -> Void) {
        if let connectedService = connectedVPNService {
            let status = connectionStatus(for: connectedService)
            if status == .connected || status == .connecting {
                AppLogger.shared.log("Interaction controller resolved toggle to disconnect: \(connectedService.name)")
                disconnect(connectedService, completion: completion)
                return
            }
        }

        guard let target = resolveServiceForShortcutConnection() ?? resolveServiceForShortcutDisconnection() else {
            AppLogger.shared.log("Interaction controller toggle ignored because no VPN service is available")
            completion(.failure(VPNInteractionError.noAvailableVPN))
            return
        }

        AppLogger.shared.log("Interaction controller resolved toggle to connect: \(target.name)")
        connect(target, completion: completion)
    }
}

private extension VPNInteractionController {
    func resolveServiceForShortcutConnection() -> SystemVPNService? {
        if let connected = connectedVPNService {
            let status = connectionStatus(for: connected)
            if status == .disconnected || status == .unknown {
                return connected
            }
        }
        if let lastPreferred = preferredVPNService {
            return lastPreferred
        }
        return availableVPNServices.first
    }

    func resolveServiceForShortcutDisconnection() -> SystemVPNService? {
        if let connected = connectedVPNService {
            return connected
        }
        if let lastPreferred = preferredVPNService {
            let status = connectionStatus(for: lastPreferred)
            if status == .connected || status == .connecting {
                return lastPreferred
            }
        }
        return nil
    }
}
