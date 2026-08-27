import Foundation

enum CodexSneakPeekPresentationPolicy {
    private static let hostFallbackGraceDuration: TimeInterval = 1

    struct SurfaceDecision: Equatable {
        let rendersTransient: Bool
        let transientOccupiesSlot: Bool
        let suppressesPersistent: Bool
    }

    static func resolvedPhase(
        snapshotMetadata: [String: String],
        liveMetadata: [String: String]?
    ) -> String? {
        snapshotMetadata["codex_presentation_phase"]
            ?? liveMetadata?["codex_presentation_phase"]
    }

    static func shouldSuppressPersistentActivity(
        candidateBundleIdentifier: String,
        candidateActivityID: String,
        sneakPeekVisibleOnScreen: Bool,
        sneakPeekBundleIdentifier: String?,
        sneakPeekActivityID: String?
    ) -> Bool {
        guard sneakPeekVisibleOnScreen,
              CodexPresentationConstants.isBuiltInCodex(
                  bundleIdentifier: candidateBundleIdentifier
              ),
              candidateBundleIdentifier == sneakPeekBundleIdentifier,
              candidateActivityID == sneakPeekActivityID else {
            return false
        }
        return true
    }

    static func surfaceDecision(
        isShowing: Bool,
        isDismissing: Bool,
        targetsCurrentScreen: Bool,
        passesRenderGates: Bool,
        candidateMatches: Bool
    ) -> SurfaceDecision {
        let rendersTransient = isShowing
            && targetsCurrentScreen
            && passesRenderGates
        let transientOccupiesSlot = (isShowing || isDismissing)
            && targetsCurrentScreen
            && passesRenderGates
        return SurfaceDecision(
            rendersTransient: rendersTransient,
            transientOccupiesSlot: transientOccupiesSlot,
            suppressesPersistent: transientOccupiesSlot && candidateMatches
        )
    }

    static func hostAutoHideDuration(
        requestedDuration: TimeInterval,
        bundleIdentifier: String,
        metadata: [String: String]
    ) -> TimeInterval {
        let phase = metadata["codex_presentation_phase"]
        if CodexPresentationConstants.isBuiltInCodex(bundleIdentifier: bundleIdentifier),
           phase == "running-pulse" || phase == "completion-pulse" {
            let boundedRequestedDuration = requestedDuration.isFinite
                ? max(0, requestedDuration)
                : CodexPresentationConstants.completionPulseDuration
            return boundedRequestedDuration + hostFallbackGraceDuration
        }
        return requestedDuration
    }
}
