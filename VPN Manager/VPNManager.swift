//
//  VPNManager.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/11/25.
//

import Foundation
import SystemConfiguration

final class VPNManager: NSObject {
    struct VPNConnectionSnapshot {
        let status: VPNConnectionStatus
        let lastStatusChangeTime: Date?
    }

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
        connectionSnapshot(for: service).status
    }

    func connectionSnapshot(for service: SystemVPNService) -> VPNConnectionSnapshot {
        vpnSnapshot(for: service)
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

private extension VPNManager {
    static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return formatter
    }()

    func fetchSystemVPNServices() -> [SystemVPNService] {
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
                isVPNInterface(interface),
                isDisplayableVPNService(service)
            else {
                return nil
            }

            let name = SCNetworkServiceGetName(service) as String? ?? "VPN"
            let serviceID = SCNetworkServiceGetServiceID(service) as String? ?? UUID().uuidString
            let description = interfaceDisplayName(for: interface)
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

    func isDisplayableVPNService(_ service: SCNetworkService) -> Bool {
        let name = SCNetworkServiceGetName(service) as String? ?? "VPN"

        guard SCNetworkServiceGetEnabled(service) else {
            AppLogger.shared.log("Skipping disabled VPN service: \(name)")
            return false
        }

        let protocols = SCNetworkServiceCopyProtocols(service) as? [SCNetworkProtocol] ?? []
        guard !protocols.isEmpty else {
            AppLogger.shared.log("Skipping VPN service without protocol configuration: \(name)")
            return false
        }

        return true
    }

    func isVPNInterface(_ interface: SCNetworkInterface) -> Bool {
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

    func interfaceDisplayName(for interface: SCNetworkInterface) -> String {
        if let localized = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?, !localized.isEmpty {
            return localized
        }

        if let type = SCNetworkInterfaceGetInterfaceType(interface) as String?, !type.isEmpty {
            return type == appVPNInterfaceType ? "App VPN" : type
        }

        return "VPN"
    }

    func runScutilCommand(arguments: [String], completion: @escaping (Error?) -> Void) {
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

    func executeScutil(arguments: [String]) throws -> String {
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

    func vpnSnapshot(for service: SystemVPNService) -> VPNConnectionSnapshot {
        AppLogger.shared.log("Checking status for VPN: \(service.name)")
        do {
            let output = try executeScutil(arguments: ["--nc", "status", service.name])
            guard let firstLine = output.components(separatedBy: .newlines).first else {
                AppLogger.shared.log("Could not get status from output for VPN: \(service.name)")
                return VPNConnectionSnapshot(status: .unknown, lastStatusChangeTime: nil)
            }

            let status = firstLine.lowercased()
            AppLogger.shared.log("Got status for VPN \(service.name): \(status)")
            let lastStatusChangeTime = parseLastStatusChangeTime(from: output)

            switch status {
            case "connected":
                return VPNConnectionSnapshot(status: .connected, lastStatusChangeTime: lastStatusChangeTime)
            case "connecting":
                return VPNConnectionSnapshot(status: .connecting, lastStatusChangeTime: lastStatusChangeTime)
            case "disconnecting":
                return VPNConnectionSnapshot(status: .disconnecting, lastStatusChangeTime: lastStatusChangeTime)
            case "disconnected":
                return VPNConnectionSnapshot(status: .disconnected, lastStatusChangeTime: lastStatusChangeTime)
            default:
                return VPNConnectionSnapshot(status: .unknown, lastStatusChangeTime: lastStatusChangeTime)
            }
        } catch {
            AppLogger.shared.log("Error checking status for VPN \(service.name): \(error.localizedDescription)")
            return VPNConnectionSnapshot(status: .unknown, lastStatusChangeTime: nil)
        }
    }

    func parseLastStatusChangeTime(from output: String) -> Date? {
        guard let line = output.components(separatedBy: .newlines).first(where: { $0.contains("LastStatusChangeTime") }),
              let rawValue = line.split(separator: ":", maxSplits: 1).last
        else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.statusDateFormatter.date(from: value)
    }
}
