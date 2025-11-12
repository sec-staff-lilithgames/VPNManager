//
//  AppLogger.swift
//  VPN Manager
//
//  Created by Siberia_1337 on 11/11/25.
//

import Foundation

final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "com.vpnmanager.logger", qos: .utility)
    private let logDirectory: URL
    private let logFileURL: URL

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let directories = AppLogger.logDirectoryCandidates()
        var resolvedDirectory = directories.last!

        for candidate in directories {
            if AppLogger.prepareDirectory(candidate) {
                resolvedDirectory = candidate
                break
            }
        }

        logDirectory = resolvedDirectory
        logFileURL = logDirectory.appendingPathComponent("vpn_manager.log", isDirectory: false)

        queue.async {
            self.writeLine("Logger initialized at path: \(self.logFileURL.path)")
        }
    }

    func log(_ message: String) {
        queue.async {
            self.writeLine(message)
        }
    }

    func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: self.logFileURL)
        }
    }

    func logFilePath() -> String {
        return logFileURL.path
    }
}

private extension AppLogger {
    func writeLine(_ message: String) {
        let timestamp = Self.dateFormatter.string(from: Date())
        let formattedMessage = "[\(timestamp)] \(message)\n"
        guard let data = formattedMessage.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                print("Failed to append log: \(error)")
            }
        } else {
            do {
                try data.write(to: logFileURL, options: .atomic)
            } catch {
                print("Failed to write log: \(error)")
            }
        }
    }

    static func logDirectoryCandidates() -> [URL] {
        var candidates: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Library/Logs/VPN Manager", isDirectory: true))

        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("VPN Manager/Logs", isDirectory: true))
        }

        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("VPNManagerLogs", isDirectory: true))

        return candidates
    }

    static func prepareDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let probeURL = directory.appendingPathComponent(".probe", isDirectory: false)
            try "probe".data(using: .utf8)?.write(to: probeURL, options: .atomic)
            try fm.removeItem(at: probeURL)
            return true
        } catch {
            print("Failed to prepare log directory \(directory.path): \(error)")
            return false
        }
    }
}
