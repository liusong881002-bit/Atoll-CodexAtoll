import Foundation

@main
struct ShelfFileDragContractTests {
    static func main() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("DynamicIsland/components/Shelf/Views/ShelfItemView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        guard let start = source.range(of: "private func createPasteboardItem(for item: ShelfItem)"),
              let end = source.range(of: "// MARK: - NSDraggingSource", range: start.upperBound..<source.endIndex)
        else {
            throw TestFailure(message: "could not locate the shelf drag pasteboard implementation")
        }

        let dragSource = String(source[start.lowerBound..<end.lowerBound])

        try expect(
            !dragSource.contains("DispatchSemaphore"),
            "file drag must not synchronously wait for an async main-actor bookmark resolution"
        )
        try expect(
            dragSource.contains("Bookmark(data: bookmarkData).resolve()"),
            "file drag must resolve the stored bookmark before beginning the AppKit drag session"
        )
        try expect(
            dragSource.contains("forType: .fileURL"),
            "file drag must advertise a real file URL so browser upload targets accept it"
        )

        print("ShelfFileDragContractTests: PASS")
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
