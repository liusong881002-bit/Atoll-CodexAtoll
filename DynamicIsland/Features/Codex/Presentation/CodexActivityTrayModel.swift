import CoreGraphics
import Foundation

public enum CodexActivityBucket: String, CaseIterable, Equatable, Hashable, Sendable {
    case needsAttention
    case statusUncertain
    case blocked
    case unreadCompleted
    case running
    case readHistory

    public var title: String {
        switch self {
        case .needsAttention: return "需要处理"
        case .statusUncertain: return "状态待确认"
        case .blocked: return "异常 / 可能失联"
        case .unreadCompleted: return "最新完成"
        case .running: return "进行中"
        case .readHistory: return "历史记录"
        }
    }

    public var symbolName: String {
        switch self {
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .statusUncertain: return "questionmark.circle.fill"
        case .blocked: return "bolt.trianglebadge.exclamationmark.fill"
        case .unreadCompleted: return "checkmark.circle.fill"
        case .running: return "terminal.fill"
        case .readHistory: return "checkmark.circle"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .needsAttention: return 0
        case .statusUncertain: return 1
        case .blocked: return 2
        case .unreadCompleted: return 3
        case .running: return 4
        case .readHistory: return 5
        }
    }
}

public struct CodexActivityTrayPreferences: Equatable, Sendable {
    public var pinnedProjectNames: Set<String>
    public var ignoredSessionIDs: Set<String>
    public var showContentPreviews: Bool
    public var historyRetention: TimeInterval

    public init(
        pinnedProjectNames: Set<String> = [],
        ignoredSessionIDs: Set<String> = [],
        showContentPreviews: Bool = true,
        historyRetention: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.pinnedProjectNames = pinnedProjectNames
        self.ignoredSessionIDs = ignoredSessionIDs
        self.showContentPreviews = showContentPreviews
        self.historyRetention = historyRetention
    }
}

public struct CodexActivityTrayItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let projectName: String
    public let title: String
    public let statusText: String
    public let detailText: String
    public let nextAction: String
    public let bucket: CodexActivityBucket
    public let lastActivityAt: Date
    public let completedAt: Date?
    public let completionID: UUID?
    public let isRead: Bool
    public let canMarkInterrupted: Bool

    public init(
        id: String,
        sessionID: String,
        projectName: String,
        title: String,
        statusText: String,
        detailText: String,
        nextAction: String,
        bucket: CodexActivityBucket,
        lastActivityAt: Date,
        completedAt: Date? = nil,
        completionID: UUID? = nil,
        isRead: Bool = false,
        canMarkInterrupted: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectName = projectName
        self.title = title
        self.statusText = statusText
        self.detailText = detailText
        self.nextAction = nextAction
        self.bucket = bucket
        self.lastActivityAt = lastActivityAt
        self.completedAt = completedAt
        self.completionID = completionID
        self.isRead = isRead
        self.canMarkInterrupted = canMarkInterrupted
    }
}

public struct CodexActivityTrayProjectGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let projectName: String
    public let items: [CodexActivityTrayItem]
    public let isPinned: Bool
    public let isCollapsed: Bool

    public init(
        projectName: String,
        items: [CodexActivityTrayItem],
        isPinned: Bool,
        isCollapsed: Bool
    ) {
        self.id = projectName
        self.projectName = projectName
        self.items = items
        self.isPinned = isPinned
        self.isCollapsed = isCollapsed
    }
}

public struct CodexActivityTrayBucketGroup: Equatable, Identifiable, Sendable {
    public let id: CodexActivityBucket
    public let bucket: CodexActivityBucket
    public let groups: [CodexActivityTrayProjectGroup]

    public init(bucket: CodexActivityBucket, groups: [CodexActivityTrayProjectGroup]) {
        self.id = bucket
        self.bucket = bucket
        self.groups = groups
    }

