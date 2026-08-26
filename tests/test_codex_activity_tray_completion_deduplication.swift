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

        let presentationID = UUID()
        var presentationVisibility = CodexActivityTrayPresentationVisibility()
        presentationVisibility.updateLayout(
            itemFrames: [
                "visible": CGRect(x: 0, y: 20, width: 240, height: 80),
                "offscreen": CGRect(x: 0, y: 220, width: 240, height: 80),
            ],
            viewportSize: CGSize(width: 240, height: 200)
        )
        try expect(
            presentationVisibility.activeExposure == nil,
            "visible layout arriving before the tray presentation waits for an active session"
        )
        presentationVisibility.beginPresentation(id: presentationID)
        try expect(
            presentationVisibility.activeExposure?.presentationID == presentationID
                && presentationVisibility.activeExposure?.visibleItemIDs == ["visible"],
            "the first visible layout is replayed when the tray presentation starts"
        )

        let visibleCompletionItems = unreadTray.buckets.first?.items ?? []
        let firstPresentation = CodexActivityTrayExposurePolicy.decision(
            for: visibleCompletionItems,
            previouslyPresentedIDs: [],
            handledCompletionIDs: []
        )
        try expect(
            firstPresentation.completionIDsToRecord == [latestTurn.id]
                && firstPresentation.sessionIDsToAcknowledge.isEmpty,
            "the first visible presentation records exposure without acknowledging the completion"
        )
        let repeatedLayoutInSamePresentation = CodexActivityTrayExposurePolicy.decision(
            for: visibleCompletionItems,
            previouslyPresentedIDs: [latestTurn.id],
            handledCompletionIDs: firstPresentation.handledCompletionIDs
        )
        try expect(
            repeatedLayoutInSamePresentation.completionIDsToRecord.isEmpty
                && repeatedLayoutInSamePresentation.sessionIDsToAcknowledge.isEmpty,
            "layout updates during one open drawer never count as a second presentation"
        )
        let secondPresentation = CodexActivityTrayExposurePolicy.decision(
            for: visibleCompletionItems,
            previouslyPresentedIDs: [latestTurn.id],
            handledCompletionIDs: []
        )
        try expect(
            secondPresentation.completionIDsToRecord.isEmpty
                && secondPresentation.sessionIDsToAcknowledge.isEmpty,
            "reopening the drawer does not acknowledge a completion before the prior presentation is dismissed"
        )
        try expect(
            CodexActivityTrayExposurePolicy.sessionIDsToAcknowledgeOnDismiss(
                for: visibleCompletionItems
            ) == [latestTurn.sessionID],
            "dismissing the drawer acknowledges the completion that was browsed during the presentation"
        )

        var explicitCloseSession = CodexActivityTrayReadSession()
        let explicitCloseDecision = explicitCloseSession.recordExposure(
            for: visibleCompletionItems,
            previouslyPresentedIDs: []
        )
        try expect(
            explicitCloseDecision.handledCompletionIDs == [latestTurn.id]
                && explicitCloseSession.finish() == [latestTurn.sessionID]
                && explicitCloseSession.finish().isEmpty,
            "an explicit tray close acknowledges exposed sessions without relying on onDisappear and is idempotent"
        )

        var registry = CodexActivityTrayPresentationRegistry()
        let screenKey = "Built-in Retina Display"
        let firstContentSignature = [latestTurn.id]
        registry.updateVisibility(
            screenKey: screenKey,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: [latestTurn.id]
        )
        let firstRegistryPresentation = registry.beginPresentation(
            screenKey: screenKey,
            contentSignature: firstContentSignature
        )
        try expect(
            firstRegistryPresentation.exposedCompletionIDs == [latestTurn.id],
            "opening the tray replays the last matching visible layout"
        )
        try expect(
            registry.finishPresentation(screenKey: screenKey) == [latestTurn.id],
            "closing the first tray presentation returns the exact completion that was visible"
        )

        let repeatedRegistryPresentation = registry.beginPresentation(
            screenKey: screenKey,
            contentSignature: firstContentSignature
        )
        try expect(
            repeatedRegistryPresentation.exposedCompletionIDs == [latestTurn.id],
            "reopening an unchanged tray replays visibility without requiring another layout callback"
        )

        let additionalCompletionID = UUID()
        let changedContentPresentation = registry.beginPresentation(
            screenKey: screenKey,
            contentSignature: [additionalCompletionID, latestTurn.id]
        )
        try expect(
            changedContentPresentation.exposedCompletionIDs == [latestTurn.id],
            "reopening after unread content changes still replays the previously visible completion"
        )

        let newerTurn = CodexCompletionRecord(
            sessionID: latestTurn.sessionID,
            projectName: latestTurn.projectName,
            promptPreview: "第三轮问题",
            resultPreview: "第三轮完成",
            completedAt: now.addingTimeInterval(30)
        )
        registry.updateVisibility(
            screenKey: screenKey,
            contentSignature: [newerTurn.id],
            visibleCompletionIDs: [newerTurn.id]
        )
        try expect(
            registry.finishPresentation(screenKey: screenKey) == [latestTurn.id, newerTurn.id],
            "an open tray accumulates only completion IDs that were actually visible"
        )

        registry.updateVisibility(
            screenKey: screenKey,
            contentSignature: [latestTurn.id],
            visibleCompletionIDs: [latestTurn.id]
        )
        _ = registry.beginPresentation(
            screenKey: screenKey,
            contentSignature: [latestTurn.id]
        )
        registry.updateVisibility(
            screenKey: screenKey,
            contentSignature: [newerTurn.id],
            visibleCompletionIDs: []
        )
        try expect(
            registry.finishPresentation(screenKey: screenKey) == [latestTurn.id],
            "a newer completion in the same session is not acknowledged unless it becomes visible"
        )

        registry.updateVisibility(
            screenKey: screenKey,
            contentSignature: firstContentSignature,
            visibleCompletionIDs: [latestTurn.id]
        )
        registry.updateVisibility(
            screenKey: "External Display",
            contentSignature: [newerTurn.id],
            visibleCompletionIDs: [newerTurn.id]
        )
        _ = registry.beginPresentation(
            screenKey: screenKey,
            contentSignature: firstContentSignature
        )
        _ = registry.beginPresentation(
            screenKey: "External Display",
            contentSignature: [newerTurn.id]
        )
        try expect(
            registry.finishPresentation(screenKey: screenKey) == [latestTurn.id]
                && registry.finishPresentation(screenKey: "External Display") == [newerTurn.id],
            "activity tray presentations remain isolated per screen"
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
