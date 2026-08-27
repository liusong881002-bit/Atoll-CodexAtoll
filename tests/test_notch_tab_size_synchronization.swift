import CoreGraphics
import Foundation

@main
struct NotchTabSizeSynchronizationTests {
    static func main() throws {
        let codexSize = CGSize(width: 640, height: 420)

        try expect(
            NotchTabSizeSynchronizationPolicy.contentSizeAfterTabSwitch(
                isOpen: true,
                currentSize: codexSize,
                resolvedSize: CGSize(width: 640, height: 200)
            ) == CGSize(width: 640, height: 200),
            "switching from Codex to Home adopts the Home content height"
        )

        try expect(
            NotchTabSizeSynchronizationPolicy.contentSizeAfterTabSwitch(
                isOpen: true,
                currentSize: codexSize,
                resolvedSize: CGSize(width: 640, height: 250)
            ) == CGSize(width: 640, height: 250),
            "switching from Codex to Timer adopts the Timer content height"
        )

        let closedSize = CGSize(width: 200, height: 32)
        try expect(
            NotchTabSizeSynchronizationPolicy.contentSizeAfterTabSwitch(
                isOpen: false,
                currentSize: closedSize,
                resolvedSize: CGSize(width: 640, height: 200)
            ) == closedSize,
            "tab changes do not expand a closed notch"
        )

        print("NotchTabSizeSynchronizationTests: PASS")
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