    public var itemCount: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    public var items: [CodexActivityTrayItem] {
        groups
            .flatMap(\.items)
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func limited(to limit: Int) -> CodexActivityTrayBucketGroup {
        guard limit >= 0, itemCount > limit else { return self }
        let allowedIDs = Set(items.prefix(limit).map(\.id))
        let limitedGroups = groups.compactMap { group -> CodexActivityTrayProjectGroup? in
            let limitedItems = group.items.filter { allowedIDs.contains($0.id) }
            guard !limitedItems.isEmpty else { return nil }
            return CodexActivityTrayProjectGroup(
                projectName: group.projectName,
                items: limitedItems,
                isPinned: group.isPinned,
                isCollapsed: group.isCollapsed
            )
        }
        return CodexActivityTrayBucketGroup(bucket: bucket, groups: limitedGroups)
    }
}

public struct CodexActivityTrayModel: Equatable, Sendable {
    public let buckets: [CodexActivityTrayBucketGroup]
    public let ignoredItems: [CodexActivityTrayItem]

    public init(
        buckets: [CodexActivityTrayBucketGroup],
        ignoredItems: [CodexActivityTrayItem] = []
    ) {
        self.buckets = buckets
        self.ignoredItems = ignoredItems
    }

    public var visibleItemCount: Int {
        buckets.reduce(0) { $0 + $1.itemCount }
    }
}

struct CodexActivityTrayExpansionPolicy {
    static func defaultCollapsedBuckets() -> Set<CodexActivityBucket> {
        [.readHistory]
    }

    static func isExpandedByDefault(_ bucket: CodexActivityBucket) -> Bool {
        bucket != .readHistory
    }
}

struct CodexActivityTrayVisibilityPolicy {
    static func visibleItemIDs(
        itemFrames: [String: CGRect],
        viewportBounds: CGRect,
        minimumVisibleFraction: CGFloat = 0.5
    ) -> Set<String> {
        let threshold = min(max(minimumVisibleFraction, 0), 1)
        return Set(itemFrames.compactMap { itemID, frame in
            guard frame.width > 0, frame.height > 0 else { return nil }
            let intersection = frame.intersection(viewportBounds)
            guard !intersection.isNull, intersection.width > 0 else { return nil }
            return intersection.height / frame.height >= threshold ? itemID : nil
        })
    }
}

struct CodexActivityTrayPresentationLifecycle: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case pending
        case begun
        case invalidated
    }

    let id: UUID
    private var phase: Phase = .pending

    init(id: UUID = UUID()) {
        self.id = id
    }

    mutating func beginIfNeeded(using begin: (UUID) -> Bool) -> Bool {
        switch phase {
        case .begun:
            return true
        case .invalidated:
            return false
        case .pending:
            guard begin(id) else { return false }
            phase = .begun
            return true
        }
    }

    mutating func invalidate() -> UUID? {
        let presentationID = phase == .begun ? id : nil
        phase = .invalidated
        return presentationID
    }
}

struct CodexActivityTrayPresentationRegistry: Equatable, Sendable {
    private static let retiredTokenLimitPerScreen = 32

    struct BeginResult: Equatable, Sendable {
        let presentationID: UUID
        let exposedCompletionIDs: Set<UUID>
    }

    private struct Presentation: Equatable, Sendable {
        let id: UUID
        var exposedCompletionIDs: Set<UUID>
    }

    private var presentationsByScreen: [String: Presentation] = [:]
    private var retiredPresentationIDsByScreen: [String: [UUID]] = [:]

    @discardableResult
    mutating func beginPresentation(
        screenKey: String,
        presentationID: UUID
    ) -> BeginResult? {
        guard retiredPresentationIDsByScreen[screenKey]?.contains(presentationID) != true else {
            return nil
        }
        if let presentation = presentationsByScreen[screenKey] {
            guard presentation.id == presentationID else { return nil }
            return BeginResult(
                presentationID: presentation.id,
                exposedCompletionIDs: presentation.exposedCompletionIDs
            )
        }

        let presentation = Presentation(id: presentationID, exposedCompletionIDs: [])
        presentationsByScreen[screenKey] = presentation
        return BeginResult(
            presentationID: presentation.id,
            exposedCompletionIDs: presentation.exposedCompletionIDs
        )
    }

