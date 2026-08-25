import Foundation

public enum CodexTaskStatus: String, Codable, Equatable, Sendable {
    case registered
    case running
    case waitingForApproval
    case completed
    case failedOrInterrupted
    case stale
    case ended

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "awaitingStatus":
            self = .running
        case "interrupted":
            self = .failedOrInterrupted
        default:
            self = CodexTaskStatus(rawValue: rawValue) ?? .failedOrInterrupted
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PreviewMode: String, Codable, Equatable, Sendable {
    case projectAndPreview
    case projectOnly
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var previewMode: PreviewMode
    public var statusConfirmationTimeout: TimeInterval
    public var staleTimeout: TimeInterval
    public var recentRetention: TimeInterval
    public var maxRecentCompletions: Int
    public var completionSneakPeekEnabled: Bool
    public var approvalReminderEnabled: Bool

    public init(
        previewMode: PreviewMode = .projectAndPreview,
        statusConfirmationTimeout: TimeInterval = 5 * 60,
        staleTimeout: TimeInterval = 30 * 60,
        recentRetention: TimeInterval = 7 * 24 * 60 * 60,
        maxRecentCompletions: Int = 100,
        completionSneakPeekEnabled: Bool = true,
        approvalReminderEnabled: Bool = true
    ) {
        self.previewMode = previewMode
        self.statusConfirmationTimeout = statusConfirmationTimeout
        self.staleTimeout = staleTimeout
        self.recentRetention = recentRetention
        self.maxRecentCompletions = max(1, maxRecentCompletions)
        self.completionSneakPeekEnabled = completionSneakPeekEnabled
        self.approvalReminderEnabled = approvalReminderEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case previewMode
        case statusConfirmationTimeout
        case staleTimeout
        case recentRetention
        case maxRecentCompletions
        case completionSneakPeekEnabled
        case approvalReminderEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            previewMode: try container.decodeIfPresent(PreviewMode.self, forKey: .previewMode)
                ?? .projectAndPreview,
            statusConfirmationTimeout: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .statusConfirmationTimeout
            ) ?? 5 * 60,
            staleTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .staleTimeout)
                ?? 30 * 60,
            recentRetention: try container.decodeIfPresent(TimeInterval.self, forKey: .recentRetention)
                ?? 7 * 24 * 60 * 60,
            maxRecentCompletions: try container.decodeIfPresent(Int.self, forKey: .maxRecentCompletions)
                ?? 100,
            completionSneakPeekEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .completionSneakPeekEnabled
            ) ?? true,
            approvalReminderEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .approvalReminderEnabled
            ) ?? true
        )
    }
}

public struct CodexTaskRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var sessionID: String
    public var currentTurnID: String?
    public var cwd: String?
    public var projectName: String
    public var promptPreview: String?
    public var resultPreview: String?
    public var approvalPreview: String?
    public var toolName: String?
    public var status: CodexTaskStatus
    public var startedAt: Date?
    public var lastActivityAt: Date
    public var completedAt: Date?
    public var endedAt: Date?
    public var model: String?
    public var lastEventID: UUID?
    public var lastEventName: String?

    public init(
        sessionID: String,
        currentTurnID: String? = nil,
        cwd: String? = nil,
        projectName: String = "Codex 会话",
        promptPreview: String? = nil,
        resultPreview: String? = nil,
        approvalPreview: String? = nil,
        toolName: String? = nil,
        status: CodexTaskStatus = .registered,
        startedAt: Date? = nil,
        lastActivityAt: Date,
        completedAt: Date? = nil,
        endedAt: Date? = nil,
        model: String? = nil,
        lastEventID: UUID? = nil,
        lastEventName: String? = nil
    ) {
        self.id = sessionID
        self.sessionID = sessionID
        self.currentTurnID = currentTurnID
        self.cwd = cwd
        self.projectName = projectName
        self.promptPreview = promptPreview
        self.resultPreview = resultPreview
        self.approvalPreview = approvalPreview
        self.toolName = toolName
        self.status = status
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.completedAt = completedAt
        self.endedAt = endedAt
        self.model = model
        self.lastEventID = lastEventID
        self.lastEventName = lastEventName
    }
}

