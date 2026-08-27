import Foundation

@main
struct CodexSneakPeekPresentationPolicyTests {
    static func main() throws {
        let completionSnapshot = [
            "codex_presentation_phase": "completion-pulse",
            "codex_waiting_count": "0",
        ]
        let restoredLiveMetadata = [
            "codex_presentation_phase": "steady",
            "codex_waiting_count": "0",
        ]

        try expect(
            CodexSneakPeekPresentationPolicy.resolvedPhase(
                snapshotMetadata: completionSnapshot,
                liveMetadata: restoredLiveMetadata
            ) == "completion-pulse",
            "a visible completion notification keeps its trigger-time phase after steady restore"
        )
        try expect(
            CodexSneakPeekPresentationPolicy.resolvedPhase(
                snapshotMetadata: ["codex_presentation_phase": "running-pulse"],
                liveMetadata: restoredLiveMetadata
            ) == "running-pulse",
            "a visible running marquee keeps its trigger-time phase after steady restore"
        )

        let codexBundleIdentifier = CodexPresentationConstants.defaultBundleIdentifier
        try expect(
            CodexSneakPeekPresentationPolicy.shouldSuppressPersistentActivity(
                candidateBundleIdentifier: codexBundleIdentifier,
                candidateActivityID: CodexPresentationConstants.liveActivityID,
                sneakPeekVisibleOnScreen: true,
                sneakPeekBundleIdentifier: codexBundleIdentifier,
                sneakPeekActivityID: CodexPresentationConstants.liveActivityID
            ),
            "the active Codex sneak peek replaces its matching standalone summary"
        )
        try expect(
            !CodexSneakPeekPresentationPolicy.shouldSuppressPersistentActivity(
                candidateBundleIdentifier: codexBundleIdentifier,
                candidateActivityID: CodexPresentationConstants.liveActivityID,
                sneakPeekVisibleOnScreen: false,
                sneakPeekBundleIdentifier: codexBundleIdentifier,
                sneakPeekActivityID: CodexPresentationConstants.liveActivityID
            ),
            "the standalone summary returns after the Codex sneak peek is hidden"
        )
        try expect(
            !CodexSneakPeekPresentationPolicy.shouldSuppressPersistentActivity(
                candidateBundleIdentifier: codexBundleIdentifier,
                candidateActivityID: "another-codex-activity",
                sneakPeekVisibleOnScreen: true,
                sneakPeekBundleIdentifier: codexBundleIdentifier,
                sneakPeekActivityID: CodexPresentationConstants.liveActivityID
            ),
            "an unrelated Codex activity is not hidden by another activity's sneak peek"
        )
        try expect(
            !CodexSneakPeekPresentationPolicy.shouldSuppressPersistentActivity(
                candidateBundleIdentifier: "com.example.extension",
                candidateActivityID: "example-activity",
                sneakPeekVisibleOnScreen: true,
                sneakPeekBundleIdentifier: "com.example.extension",
                sneakPeekActivityID: "example-activity"
            ),
            "the Codex-specific replacement policy does not change third-party extension behavior"
        )

        let blockedTransient = CodexSneakPeekPresentationPolicy.surfaceDecision(
            isShowing: true,
            isDismissing: false,
            targetsCurrentScreen: true,
            passesRenderGates: false,
            candidateMatches: true
        )
        try expect(
            !blockedTransient.rendersTransient
                && !blockedTransient.transientOccupiesSlot
                && !blockedTransient.suppressesPersistent,
            "a Codex pulse that cannot render keeps the persistent summary visible"
        )

        let dismissingTransient = CodexSneakPeekPresentationPolicy.surfaceDecision(
            isShowing: false,
            isDismissing: true,
            targetsCurrentScreen: true,
            passesRenderGates: true,
            candidateMatches: true
        )
        try expect(
            !dismissingTransient.rendersTransient
                && dismissingTransient.transientOccupiesSlot
                && dismissingTransient.suppressesPersistent,
            "a renderable Codex pulse keeps its slot during the dismissal transition"
        )

        let completionFallbackDuration = CodexSneakPeekPresentationPolicy.hostAutoHideDuration(
            requestedDuration: CodexPresentationConstants.completionPulseDuration,
            bundleIdentifier: codexBundleIdentifier,
            metadata: completionSnapshot
        )
        try expect(
            completionFallbackDuration.isFinite
                && completionFallbackDuration > CodexPresentationConstants.completionPulseDuration,
            "completion notifications keep a finite host fallback after the coordinator deadline"
        )
        let runningFallbackDuration = CodexSneakPeekPresentationPolicy.hostAutoHideDuration(
            requestedDuration: CodexPresentationConstants.runningSneakPeekDuration,
            bundleIdentifier: codexBundleIdentifier,
            metadata: ["codex_presentation_phase": "running-pulse"]
        )
        try expect(
            runningFallbackDuration.isFinite
                && runningFallbackDuration > CodexPresentationConstants.runningSneakPeekDuration,
            "running notifications keep a finite host fallback after the coordinator deadline"
        )
        try expect(
            CodexSneakPeekPresentationPolicy.hostAutoHideDuration(
                requestedDuration: 2.5,
                bundleIdentifier: "com.example.extension",
                metadata: ["codex_presentation_phase": "running-pulse"]
            ) == 2.5,
            "third-party extension sneak peeks keep the shared host auto-hide timer"
        )

        let oldPresentationID = UUID()
        let replacementPresentationID = UUID()
        try expect(
            !SneakPeekPresentationTokenPolicy.canDismiss(
                isShowing: true,
                currentPresentationID: replacementPresentationID,
                expectedPresentationID: oldPresentationID
            ),
            "an expired auto-hide task cannot dismiss a replacement sneak peek"
        )
        try expect(
            SneakPeekPresentationTokenPolicy.canDismiss(
                isShowing: true,
                currentPresentationID: replacementPresentationID,
                expectedPresentationID: replacementPresentationID
            ),
            "the active presentation can dismiss itself at its own deadline"
        )
        try expect(
            !SneakPeekPresentationTokenPolicy.canDismiss(
                isShowing: false,
                currentPresentationID: replacementPresentationID,
                expectedPresentationID: nil
            ),
            "a hidden presentation ignores duplicate dismissal requests"
        )

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentViewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DynamicIsland/ContentView.swift"),
            encoding: .utf8
        )
        try expect(
            contentViewSource.contains("? codexSurfaceDecision.rendersTransient"),
            "the Codex card stops rendering as soon as dismissal begins"
        )

        let liveActivityManagerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "DynamicIsland/managers/Extensions/ExtensionLiveActivityManager.swift"
            ),
            encoding: .utf8
        )
        try expect(
            !liveActivityManagerSource.contains("builtInSneakPeekPresentationIDs"),
            "the shared coordinator remains the single owner of the active sneak peek token"
        )

        print("CodexSneakPeekPresentationPolicyTests: PASS")
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
