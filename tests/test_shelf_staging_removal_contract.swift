import Foundation

@main
struct ShelfStagingRemovalContractTests {
    static func main() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let shelfView = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/Views/ShelfView.swift")
        )
        let shelfItemView = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/Views/ShelfItemView.swift")
        )
        try expect(
            shelfView.contains(".onDeleteCommand")
                && !shelfView.contains(".confirmationDialog")
                && shelfView.contains("keyboardShortcut(.delete, modifiers: .command)")
                && shelfView.contains("clearConfirmationAutoCloseToken")
                && shelfView.contains("setAutoCloseSuppression(")
                && shelfView.contains("isShowing")
                && shelfView.contains("true,")
                && shelfView.contains("showClearConfirmation = true")
                && shelfView.contains("清空文件暂存？")
                && shelfView.contains("清空暂存")
                && shelfView.contains("原文件不会被删除"),
            "Shelf must use an inline Chinese clear confirmation without a system modal"
        )
        try expect(
            shelfItemView.contains("Remove from Shelf only")
                && shelfView.contains("原文件不会被删除"),
            "removal controls must clearly describe staging-only semantics"
        )

        let stateSource = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/ViewModels/ShelfStateViewModel.swift")
        )
        try expect(
            stateSource.contains("func remove(_ itemsToRemove: [ShelfItem])")
                && stateSource.contains("func clear()"),
            "Shelf state must expose batch removal and clear operations"
        )
        try expect(
            stateSource.contains("await item.cleanupStoredDataAsync()")
                && !stateSource.contains("FileManager.default.removeItem"),
            "Shelf state must defer cleanup and never delete source files directly"
        )

        let itemSource = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/Models/ShelfItem.swift")
        )
        try expect(
            itemSource.contains("func cleanupStoredDataAsync() async")
                && itemSource.contains("guard isTemporary, case let .file(bookmark) = kind else { return }"),
            "backing-file cleanup must be restricted to Atoll-owned temporary items"
        )

        print("ShelfStagingRemovalContractTests: PASS")
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
