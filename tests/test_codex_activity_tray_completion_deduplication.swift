import CoreGraphics
import Foundation

@main
struct CodexActivityTrayCompletionDeduplicationTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let earlierTurn = CodexCompletionRecord(
            sessionID: "multi-turn-session",
            projectName: "Multi-turn Project",
            promptPreview: "第一轮问题",
            resultPreview: "第一轮完成",
            completedAt: now.addingTimeInterval(-60)
        )
        let latestTurn = CodexCompletionRecord(
            sessionID: "multi-turn-session",
            projectName: "Multi-turn Project",
            promptPreview: "第二轮问题",
            resultPreview: "第二轮完成",
            completedAt: now
        )

        let unreadTray = CodexActivityTrayBuilder().build(
            from: CodexTaskStoreSnapshot(
                savedAt: now,
                recentCompletions: [earlierTurn, latestTurn]
            )
        )
        try expect(
            unreadTray.buckets.count == 1
                && unreadTray.buckets.first?.bucket == .unreadCompleted
                && unreadTray.buckets.first?.itemCount == 1
                && unreadTray.buckets.first?.items.first?.title == "第二轮问题",
            "multiple completed turns in one conversation occupy one unread card with the latest content"
        )

        let readTray = CodexActivityTrayBuilder().build(
            from: CodexTaskStoreSnapshot(
                savedAt: now,
                recentCompletions: [earlierTurn, latestTurn],
                acknowledgedCompletionIDs: [earlierTurn.id, latestTurn.id]
            )
        )
        try expect(
            readTray.buckets.count == 1
                && readTray.buckets.first?.bucket == .readHistory
                && readTray.buckets.first?.itemCount == 1
                && readTray.buckets.first?.items.first?.title == "第二轮问题",
            "viewing a multi-turn conversation greys one latest history card without duplicates"
        )

        let latestUnreadTray = CodexActivityTrayBuilder().build(
            from: CodexTaskStoreSnapshot(
                savedAt: now,
                recentCompletions: [earlierTurn, latestTurn],
                acknowledgedCompletionIDs: [earlierTurn.id]
            )
        )
        try expect(
            latestUnreadTray.buckets.count == 1
                && latestUnreadTray.buckets.first?.bucket == .unreadCompleted
                && latestUnreadTray.buckets.first?.itemCount == 1
                && latestUnreadTray.buckets.first?.items.first?.title == "第二轮问题",
            "a new completed turn refreshes the same conversation card back to unread"
        )

        let visibleIDs = CodexActivityTrayVisibilityPolicy.visibleItemIDs(
            itemFrames: [
                "visible": CGRect(x: 0, y: 20, width: 240, height: 80),
                "clipped-edge": CGRect(x: 0, y: 180, width: 240, height: 80),
                "offscreen": CGRect(x: 0, y: 220, width: 240, height: 80),
            ],
            viewportBounds: CGRect(x: 0, y: 0, width: 240, height: 200)
        )
        try expect(
            visibleIDs == ["visible"],
            "only completion cards that are materially visible in the drawer count as read"
        )

        var presentationLifecycle = CodexActivityTrayPresentationLifecycle()
        var beginCount = 0
        try expect(
            presentationLifecycle.beginIfNeeded { _ in
                beginCount += 1
                return true
            }
                && presentationLifecycle.beginIfNeeded { _ in
                    beginCount += 1
                    return true
                }
                && beginCount == 1,
            "the first geometry callback can begin the view generation before onAppear without creating a second presentation"
        )
        let begunPresentationID = presentationLifecycle.id
        try expect(
            presentationLifecycle.invalidate() == begunPresentationID
                && !presentationLifecycle.beginIfNeeded { _ in true },
            "a dismissed view generation cannot restart after it has begun"
        )

        var neverBegunLifecycle = CodexActivityTrayPresentationLifecycle()
        var attemptedLateBegin = false
        try expect(
            neverBegunLifecycle.invalidate() == nil
                && !neverBegunLifecycle.beginIfNeeded { _ in
                    attemptedLateBegin = true
                    return true
                }
                && !attemptedLateBegin,
            "a view dismissed before its first callback cannot be revived by late geometry"
        )

        var registry = CodexActivityTrayPresentationRegistry()
        let screenKey = "Built-in Retina Display"
        let firstContentSignature = [latestTurn.id]
        let firstRegistryPresentation = registry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        try expect(
            firstRegistryPresentation.exposedCompletionIDs.isEmpty,
            "opening a tray starts with no completion exposed"
        )
        let firstVisibleCompletionIDs = registry.updateVisibility(
            screenKey: screenKey,
            presentationID: firstRegistryPresentation.presentationID,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: [latestTurn.id]
        )
        try expect(
            firstVisibleCompletionIDs == [latestTurn.id],
            "the first visible geometry update records the completion in the active presentation"
        )
        let repeatedBegin = registry.beginPresentation(
            screenKey: screenKey,
            presentationID: firstRegistryPresentation.presentationID
        )!
        try expect(
            repeatedBegin.presentationID == firstRegistryPresentation.presentationID
                && repeatedBegin.exposedCompletionIDs == [latestTurn.id],
            "repeated host synchronization keeps the same active presentation"
        )
        try expect(
            registry.finishPresentation(screenKey: screenKey) == [latestTurn.id],
            "closing the first tray presentation returns the exact completion that was visible"
        )
        try expect(
            registry.finishPresentation(screenKey: screenKey).isEmpty,
            "closing an already finished presentation is idempotent"
        )

        let newerTurn = CodexCompletionRecord(
            sessionID: latestTurn.sessionID,
            projectName: latestTurn.projectName,
            promptPreview: "第三轮问题",
            resultPreview: "第三轮完成",
            completedAt: now.addingTimeInterval(30)
        )
        let viewportPresentation = registry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        registry.updateVisibility(
            screenKey: screenKey,
            presentationID: viewportPresentation.presentationID,
            contentSignature: [latestTurn.id, newerTurn.id],
            visibleCompletionIDs: [latestTurn.id]
        )
        try expect(
            registry.finishPresentation(
                screenKey: screenKey,
                presentationID: viewportPresentation.presentationID
            ) == [latestTurn.id],
            "a completion below the visible viewport remains unread"
        )

        let scrollingPresentation = registry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        registry.updateVisibility(
            screenKey: screenKey,
            presentationID: scrollingPresentation.presentationID,
            contentSignature: [latestTurn.id, newerTurn.id],
            visibleCompletionIDs: [latestTurn.id]
        )
        registry.updateVisibility(
            screenKey: screenKey,
            presentationID: scrollingPresentation.presentationID,
            contentSignature: [latestTurn.id, newerTurn.id],
            visibleCompletionIDs: [latestTurn.id, newerTurn.id]
        )
        try expect(
            registry.finishPresentation(
                screenKey: screenKey,
                presentationID: scrollingPresentation.presentationID
            ) == [latestTurn.id, newerTurn.id],
            "an open tray accumulates each completion that actually becomes visible"
        )

        let mainScreenPresentation = registry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        let externalScreenPresentation = registry.beginPresentation(
            screenKey: "External Display",
            presentationID: UUID()
        )!
        registry.updateVisibility(
            screenKey: screenKey,
            presentationID: mainScreenPresentation.presentationID,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: [latestTurn.id]
        )
        registry.updateVisibility(
            screenKey: "External Display",
            presentationID: externalScreenPresentation.presentationID,
            contentSignature: [newerTurn.id],
            visibleCompletionIDs: [newerTurn.id]
        )
        try expect(
            registry.finishPresentation(
                screenKey: screenKey,
                presentationID: mainScreenPresentation.presentationID
            ) == [latestTurn.id]
                && registry.finishPresentation(
                    screenKey: "External Display",
                    presentationID: externalScreenPresentation.presentationID
                ) == [newerTurn.id],
            "activity tray presentations remain isolated per screen"
        )

        var lateVisibilityRegistry = CodexActivityTrayPresentationRegistry()
        let dismissedPresentation = lateVisibilityRegistry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        lateVisibilityRegistry.updateVisibility(
            screenKey: screenKey,
            presentationID: dismissedPresentation.presentationID,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: []
        )
        try expect(
            lateVisibilityRegistry.finishPresentation(
                screenKey: screenKey,
                presentationID: dismissedPresentation.presentationID
            ).isEmpty,
            "closing before a completion becomes visible does not acknowledge it"
        )
        lateVisibilityRegistry.updateVisibility(
            screenKey: screenKey,
            presentationID: dismissedPresentation.presentationID,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: [latestTurn.id]
        )
        let presentationAfterLateVisibility = lateVisibilityRegistry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        try expect(
            presentationAfterLateVisibility.exposedCompletionIDs.isEmpty,
            "a visibility update arriving after dismissal is never replayed into the next presentation"
        )

        var retiredTokenRegistry = CodexActivityTrayPresentationRegistry()
        let retiredPresentation = retiredTokenRegistry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        _ = retiredTokenRegistry.finishPresentation(
            screenKey: screenKey,
            presentationID: retiredPresentation.presentationID
        )
        try expect(
            retiredTokenRegistry.beginPresentation(
                screenKey: screenKey,
                presentationID: retiredPresentation.presentationID
            ) == nil,
            "a finished presentation token is one-shot and cannot be revived before the next tray begins"
        )

        var reopenedRegistry = CodexActivityTrayPresentationRegistry()
        let firstReopenedPresentation = reopenedRegistry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        _ = reopenedRegistry.finishPresentation(
            screenKey: screenKey,
            presentationID: firstReopenedPresentation.presentationID
        )
        let secondReopenedPresentation = reopenedRegistry.beginPresentation(
            screenKey: screenKey,
            presentationID: UUID()
        )!
        try expect(
            reopenedRegistry.beginPresentation(
                screenKey: screenKey,
                presentationID: firstReopenedPresentation.presentationID
            ) == nil,
            "a dismissed view generation cannot bind itself to a newly reopened tray"
        )
        try expect(
            reopenedRegistry.finishPresentation(
                screenKey: screenKey,
                presentationID: firstReopenedPresentation.presentationID
            ).isEmpty,
            "a stale dismissal callback cannot finish a newly reopened tray"
        )
        let staleVisibilityUpdate = reopenedRegistry.updateVisibility(
            screenKey: screenKey,
            presentationID: firstReopenedPresentation.presentationID,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: [latestTurn.id]
        )
        let activeVisibilityUpdate = reopenedRegistry.updateVisibility(
            screenKey: screenKey,
            presentationID: secondReopenedPresentation.presentationID,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: []
        )
        try expect(
            staleVisibilityUpdate == nil
                && activeVisibilityUpdate?.isEmpty == true
                && reopenedRegistry.finishPresentation(
                screenKey: screenKey,
                presentationID: secondReopenedPresentation.presentationID
            ).isEmpty,
            "a visibility callback from the dismissed presentation cannot expose a completion in a newly reopened tray"
        )
        print("CodexActivityTrayCompletionDeduplicationTests: PASS")
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