    @discardableResult
    mutating func updateVisibility(
        screenKey: String,
        presentationID: UUID,
        contentSignature: [UUID],
        visibleCompletionIDs: Set<UUID>
    ) -> Set<UUID>? {
        let eligibleCompletionIDs = visibleCompletionIDs.intersection(contentSignature)
        guard var presentation = presentationsByScreen[screenKey],
              presentation.id == presentationID else { return nil }
        let newlyExposedCompletionIDs = eligibleCompletionIDs.subtracting(
            presentation.exposedCompletionIDs
        )
        presentation.exposedCompletionIDs.formUnion(eligibleCompletionIDs)
        presentationsByScreen[screenKey] = presentation
        return newlyExposedCompletionIDs
    }

    mutating func finishPresentation(
        screenKey: String,
        presentationID: UUID? = nil
    ) -> Set<UUID> {
        guard let presentation = presentationsByScreen[screenKey],
              presentationID == nil || presentation.id == presentationID else { return [] }
        presentationsByScreen.removeValue(forKey: screenKey)
        retirePresentationID(presentation.id, screenKey: screenKey)
        return presentation.exposedCompletionIDs
    }

    func presentationID(screenKey: String) -> UUID? {
        presentationsByScreen[screenKey]?.id
    }

    var activeScreenKeys: [String] {
        Array(presentationsByScreen.keys)
    }

    private mutating func retirePresentationID(_ presentationID: UUID, screenKey: String) {
        var retiredIDs = retiredPresentationIDsByScreen[screenKey, default: []]
        guard !retiredIDs.contains(presentationID) else { return }
        retiredIDs.append(presentationID)
        if retiredIDs.count > Self.retiredTokenLimitPerScreen {
            retiredIDs.removeFirst(retiredIDs.count - Self.retiredTokenLimitPerScreen)
        }
        retiredPresentationIDsByScreen[screenKey] = retiredIDs
    }
}

public struct CodexActivityTrayBuilder: Sendable {
    public init() {}

    public func build(
        from snapshot: CodexTaskStoreSnapshot,
        preferences: CodexActivityTrayPreferences = .init(),
        now: Date = Date(),
        livenessPolicy: CodexTaskLivenessPolicy = .init()
    ) -> CodexActivityTrayModel {
        var itemsByBucket: [CodexActivityBucket: [CodexActivityTrayItem]] = [:]
        var currentSessionIDs: Set<String> = []

        for task in snapshot.tasks {
            guard let bucket = bucket(
                for: task,
                now: now,
                preferences: preferences,
                livenessPolicy: livenessPolicy
            ) else { continue }
            currentSessionIDs.insert(task.sessionID)
            let item = makeItem(
                for: task,
                bucket: bucket,
                showContentPreviews: preferences.showContentPreviews,
                now: now
            )
            itemsByBucket[bucket, default: []].append(item)
        }

        let acknowledgedCompletionIDs = Set(snapshot.acknowledgedCompletionIDs ?? [])
        let unacknowledgedSessionIDs = Set(
            snapshot.recentCompletions
                .filter { !acknowledgedCompletionIDs.contains($0.id) }
                .map(\.sessionID)
        )
        let recentCompletions = snapshot.latestRecentCompletions(
            excludingSessionIDs: currentSessionIDs
        )
        for completion in recentCompletions {
            let isRead = !unacknowledgedSessionIDs.contains(completion.sessionID)
            let item = makeItem(
                for: completion,
                bucket: isRead ? .readHistory : .unreadCompleted,
                isRead: isRead,
                showContentPreviews: preferences.showContentPreviews
            )
            itemsByBucket[item.bucket, default: []].append(item)
        }

        // Older builds retained completed tasks in `tasks` but pruned the
        // separate completion summaries after ten minutes. Recover those
        // records for display when no newer completion summary exists.
        let recentSessionIDs = Set(recentCompletions.map(\.sessionID))
        let historyCutoff = now.addingTimeInterval(-preferences.historyRetention)
        for task in snapshot.tasks {
            guard (task.status == .completed || task.status == .ended),
                  let completedAt = task.completedAt,
                  completedAt > historyCutoff,
                  !recentSessionIDs.contains(task.sessionID) else { continue }
            itemsByBucket[.readHistory, default: []].append(
                makeItem(
                    for: task,
                    bucket: .readHistory,
                    isRead: true,
                    showContentPreviews: preferences.showContentPreviews,
                    now: now
                )
            )
        }

        let ignoredIDs = preferences.ignoredSessionIDs
        let ignoredItems = itemsByBucket.values
            .flatMap { $0 }
            .filter { ignoredIDs.contains($0.sessionID) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }

        let buckets = CodexActivityBucket.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { bucket -> CodexActivityTrayBucketGroup? in
                let items = itemsByBucket[bucket, default: []]
                    .filter { !ignoredIDs.contains($0.sessionID) }
                    .sorted { $0.lastActivityAt > $1.lastActivityAt }
                guard !items.isEmpty else { return nil }
                return CodexActivityTrayBucketGroup(
                    bucket: bucket,
                    groups: projectGroups(
                        from: items,
                        preferences: preferences
                    )
                )
            }

        return CodexActivityTrayModel(buckets: buckets, ignoredItems: ignoredItems)
    }

