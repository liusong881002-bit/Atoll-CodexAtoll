import Foundation

@main
struct ShelfDropPerformanceContractTests {
    static func main() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let stateSource = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/ViewModels/ShelfStateViewModel.swift")
        )
        guard let addStart = stateSource.range(of: "func add(_ newItems: [ShelfItem])") else {
            throw TestFailure(message: "could not locate ShelfStateViewModel.add")
        }
        let addSource = String(stateSource[addStart.lowerBound...])

        try expect(
            addSource.contains("fastIdentityKey") && !addSource.contains("$0.identityKey"),
            "shelf insertion must not synchronously resolve every bookmark for deduplication"
        )

        let itemSource = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/Models/ShelfItem.swift")
        )
        try expect(
            itemSource.contains("var fastIdentityKey: String"),
            "ShelfItem must provide a non-blocking insertion identity"
        )

        let viewModelSource = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/ViewModels/ShelfItemViewModel.swift")
        )
        try expect(
            viewModelSource.contains("Task.detached(priority: .utility)"),
            "shelf metadata work must run outside the main actor"
        )

        print("ShelfDropPerformanceContractTests: PASS")
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
