//
//  SplittingTunnelManager.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/11/25.
//

import Foundation
import SystemConfiguration
import Security
import Darwin

@_silgen_name("AuthorizationExecuteWithPrivileges")
private func AuthorizationExecuteWithPrivileges(_ authorization: AuthorizationRef,
                                                _ pathToTool: UnsafePointer<CChar>,
                                                _ options: AuthorizationFlags,
                                                _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                                _ communicationsPipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus

enum SplittingTunnelError: LocalizedError {
    case noConnectedVPN
    case missingVPNInterface
    case defaultRouteUnavailable
    case authorizationUnavailable
    case commandFailed(String)
    case databaseUnavailable(String)
    case vpnGatewayUnavailable

    var errorDescription: String? {
        switch self {
        case .noConnectedVPN:
            return "没有正在连接的 VPN，无法启用 Splitting Tunnel。"
        case .missingVPNInterface:
            return "无法获取 VPN 接口名称。请确认该 VPN 支持手动路由配置。"
        case .defaultRouteUnavailable:
            return "无法获取当前默认网关信息。"
        case .authorizationUnavailable:
            return "需要管理员权限以配置系统路由。"
        case .commandFailed(let message):
            return "配置流量分流时执行系统命令失败：\(message)"
        case .databaseUnavailable(let reason):
            return "无法加载中国 IP 数据：\(reason)"
        case .vpnGatewayUnavailable:
            return "无法解析当前 VPN 的网关地址，请重试或检查 VPN 配置。"
        }
    }
}

struct SystemRouteInfo {
    let localInterface: String
    let physicalGateway: String
}

final class DefaultRouteInfoFetcher {
    private let disallowedInterfacePrefixes = ["utun", "ppp", "ipsec", "awdl", "llw"]

    func fetch() throws -> SystemRouteInfo {
        guard let store = SCDynamicStoreCreate(nil, "VPN Manager" as CFString, nil, nil),
              let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else {
            throw SplittingTunnelError.defaultRouteUnavailable
        }

        if let route = resolvePhysicalDefaultRoute() {
            AppLogger.shared.log("Default route localInterface=\(route.interface) physicalGateway=\(route.gateway)")
            return SystemRouteInfo(localInterface: route.interface, physicalGateway: route.gateway)
        }

        guard let interface = globalIPv4["PrimaryInterface"] as? String,
              !interface.isEmpty,
              !isDisallowedInterface(interface),
              let router = globalIPv4["Router"] as? String,
              !router.isEmpty else {
            throw SplittingTunnelError.defaultRouteUnavailable
        }

        AppLogger.shared.log("Fallback default route localInterface=\(interface) physicalGateway=\(router)")
        return SystemRouteInfo(localInterface: interface, physicalGateway: router)
    }

    private func resolvePhysicalDefaultRoute() -> (interface: String, gateway: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", "inet"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            AppLogger.shared.log("Failed to execute netstat for default route lookup: \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            AppLogger.shared.log("netstat returned non-zero status when resolving default route.")
            return nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("default") else { continue }

            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 4 else { continue }

            let interface = columns.last ?? ""
            if isDisallowedInterface(interface) {
                continue
            }

            let gateway = columns.count > 1 ? columns[1] : ""
            if gateway.isEmpty || gateway.hasPrefix("link#") {
                continue
            }

            AppLogger.shared.log("Detected physical default route via netstat: interface=\(interface) gateway=\(gateway)")
            return (interface, gateway)
        }

        AppLogger.shared.log("Failed to find physical default interface via netstat output.")
        return nil
    }

    private func isDisallowedInterface(_ interface: String) -> Bool {
        return disallowedInterfacePrefixes.contains { interface.hasPrefix($0) }
    }
}

