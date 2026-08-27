import Foundation

enum SneakPeekDismissalResult: String, Equatable, Sendable {
    case dismissed
    case alreadyHidden = "already_hidden"
    case differentContent = "different_content"
    case stalePresentation = "stale_presentation"
}

enum SneakPeekPresentationTokenPolicy {
    static func dismissalResult(
        isShowing: Bool,
        currentPresentationID: UUID?,
        expectedPresentationID: UUID?
    ) -> SneakPeekDismissalResult {
        guard isShowing else { return .alreadyHidden }
        guard let expectedPresentationID else { return .dismissed }
        guard currentPresentationID == expectedPresentationID else {
            return .stalePresentation
        }
        return .dismissed
    }

    static func canDismiss(
        isShowing: Bool,
        currentPresentationID: UUID?,
        expectedPresentationID: UUID?
    ) -> Bool {
        dismissalResult(
            isShowing: isShowing,
            currentPresentationID: currentPresentationID,
            expectedPresentationID: expectedPresentationID
        ) == .dismissed
    }
}
