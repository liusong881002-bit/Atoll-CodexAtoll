import Foundation

@main
struct ShelfDropFeedbackContractTests {
    static func main() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let contentView = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/ContentView.swift")
        )
        let stateViewModel = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/ViewModels/ShelfStateViewModel.swift")
        )
        let shelfView = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/Views/ShelfView.swift")
        )
        let itemView = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/Views/ShelfItemView.swift")
        )

        try expect(
            stateViewModel.contains("struct ShelfAddEvent: Equatable, Sendable")
                && stateViewModel.contains("@Published private(set) var lastAddEvent: ShelfAddEvent?")
                && stateViewModel.contains("event = ShelfAddEvent")
                && stateViewModel.contains("focusShelf: Bool")
                && stateViewModel.contains("focusShelf: policy == .filesOnly")
                && stateViewModel.contains("guard !addedIDs.isEmpty")
                && stateViewModel.contains("lastAddEvent = event")
                && stateViewModel.contains("lastAddEvent = nil"),
            "Shelf state must publish a real-add event only after one or more new items are inserted"
        )

        try expect(
            contentView.contains(".onChange(of: shelfState.lastAddEvent)")
                && contentView.contains("coordinator.currentView = .shelf")
                && contentView.contains("openNotch()"),
            "ContentView must switch to and open the Shelf after a successful global drop"
        )

        try expect(
            shelfView.contains("tvm.addFeedbackMessage")
                && shelfView.contains(".transition(")
                && shelfView.contains(".move(edge: .top)")
                && stateViewModel.contains("String(localized: \"Added to Shelf\")"),
            "Shelf must show a transient success confirmation after a file is staged"
        )

        try expect(
            itemView.contains("addPulse")
                && itemView.contains("lastAnimatedAddToken")
                && itemView.contains("ShelfAddEvent"),
            "newly staged cards must have a one-shot visual pulse keyed by the add event"
        )

        print("ShelfDropFeedbackContractTests: PASS")
    }

    private static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
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