final class ChinaIPDatabase {
    private let remoteURL = URL(string: "https://ispip.clang.cn/all_cn_cidr.txt")!
    private let cacheURL: URL
    private let fileManager = FileManager.default
    private let fallbackCIDR: String = """
1.0.1.0/24
1.0.2.0/23
1.0.8.0/21
1.0.32.0/19
1.1.0.0/24
1.1.2.0/23
1.1.4.0/24
1.1.8.0/21
1.2.0.0/23
1.2.2.0/24
1.2.4.0/22
1.2.8.0/21
1.2.16.0/20
1.2.128.0/17
1.8.0.0/16
1.10.0.0/15
1.12.0.0/14
1.48.0.0/15
1.50.0.0/16
1.51.0.0/16
"""

    init(workDirectory: URL) {
        self.cacheURL = workDirectory.appendingPathComponent("china_ip_list.txt", isDirectory: false)
    }

    func ensureDatabase() async throws -> URL {
        if let attributes = try? fileManager.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 60 * 60 * 24 {
            AppLogger.shared.log("Using cached China IP database at \(cacheURL.path)")
            return cacheURL
        }

        do {
            AppLogger.shared.log("Downloading China IP database from \(remoteURL.absoluteString)")
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw SplittingTunnelError.databaseUnavailable("远程服务器响应异常。")
            }
            try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            AppLogger.shared.log("China IP database downloaded successfully.")
            return cacheURL
        } catch {
            if fileManager.fileExists(atPath: cacheURL.path) {
                AppLogger.shared.log("Download failed but cached China IP database exists. Error: \(error.localizedDescription)")
                return cacheURL
            }

            do {
                try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fallbackCIDR.write(to: cacheURL, atomically: true, encoding: .utf8)
                AppLogger.shared.log("Using fallback China IP database.")
                return cacheURL
            } catch {
                throw SplittingTunnelError.databaseUnavailable("无法写入备用 IP 数据。")
            }
        }
    }
}

final class PrivilegedCommandRunner {
    private var authorizationRef: AuthorizationRef?

    private func ensureAuthorization() throws -> AuthorizationRef {
        if let ref = authorizationRef {
            return ref
        }

        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let ref = authRef else {
            throw SplittingTunnelError.authorizationUnavailable
        }

        var right = AuthorizationItem(name: kAuthorizationRightExecute, valueLength: 0, value: nil, flags: 0)
        var rights = AuthorizationRights(count: 1, items: &right)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let copyStatus = AuthorizationCopyRights(ref, &rights, nil, flags, nil)
        guard copyStatus == errAuthorizationSuccess else {
            throw SplittingTunnelError.authorizationUnavailable
        }

        authorizationRef = ref
        return ref
    }

    deinit {
        if let ref = authorizationRef {
            AuthorizationFree(ref, [])
        }
    }

    @discardableResult
    func execute(path: String, arguments: [String]) throws -> String {
        let ref = try ensureAuthorization()

        var cArguments = arguments.map { strdup($0) }
        cArguments.append(nil)
        defer {
            for pointer in cArguments where pointer != nil {
                free(pointer)
            }
        }

        var pipe: UnsafeMutablePointer<FILE>?
        var status: OSStatus = errAuthorizationSuccess
        cArguments.withUnsafeMutableBufferPointer { buffer in
            status = AuthorizationExecuteWithPrivileges(ref, path, [], buffer.baseAddress, &pipe)
        }
        guard status == errAuthorizationSuccess else {
            AppLogger.shared.log("Command \(path) \(arguments.joined(separator: " ")) failed with status \(status)")
            throw SplittingTunnelError.commandFailed("AuthorizationExecuteWithPrivileges 返回 \(status)")
        }

        var outputData = Data()
        if let pipe = pipe {
            let fileDescriptor = fileno(pipe)
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            outputData = handle.readDataToEndOfFile()
            handle.closeFile()
            fclose(pipe)
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        AppLogger.shared.log("Command \(path) \(arguments.joined(separator: " ")) succeeded. Output length=\(output.count)")
        return output
    }

    func ensurePacketFilterEnabled() throws {
        let statusOutput = try execute(path: "/sbin/pfctl", arguments: ["-q", "-si"])
        guard statusOutput.contains("Status: Enabled") else {
            _ = try execute(path: "/sbin/pfctl", arguments: ["-q", "-E"])
            AppLogger.shared.log("Packet filter was disabled. Enabled via pfctl.")
            return
        }
        AppLogger.shared.log("Packet filter already enabled.")
    }

    func loadAnchor(_ anchorName: String, rulesPath: String) throws {
        AppLogger.shared.log("Loading PF anchor \(anchorName) with rules from \(rulesPath)")
        _ = try execute(path: "/sbin/pfctl", arguments: ["-q", "-a", anchorName, "-f", rulesPath])
    }

    func flushAnchor(_ anchorName: String) throws {
        AppLogger.shared.log("Flushing PF anchor \(anchorName)")
        _ = try execute(path: "/sbin/pfctl", arguments: ["-q", "-a", anchorName, "-F", "rules"])
    }
}

final class SplittingTunnelManager {
    enum State {
        case disabled
        case enabled(localInterface: String, vpnInterface: String)
    }