    private func bucket(
        for task: CodexTaskRecord,
        now: Date,
        preferences: CodexActivityTrayPreferences,
        livenessPolicy: CodexTaskLivenessPolicy
    ) -> CodexActivityBucket? {
        if task.wasManuallyInterrupted {
            guard let endedAt = task.endedAt,
                  endedAt > now.addingTimeInterval(-preferences.historyRetention) else {
                return nil
            }
            return .readHistory
        }

        switch task.status {
        case .waitingForApproval:
            return .needsAttention
        case .failedOrInterrupted, .stale:
            return .blocked
        case .running:
            switch livenessPolicy.liveness(for: task, now: now) {
            case .fresh:
                return .running
            case .statusUncertain:
                return .statusUncertain
            case .stale:
                return .blocked
            }
        case .registered, .completed, .ended:
            return nil
        }
    }

    private func projectGroups(
        from items: [CodexActivityTrayItem],
        preferences: CodexActivityTrayPreferences
    ) -> [CodexActivityTrayProjectGroup] {
        let grouped = Dictionary(grouping: items, by: \.projectName)
        return grouped
            .map { projectName, projectItems in
                CodexActivityTrayProjectGroup(
                    projectName: projectName,
                    items: projectItems.sorted { $0.lastActivityAt > $1.lastActivityAt },
                    isPinned: preferences.pinnedProjectNames.contains(projectName),
                    isCollapsed: false
                )
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                let leftDate = lhs.items.map(\.lastActivityAt).max() ?? .distantPast
                let rightDate = rhs.items.map(\.lastActivityAt).max() ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
            }
    }

