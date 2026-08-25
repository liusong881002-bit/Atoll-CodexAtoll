import Foundation

@main
struct CodexStatusReconciliationTests {
    static func main() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = "disconnected-session"
        var store = CodexTaskStore(
            snapshot: CodexTaskStoreSnapshot(
                savedAt: startedAt,
                tasks: [
                    CodexTaskRecord(
                        sessionID: sessionID,
                        currentTurnID: "turn-1",
                        projectName: "Atoll-CodexAtoll",
                        promptPreview: "复现断流后的托盘状态",
                        status: .running,
                        startedAt: startedAt,
                        lastActivityAt: startedAt
                    )
                ]
            ),
            preferences: AppPreferences(
                statusConfirmationTimeout: 5 * 60,
                staleTimeout: 30 * 60
            )
        )

        _ = store.performMaintenance(now: startedAt.addingTimeInterval(5 * 60 - 1))
        try expect(
            store.snapshot.tasks.first?.status == .running,
            "a recent Hook remains running before the confirmation threshold"
        )
        try expect(
            store.markInterrupted(
                sessionID: sessionID,
                now: startedAt.addingTimeInterval(5 * 60 - 1)
            ).isEmpty,
            "a fresh task cannot be manually marked interrupted"
        )

        let confirmationTime = startedAt.addingTimeInterval(5 * 60)
        _ = store.performMaintenance(now: confirmationTime)
        try expect(
            store.snapshot.tasks.first?.status == .running,
            "status confirmation remains a derived presentation state instead of a persisted enum"
        )

        let confirmationTray = CodexActivityTrayBuilder().build(
            from: store.snapshot,
            now: startedAt.addingTimeInterval(8 * 60)
        )
        let confirmationItem = confirmationTray.buckets
            .first(where: { $0.bucket == .statusUncertain })?
            .items
            .first
        try expect(
            confirmationItem?.statusText == "状态待确认"
                && confirmationItem?.detailText == "最后信号 8 分钟前"
                && confirmationItem?.canMarkInterrupted == true,
            "a silent task shows its last Hook age and exposes the interruption action"
        )
        try expect(
            confirmationTray.buckets.contains(where: { $0.bucket == .running }) == false,
            "a task awaiting confirmation no longer contributes to the running bucket"
        )

        let customPolicy = CodexTaskLivenessPolicy(
            statusConfirmationTimeout: 10 * 60,
            staleTimeout: 20 * 60
        )
        let customPolicyTray = CodexActivityTrayBuilder().build(
            from: store.snapshot,
            now: startedAt.addingTimeInterval(8 * 60),
            livenessPolicy: customPolicy
        )
        try expect(
            customPolicyTray.buckets.first?.bucket == .running,
            "presentation uses the injected runtime liveness policy instead of hard-coded thresholds"
        )

        var uncertainStore = store
        _ = uncertainStore.markInterrupted(
            sessionID: sessionID,
            now: startedAt.addingTimeInterval(8 * 60)
        )
        try expect(
            uncertainStore.snapshot.tasks.first?.wasManuallyInterrupted == true,
            "a task in the derived confirmation window can be manually interrupted"
        )

        let persistedAtConfirmation = try JSONEncoder().encode(store.snapshot)
        let persistedText = String(decoding: persistedAtConfirmation, as: UTF8.self)
        try expect(
            persistedText.contains("awaitingStatus") == false
                && persistedText.contains("interrupted\"") == false,
            "derived and manual presentation states do not introduce unknown persisted enum values"
        )