    private let workDirectory: URL
    private let anchorFileURL: URL
    private let queue = DispatchQueue(label: "com.vpnmanager.splitting", qos: .userInitiated)
    private var state: State = .disabled

    private let routeFetcher = DefaultRouteInfoFetcher()
    private lazy var commandRunner: PrivilegedCommandRunner? = try? PrivilegedCommandRunner()
    private lazy var chinaDatabase = ChinaIPDatabase(workDirectory: workDirectory)

    private let anchorName = "com.apple/100.vpnmanager.split"

    init() {
        self.workDirectory = SplittingTunnelManager.resolveWorkDirectory()
        self.anchorFileURL = workDirectory.appendingPathComponent("vpnmanager_anchor.conf", isDirectory: false)
        AppLogger.shared.log("SplittingTunnel work directory: \(workDirectory.path)")
    }

    private var isActiveState: Bool {
        if case .enabled = state {
            return true
        }
        return false
    }

    var isActive: Bool {
        queue.sync {
            self.isActiveState
        }
    }

    func enable(for service: SystemVPNService, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            AppLogger.shared.log("Enabling splitting tunnel for service \(service.name) (ID: \(service.id))")
            guard let vpnInterface = self.runtimeInterfaceName(for: service) else {
                AppLogger.shared.log("Unable to determine runtime interface for service \(service.name).")
                completion(.failure(SplittingTunnelError.missingVPNInterface))
                return
            }

            do {
                AppLogger.shared.log("Enabling splitting tunnel for service \(service.name) vpnInterface=\(vpnInterface)")
                let routeInfo = try self.routeFetcher.fetch()
                guard let vpnGateway = self.resolveVPNGateway(for: service, interfaceName: vpnInterface),
                      !vpnGateway.isEmpty else {
                    AppLogger.shared.log("Unable to resolve VPN gateway for interface \(vpnInterface). Aborting splitting tunnel enablement.")
                    completion(.failure(SplittingTunnelError.vpnGatewayUnavailable))
                    return
                }
                AppLogger.shared.log("Route info: localInterface=\(routeInfo.localInterface), physicalGateway=\(routeInfo.physicalGateway), vpnGateway=\(vpnGateway)")
                let chinaListURL = try awaitResult { try await self.chinaDatabase.ensureDatabase() }
                try self.writeAnchorFile(localInterface: routeInfo.localInterface,
                                          physicalGateway: routeInfo.physicalGateway,
                                          vpnInterface: vpnInterface,
                                          vpnGateway: vpnGateway,
                                          chinaListPath: chinaListURL.path)
                guard let runner = self.commandRunner else {
                    AppLogger.shared.log("Failed to get privileged command runner")
                    completion(.failure(SplittingTunnelError.authorizationUnavailable))
                    return
                }
                try runner.ensurePacketFilterEnabled()
                try runner.loadAnchor(self.anchorName, rulesPath: self.anchorFileURL.path)
                self.state = .enabled(localInterface: routeInfo.localInterface, vpnInterface: vpnInterface)
                AppLogger.shared.log("Splitting tunnel enabled successfully.")
                completion(.success(()))
            } catch {
                AppLogger.shared.log("Failed to enable splitting tunnel: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    private func runtimeInterfaceName(for service: SystemVPNService) -> String? {
        if let bsd = service.interfaceBSDName, !bsd.isEmpty {
            AppLogger.shared.log("Using known BSD name for service \(service.name): \(bsd)")
            return bsd
        }

        guard let store = SCDynamicStoreCreate(nil, "VPN Manager" as CFString, nil, nil) else {
            AppLogger.shared.log("Could not create SCDynamicStore for service \(service.name)")
            return nil
        }

        let ipv4Key = "State:/Network/Service/\(service.id)/IPv4" as CFString
        if let ipv4 = SCDynamicStoreCopyValue(store, ipv4Key) as? [String: Any],
           let interfaceName = ipv4["InterfaceName"] as? String,
           !interfaceName.isEmpty {
            AppLogger.shared.log("Resolved runtime interface for \(service.name) via IPv4 key: \(interfaceName)")
            return interfaceName
        }

        let pppKey = "State:/Network/Service/\(service.id)/PPP" as CFString
        if let ppp = SCDynamicStoreCopyValue(store, pppKey) as? [String: Any],
           let interfaceName = ppp["InterfaceName"] as? String,
           !interfaceName.isEmpty {
            AppLogger.shared.log("Resolved runtime interface for \(service.name) via PPP key: \(interfaceName)")
            return interfaceName
        }

        AppLogger.shared.log("Failed to resolve runtime interface for \(service.name).")
        return nil
    }

    func disable(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.isActiveState else {
                AppLogger.shared.log("Splitting tunnel is already disabled, nothing to do")
                completion(.success(()))
                return
            }

            do {
                AppLogger.shared.log("Disabling splitting tunnel.")
                guard let runner = self.commandRunner else {
                    AppLogger.shared.log("Failed to get privileged command runner for disabling")
                    throw SplittingTunnelError.authorizationUnavailable
                }
                try runner.flushAnchor(self.anchorName)
                self.state = .disabled
                AppLogger.shared.log("Splitting tunnel disabled.")
                completion(.success(()))
            } catch {
                AppLogger.shared.log("Failed to disable splitting tunnel: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    private func writeAnchorFile(localInterface: String,
                                 physicalGateway: String,
                                 vpnInterface: String,
                                 vpnGateway: String,
                                 chinaListPath: String) throws {
        let routeTarget = "(\(vpnInterface) \(vpnGateway))"
        AppLogger.shared.log("Writing PF anchor route-to target: \(routeTarget)")

        let localRouteTarget = "(\(localInterface) \(physicalGateway))"
        AppLogger.shared.log("Writing PF anchor local route-to target: \(localRouteTarget)")

        // Rules intentionally avoid ALTQ/queue directives so they can run on kernels
        // without traffic-shaping support (macOS disables ALTQ in shipping kernels).
        let anchor = """
        table <vpnmanager_cn> persist file \"\(chinaListPath)\"

        pass out quick on lo0 all keep state
        pass out quick on \(localInterface) route-to \(localRouteTarget) to <vpnmanager_cn> keep state
        pass out quick on \(localInterface) route-to \(routeTarget) from any to ! <vpnmanager_cn> keep state
        """
        let anchoredText = anchor.hasSuffix("\n") ? anchor : anchor + "\n"
        AppLogger.shared.log("Writing anchor file to: \(anchorFileURL.path)")
        try anchoredText.write(to: anchorFileURL, atomically: true, encoding: .utf8)
        AppLogger.shared.log("Wrote PF anchor file at \(anchorFileURL.path)")
    }

    private func resolveVPNGateway(for service: SystemVPNService, interfaceName: String) -> String? {
        AppLogger.shared.log("Resolving VPN gateway for service \(service.name) on interface \(interfaceName)")
        if let store = SCDynamicStoreCreate(nil, "VPN Manager" as CFString, nil, nil) {
            let ipv4Key = "State:/Network/Service/\(service.id)/IPv4" as CFString
            if let ipv4 = SCDynamicStoreCopyValue(store, ipv4Key) as? [String: Any],
               let candidate = Self.extractGateway(from: ipv4) {
                AppLogger.shared.log("Resolved VPN gateway via IPv4 state: \(candidate)")
                return candidate
            }

            let pppKey = "State:/Network/Service/\(service.id)/PPP" as CFString
            if let ppp = SCDynamicStoreCopyValue(store, pppKey) as? [String: Any],
               let dest = Self.firstString(from: ppp["DestAddress"]) ?? Self.firstString(from: ppp["CommRemoteAddress"]) {
                AppLogger.shared.log("Resolved VPN gateway via PPP state: \(dest)")
                return dest
            }
        }

        if let peer = inferGatewayViaIfconfig(interfaceName: interfaceName) {
            AppLogger.shared.log("Resolved VPN gateway via ifconfig: \(peer)")
            return peer
        }

        AppLogger.shared.log("Unable to resolve VPN gateway for interface \(interfaceName).")
        return nil
    }

    private static func extractGateway(from ipv4Dict: [String: Any]) -> String? {
        if let router = firstString(from: ipv4Dict["Router"]) {
            return router
        }
        if let dest = firstString(from: ipv4Dict["DestAddress"]) {
            return dest
        }
        if let peer = firstString(from: ipv4Dict["PeerAddress"]) {
            return peer
        }
        return nil
    }

    private static func firstString(from value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let array = value as? [String] {
            return array.first(where: { !$0.isEmpty })
        }
        return nil
    }

    private func inferGatewayViaIfconfig(interfaceName: String) -> String? {
        AppLogger.shared.log("Attempting to infer gateway via ifconfig for interface: \(interfaceName)")
        let process = Process()
        process.launchPath = "/sbin/ifconfig"
        process.arguments = [interfaceName]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLogger.shared.log("Failed to execute ifconfig for \(interfaceName): \(error.localizedDescription)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            AppLogger.shared.log("No output from ifconfig for interface \(interfaceName)")
            return nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let gateway = Self.parseGateway(fromIfconfigLine: line) {
                AppLogger.shared.log("Found gateway from ifconfig for \(interfaceName): \(gateway)")
                return gateway
            }
        }

        AppLogger.shared.log("Could not find gateway from ifconfig output for interface \(interfaceName)")
        return nil
    }

    private static func parseGateway(fromIfconfigLine line: String) -> String? {
        if let range = line.range(of: "-->") {
            let substring = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let gateway = substring.split(whereSeparator: { $0 == " " || $0 == "\t" }).first {
                return String(gateway)
            }
        }

        if line.contains("dest") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let destIndex = tokens.firstIndex(where: { $0 == "dest" || $0 == "destaddr" }),
               tokens.indices.contains(tokens.index(after: destIndex)) {
                return String(tokens[tokens.index(after: destIndex)])
            }
        }

        return nil
    }
}

private extension SplittingTunnelManager {
    static func resolveWorkDirectory() -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []

        let home = fm.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Library/Logs/VPN Manager/SplittingTunnel", isDirectory: true))

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("VPN Manager/SplittingTunnel", isDirectory: true))
        }

        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("VPNManager/SplittingTunnel", isDirectory: true))

        for candidate in candidates {
            if ensureWritableDirectory(candidate) {
                return candidate
            }
        }

        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("VPNManager/SplittingTunnel", isDirectory: true)
        _ = ensureWritableDirectory(fallback)
        return fallback
    }

    static func ensureWritableDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let probeURL = directory.appendingPathComponent(".probe", isDirectory: false)
            try "probe".data(using: .utf8)?.write(to: probeURL, options: .atomic)
            try fm.removeItem(at: probeURL)
            return true
        } catch {
            AppLogger.shared.log("Cannot use directory \(directory.path) for splitting tunnel data: \(error)")
            return false
        }
    }
}

private func awaitResult<T>(_ operation: @escaping () async throws -> T) throws -> T {
    var result: Result<T, Error>?
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let value = try await operation()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    case .none:
        throw SplittingTunnelError.commandFailed("Unexpected async completion state.")
    }
}