    private func makeItem(
        for task: CodexTaskRecord,
        bucket: CodexActivityBucket,
        isRead: Bool = false,
        showContentPreviews: Bool,
        now: Date
    ) -> CodexActivityTrayItem {
        let title = showContentPreviews
            ? PreviewSanitizer.sanitizePrompt(task.promptPreview ?? task.approvalPreview, maxLength: 36)
            ?? PreviewSanitizer.sanitize(task.projectName, maxLength: 36)
            ?? "Codex 会话"
            : PreviewSanitizer.sanitize(task.projectName, maxLength: 36) ?? "Codex 会话"
        let detail: String
        let nextAction: String
        let statusText: String

        switch bucket {
        case .needsAttention:
            detail = showContentPreviews
                ? PreviewSanitizer.sanitize(task.approvalPreview ?? task.toolName, maxLength: 72)
                    ?? "需要你的决定"
                : "需要你的决定"
            nextAction = "打开 Codex 处理"
            statusText = durationStatus(for: task, label: "等待批准", now: now)
        case .statusUncertain:
            detail = lastSignalStatus(for: task, now: now)
            nextAction = "打开 Codex 检查"
            statusText = "状态待确认"
        case .blocked:
            let isPossiblyDisconnected = task.status == .stale || task.status == .running
            detail = isPossiblyDisconnected ? lastSignalStatus(for: task, now: now) : "任务已中断"
            nextAction = "检查会话"
            statusText = isPossiblyDisconnected ? "可能失联" : "已中断"
        case .running:
            detail = showContentPreviews
                ? PreviewSanitizer.sanitize(task.toolName, maxLength: 72) ?? "Codex 正在执行"
                : "Codex 正在执行"
            nextAction = "继续等待"
            statusText = durationStatus(for: task, label: "运行中", now: now)
        case .unreadCompleted, .readHistory:
            if task.wasManuallyInterrupted {
                detail = "已由你标记为中断"
                nextAction = "打开 Codex 查看"
                statusText = "已中断"
                break
            }
            detail = showContentPreviews
                ? PreviewSanitizer.sanitize(task.resultPreview, maxLength: 72) ?? "任务已完成"
                : "任务已完成"
            nextAction = "查看完成结果"
            statusText = "已完成"
        }

        return CodexActivityTrayItem(
            id: task.sessionID,
            sessionID: task.sessionID,
            projectName: task.projectName,
            title: title,
            statusText: statusText,
            detailText: detail,
            nextAction: nextAction,
            bucket: bucket,
            lastActivityAt: task.endedAt ?? task.completedAt ?? task.lastActivityAt,
            completedAt: task.completedAt,
            isRead: isRead || bucket == .readHistory,
            canMarkInterrupted: bucket == .statusUncertain
                || (bucket == .blocked && (task.status == .running || task.status == .stale))
        )
    }

    private func makeItem(
        for completion: CodexCompletionRecord,
        bucket: CodexActivityBucket,
        isRead: Bool,
        showContentPreviews: Bool
    ) -> CodexActivityTrayItem {
        let title = showContentPreviews
            ? PreviewSanitizer.sanitizePrompt(completion.promptPreview, maxLength: 36)
            ?? PreviewSanitizer.sanitize(completion.projectName, maxLength: 36)
            ?? "Codex 会话"
            : PreviewSanitizer.sanitize(completion.projectName, maxLength: 36) ?? "Codex 会话"
        let detail = showContentPreviews
            ? PreviewSanitizer.sanitize(completion.resultPreview, maxLength: 72) ?? "任务已完成"
            : "任务已完成"
        return CodexActivityTrayItem(
            id: "completion-\(completion.id.uuidString)",
            sessionID: completion.sessionID,
            projectName: completion.projectName,
            title: title,
            statusText: "已完成",
            detailText: detail,
            nextAction: "查看完成结果",
            bucket: bucket,
            lastActivityAt: completion.completedAt,
            completedAt: completion.completedAt,
            completionID: completion.id,
            isRead: isRead
        )
    }

    private func durationStatus(for task: CodexTaskRecord, label: String, now: Date) -> String {
        guard let startedAt = task.startedAt else { return label }
        let total = max(0, Int(now.timeIntervalSince(startedAt)))
        if total >= 60 * 60 {
            return String(
                format: "%@ · %02d:%02d:%02d",
                label,
                total / 3_600,
                (total % 3_600) / 60,
                total % 60
            )
        }
        return String(format: "%@ · %02d:%02d", label, total / 60, total % 60)
    }

    private func lastSignalStatus(for task: CodexTaskRecord, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(task.lastActivityAt)))
        let minutes = max(1, elapsed / 60)
        return "最后信号 \(minutes) 分钟前"
    }
}
