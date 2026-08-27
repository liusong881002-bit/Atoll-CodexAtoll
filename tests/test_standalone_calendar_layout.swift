import CoreGraphics
import Foundation

@main
struct StandaloneCalendarLayoutTests {
    static func main() throws {
        try expect(
            resolvedHeight(
                showCalendar: true,
                showStandardMediaControls: true,
                autoHideInactiveMediaPlayer: true,
                hasActiveMusicSession: false
            ) == StandaloneCalendarLayoutPolicy.preferredOpenNotchHeight,
            "an inactive auto-hidden media player gives the standalone calendar full-month height"
        )

        try expect(
            resolvedHeight(
                showCalendar: true,
                showStandardMediaControls: true,
                autoHideInactiveMediaPlayer: true,
                hasActiveMusicSession: true
            ) == 200,
            "an active media player keeps the compact combined layout"
        )

        try expect(
            resolvedHeight(
                showCalendar: true,
                showStandardMediaControls: true,
                autoHideInactiveMediaPlayer: false,
                hasActiveMusicSession: false
            ) == 200,
            "an always-visible media player keeps the compact combined layout"
        )

        try expect(
            resolvedHeight(
                showCalendar: false,
                showStandardMediaControls: false,
                autoHideInactiveMediaPlayer: true,
                hasActiveMusicSession: false
            ) == 200,
            "a Home tab without the calendar keeps its normal height"
        )

        print("StandaloneCalendarLayoutTests: PASS")
    }

    private static func resolvedHeight(
        showCalendar: Bool,
        enableMinimalisticUI: Bool = false,
        showStandardMediaControls: Bool,
        autoHideInactiveMediaPlayer: Bool,
        hasActiveMusicSession: Bool
    ) -> CGFloat {
        StandaloneCalendarLayoutPolicy.resolvedOpenNotchHeight(
            baseHeight: 200,
            showCalendar: showCalendar,
            enableMinimalisticUI: enableMinimalisticUI,
            showStandardMediaControls: showStandardMediaControls,
            autoHideInactiveMediaPlayer: autoHideInactiveMediaPlayer,
            hasActiveMusicSession: hasActiveMusicSession
        )
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
