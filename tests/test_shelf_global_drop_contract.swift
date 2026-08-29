import Foundation

@main
struct ShelfGlobalDropContractTests {
    static func main() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let contentView = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/ContentView.swift")
        )
        let service = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/Services/ShelfDropService.swift")
        )
        let stateViewModel = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Shelf/ViewModels/ShelfStateViewModel.swift")
        )
        let settings = try read(
            repositoryRoot.appendingPathComponent("DynamicIsland/components/Settings/SettingsView.swift")
        )

        guard let detectorStart = contentView.range(of: "var dragDetector: some View") else {
            throw TestFailure(message: "could not locate the root drag detector")
        }
        let detector = String(contentView[detectorStart.lowerBound...])

        try expect(
            detector.contains("ShelfDropService.globalSupportedTypes"),
            "the root drag detector must advertise the shared global shelf drop types"
        )
        try expect(
            detector.contains("ShelfStateViewModel.shared.load(providers, policy: .filesOnly)"),
            "the root drag detector must route accepted files into ShelfStateViewModel"
        )
        try expect(
            detector.contains("if expandedDragDetection"),
            "the global drop target must be controlled by the expanded drag setting"
        )

        try expect(
            service.contains("enum ShelfDropPolicy") && service.contains("case filesOnly"),
            "ShelfDropService must expose a file-only global drop policy"
        )
        try expect(
            service.contains("globalSupportedTypes")
                && service.contains("com.apple.filepromise")
                && service.contains("UTType.text.identifier")
                && service.contains("UTType.url.identifier"),
            "global drop filtering must account for file promises and reject text or URL payloads"
        )
        try expect(
            stateViewModel.contains("func load(_ providers: [NSItemProvider], policy: ShelfDropPolicy = .all)"),
            "ShelfStateViewModel must keep one shared ingestion entry point with an explicit policy"
        )

        try expect(
            settings.contains("title: \"Drop files anywhere into Shelf\""),
            "settings search must expose the global shelf drop option"
        )
        try expect(
            settings.contains("Text(\"Drop files anywhere into Shelf\")"),
            "Shelf settings must expose the global shelf drop option"
        )

        print("ShelfGlobalDropContractTests: PASS")
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