        let legacyPreferences = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(
                """
                {
                  "previewMode": "projectAndPreview",
                  "staleTimeout": 2700,
                  "recentRetention": 604800,
                  "maxRecentCompletions": 100,
                  "completionSneakPeekEnabled": true,
                  "approvalReminderEnabled": true
                }
                """.utf8
            )
        )
        try expect(
            legacyPreferences.statusConfirmationTimeout == 5 * 60
                && legacyPreferences.staleTimeout == 45 * 60,
            "new preferences decode older payloads without losing their existing stale timeout"
        )

        let legacyAwaitingStatus = try JSONDecoder().decode(
            CodexTaskStatus.self,
            from: Data("\"awaitingStatus\"".utf8)
        )
        let legacyInterruptedStatus = try JSONDecoder().decode(
            CodexTaskStatus.self,
            from: Data("\"interrupted\"".utf8)
        )
        let unknownFutureStatus = try JSONDecoder().decode(
            CodexTaskStatus.self,
            from: Data("\"futureStatus\"".utf8)
        )
        try expect(
            legacyAwaitingStatus == .running
                && legacyInterruptedStatus == .failedOrInterrupted
                && unknownFutureStatus == .failedOrInterrupted,
            "legacy transient and unknown future statuses degrade without invalidating the whole state file"
        )

        _ = store.performMaintenance(now: startedAt.addingTimeInterval(30 * 60))
        try expect(
            store.snapshot.tasks.first?.status == .stale,
            "a task with no Hook for thirty minutes becomes possibly disconnected"
        )

        var staleRecoveryStore = store
        let staleRecoveryTime = startedAt.addingTimeInterval(30 * 60 + 1)
        _ = staleRecoveryStore.apply(
            CodexHookEnvelope(
                receivedAt: staleRecoveryTime,
                payload: CodexHookEvent(
                    hookEventName: "PostToolUse",
                    sessionID: sessionID,
                    turnID: "turn-1",
                    toolName: "Bash"
                )
            )
        )
        try expect(
            staleRecoveryStore.snapshot.tasks.first?.status == .running
                && staleRecoveryStore.snapshot.tasks.first?.lastActivityAt == staleRecoveryTime,
            "a real Hook restores an inferred stale task"
        )

        let lastHookAt = store.snapshot.tasks.first?.lastActivityAt
        let interruptedAt = startedAt.addingTimeInterval(31 * 60)
        _ = store.markInterrupted(sessionID: sessionID, now: interruptedAt)
        try expect(
            store.snapshot.tasks.first?.status == .failedOrInterrupted
                && store.snapshot.tasks.first?.lastEventName == "ManualInterruption"
                && store.snapshot.tasks.first?.lastActivityAt == lastHookAt
                && store.snapshot.tasks.first?.endedAt == interruptedAt,
            "manual interruption uses the compatible failure status and preserves the last real Hook time"
        )
        let interruptedTray = CodexActivityTrayBuilder().build(
            from: store.snapshot,
            now: startedAt.addingTimeInterval(31 * 60)
        )
        try expect(
            interruptedTray.buckets.first(where: { $0.bucket == .readHistory })?.items.first?.statusText == "已中断",
            "manually interrupted tasks move to history instead of remaining in an active bucket"
        )

        let recoveryTime = startedAt.addingTimeInterval(32 * 60)
        _ = store.apply(
            CodexHookEnvelope(
                receivedAt: recoveryTime,
                payload: CodexHookEvent(
                    hookEventName: "PostToolUse",
                    sessionID: sessionID,
                    turnID: "turn-1",
                    toolName: "Bash"
                )
            )
        )
        try expect(
            store.snapshot.tasks.first?.status == .failedOrInterrupted
                && store.snapshot.tasks.first?.lastActivityAt == recoveryTime,
            "a late Hook updates evidence without undoing an explicit manual interruption"
        )

        let resumedAt = startedAt.addingTimeInterval(33 * 60)
        _ = store.apply(
            CodexHookEnvelope(
                receivedAt: resumedAt,
                payload: CodexHookEvent(
                    hookEventName: "UserPromptSubmit",
                    sessionID: sessionID,
                    turnID: "turn-2",
                    prompt: "重新开始"
                )
            )
        )
        try expect(
            store.snapshot.tasks.first?.status == .running
                && store.snapshot.tasks.first?.currentTurnID == "turn-2"
                && store.snapshot.tasks.first?.startedAt == resumedAt,
            "only a new prompt starts a manually interrupted conversation again"
        )

        let recentManualInterruption = CodexTaskRecord(
            sessionID: "recent-interruption",
            projectName: "Atoll-CodexAtoll",
            promptPreview: "最近手动中断",
            status: .failedOrInterrupted,
            startedAt: startedAt.addingTimeInterval(-120),
            lastActivityAt: startedAt.addingTimeInterval(-60),
            endedAt: startedAt,
            lastEventName: "ManualInterruption"
        )
        let expiredManualInterruption = CodexTaskRecord(
            sessionID: "expired-interruption",
            projectName: "Atoll-CodexAtoll",
            promptPreview: "过期手动中断",
            status: .failedOrInterrupted,
            startedAt: startedAt.addingTimeInterval(-(8 * 24 * 60 * 60)),
            lastActivityAt: startedAt.addingTimeInterval(-(8 * 24 * 60 * 60)),
            endedAt: startedAt.addingTimeInterval(-(8 * 24 * 60 * 60)),
            lastEventName: "ManualInterruption"
        )
        let interruptionHistory = CodexActivityTrayBuilder().build(
            from: CodexTaskStoreSnapshot(
                savedAt: startedAt,
                tasks: [recentManualInterruption, expiredManualInterruption]
            ),
            now: startedAt
        )
        try expect(
            interruptionHistory.buckets.first(where: { $0.bucket == .readHistory })?.items.map(\.sessionID)
                == [recentManualInterruption.sessionID],
            "manual interruption history follows the same retention window as completed history"
        )

        let elapsedTray = CodexActivityTrayBuilder().build(
            from: CodexTaskStoreSnapshot(
                savedAt: startedAt,
                tasks: [
                    CodexTaskRecord(
                        sessionID: "elapsed-session",
                        projectName: "Atoll-CodexAtoll",
                        status: .running,
                        startedAt: startedAt.addingTimeInterval(-125),
                        lastActivityAt: startedAt.addingTimeInterval(-120)
                    )
                ]
            ),
            now: startedAt
        )
        try expect(
            elapsedTray.buckets.first(where: { $0.bucket == .running })?.items.first?.statusText == "运行中 · 02:05",
            "running duration is measured to the current time instead of the last Hook"
        )

        let hourElapsedTray = CodexActivityTrayBuilder().build(
            from: CodexTaskStoreSnapshot(
                savedAt: startedAt,
                tasks: [
                    CodexTaskRecord(
                        sessionID: "hour-elapsed-session",
                        projectName: "Atoll-CodexAtoll",
                        status: .running,
                        startedAt: startedAt.addingTimeInterval(-3_665),
                        lastActivityAt: startedAt
                    )
                ]
            ),
            now: startedAt
        )
        try expect(
            hourElapsedTray.buckets.first(where: { $0.bucket == .running })?.items.first?.statusText
                == "运行中 · 01:01:05",
            "running duration uses an hour-aware format"
        )

        print("CodexStatusReconciliationTests: PASS")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw TestFailure(message: message) }
    }
}

private struct TestFailure: Error {
    let message: String
}