public enum CodexTaskLiveness: Equatable, Sendable {
    case fresh
    case statusUncertain
    case stale
}

public struct CodexTaskLivenessPolicy: Equatable, Sendable {
    public let statusConfirmationTimeout: TimeInterval
    public let staleTimeout: TimeInterval

    public init(
        statusConfirmationTimeout: TimeInterval = 5 * 60,
        staleTimeout: TimeInterval = 30 * 60
    ) {
        self.statusConfirmationTimeout = max(0, statusConfirmationTimeout)
        self.staleTimeout = max(self.statusConfirmationTimeout, staleTimeout)
    }

    public init(preferences: AppPreferences) {
        self.init(
            statusConfirmationTimeout: preferences.statusConfirmationTimeout,
            staleTimeout: preferences.staleTimeout
        )
    }

    public func liveness(for task: CodexTaskRecord, now: Date) -> CodexTaskLiveness {
        guard task.status == .running else { return .fresh }
        let silenceDuration = max(0, now.timeIntervalSince(task.lastActivityAt))
        if silenceDuration >= staleTimeout {
            return .stale
        }
        if silenceDuration >= statusConfirmationTimeout {
            return .statusUncertain
        }
        return .fresh
    }
}

public extension CodexTaskRecord {
    var wasManuallyInterrupted: Bool {
        status == .failedOrInterrupted && lastEventName == "ManualInterruption"
    }
}

public struct CodexCompletionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let projectName: String
    public let promptPreview: String?
    public let resultPreview: String?
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: String,
        projectName: String,
        promptPreview: String?,
        resultPreview: String?,
        completedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectName = projectName
        self.promptPreview = promptPreview
        self.resultPreview = resultPreview
        self.completedAt = completedAt
    }
}

public struct CodexTaskStoreSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var savedAt: Date
    public var tasks: [CodexTaskRecord]
    public var recentCompletions: [CodexCompletionRecord]
    public var acknowledgedCompletionIDs: [UUID]?
    public var presentedCompletionIDs: [UUID]?
    public var processedEventIDs: [UUID]

    public init(
        schemaVersion: Int = 1,
        savedAt: Date = Date(),
        tasks: [CodexTaskRecord] = [],
        recentCompletions: [CodexCompletionRecord] = [],
        acknowledgedCompletionIDs: [UUID] = [],
        presentedCompletionIDs: [UUID] = [],
        processedEventIDs: [UUID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.tasks = tasks
        self.recentCompletions = recentCompletions
        self.acknowledgedCompletionIDs = acknowledgedCompletionIDs
        self.presentedCompletionIDs = presentedCompletionIDs
        self.processedEventIDs = processedEventIDs
    }

    public var unacknowledgedCompletions: [CodexCompletionRecord] {
        let acknowledged = Set(acknowledgedCompletionIDs ?? [])
        let unreadSessionIDs = Set(
            recentCompletions
                .filter { !acknowledged.contains($0.id) }
                .map(\.sessionID)
        )
        let latestCompletionIDs = Set(latestRecentCompletions().map(\.id))
        return recentCompletions.filter {
            latestCompletionIDs.contains($0.id)
                && unreadSessionIDs.contains($0.sessionID)
        }
    }

    public func latestRecentCompletions(
        excludingSessionIDs excludedSessionIDs: Set<String> = []
    ) -> [CodexCompletionRecord] {
        var latestBySession: [String: CodexCompletionRecord] = [:]
        for completion in recentCompletions where !excludedSessionIDs.contains(completion.sessionID) {
            if let current = latestBySession[completion.sessionID],
               current.completedAt >= completion.completedAt {
                continue
            }
            latestBySession[completion.sessionID] = completion
        }
        return latestBySession.values.sorted { $0.completedAt > $1.completedAt }
    }

    public static var empty: CodexTaskStoreSnapshot { CodexTaskStoreSnapshot() }
}
