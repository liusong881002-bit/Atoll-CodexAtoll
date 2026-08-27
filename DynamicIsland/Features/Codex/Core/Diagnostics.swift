import Foundation
import os.log

enum CodexActivityTrayDiagnostics {
    private static let activityLog = OSLog(
        subsystem: "com.ebullioscopic.Atoll",
        category: "codex.activity-tray"
    )

    static func log(
        event: String,
        screenKey: String,
        presentationID: UUID? = nil,
        completionCount: Int,
        detail: String? = nil
    ) {
        let message = [
            "event=\(event)",
            "screen=\(diagnosticScreenToken(for: screenKey))",
            "presentation=\(presentationID?.uuidString ?? "none")",
            "completion_count=\(completionCount)",
            detail,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        os_log("%{public}@", log: activityLog, type: .info, message)
    }

    private static func diagnosticScreenToken(for screenKey: String) -> String {
        switch screenKey {
        case "all": return "all"
        case "__default__": return "default"
        default:
            return "screen-\(String(UInt(bitPattern: screenKey.hashValue), radix: 16))"
        }
    }
}

enum CodexSneakPeekDiagnostics {
    private static let presentationLog = OSLog(
        subsystem: "com.ebullioscopic.Atoll",
        category: "codex.sneak-peek"
    )

    static func log(event: String, phase: String?, detail: String? = nil) {
        let message = [
            "event=\(event)",
            "phase=\(phase ?? "none")",
            detail,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        os_log("%{public}@", log: presentationLog, type: .info, message)
    }
}

public struct CodexDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let activeSessionCount: Int
    public let runningCount: Int
    public let statusUncertainCount: Int
    public let waitingCount: Int
    public let staleCount: Int
    public let recentCompletionCount: Int
    public let inboxPendingCount: Int
    public let failedEventCount: Int
    public let lastEventAt: Date?
    public let helperPath: String?
    public let helperVersion: String?

    public init(
        generatedAt: Date = Date(),
        activeSessionCount: Int,
        runningCount: Int,
        statusUncertainCount: Int = 0,
        waitingCount: Int,
        staleCount: Int,
        recentCompletionCount: Int,
        inboxPendingCount: Int,
        failedEventCount: Int,
        lastEventAt: Date?,
        helperPath: String? = nil,
        helperVersion: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.activeSessionCount = activeSessionCount
        self.runningCount = runningCount
        self.statusUncertainCount = statusUncertainCount
        self.waitingCount = waitingCount
        self.staleCount = staleCount
        self.recentCompletionCount = recentCompletionCount
        self.inboxPendingCount = inboxPendingCount
        self.failedEventCount = failedEventCount
        self.lastEventAt = lastEventAt
        self.helperPath = helperPath
        self.helperVersion = helperVersion
    }

    public func redactedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct DiagnosticsCollector {
    public let paths: AppPaths
    private let fileManager: FileManager

    public init(paths: AppPaths = .default, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func collect(
        snapshot: CodexTaskStoreSnapshot,
        generatedAt: Date = Date(),
        helperPath: String? = nil,
        helperVersion: String? = nil,
        livenessPolicy: CodexTaskLivenessPolicy = .init()
    ) throws -> CodexDiagnosticsSnapshot {
        let pending = try countJSONFiles(in: paths.inbox)
        let failed = try countJSONFiles(in: paths.failed)
        let waiting = snapshot.tasks.filter { $0.status == .waitingForApproval }
        let rawRunning = snapshot.tasks.filter { $0.status == .running }
        let running = rawRunning.filter {
            livenessPolicy.liveness(for: $0, now: generatedAt) == .fresh
        }
        let statusUncertain = rawRunning.filter {
            livenessPolicy.liveness(for: $0, now: generatedAt) == .statusUncertain
        }
        let derivedStale = rawRunning.filter {
            livenessPolicy.liveness(for: $0, now: generatedAt) == .stale
        }
        return CodexDiagnosticsSnapshot(
            generatedAt: generatedAt,
            activeSessionCount: running.count + waiting.count,
            runningCount: running.count,
            statusUncertainCount: statusUncertain.count,
            waitingCount: waiting.count,
            staleCount: snapshot.tasks.filter { $0.status == .stale }.count + derivedStale.count,
            recentCompletionCount: snapshot.recentCompletions.count,
            inboxPendingCount: pending,
            failedEventCount: failed,
            lastEventAt: snapshot.tasks.map(\.lastActivityAt).max(),
            helperPath: helperPath,
            helperVersion: helperVersion
        )
    }

    private func countJSONFiles(in directory: URL) throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.count
    }
}
