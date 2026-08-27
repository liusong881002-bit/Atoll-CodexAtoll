import AppKit
import Combine
import Defaults
import Foundation

@MainActor
final class CodexFeatureController: ObservableObject {
    static let shared = CodexFeatureController()

    static let hookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
        "SessionEnd",
    ]

    @Published private(set) var snapshot: CodexTaskStoreSnapshot
    @Published private(set) var diagnostics: CodexDiagnosticsSnapshot?
    @Published private(set) var helperInstallation: HookInstallationState?
    @Published private(set) var hooksInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastOperationMessage: String?
    @Published private(set) var lastError: String?

    private let paths: AppPaths
    private let processor: EventFileProcessor
    private let repository: StateRepository
    private let presentationCoordinator: CodexPresentationCoordinator
    private var store: CodexTaskStore
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var activityTrayPresentations = CodexActivityTrayPresentationRegistry()

    private static let defaultActivityTrayScreenKey = "__default__"

    init(
        paths: AppPaths = .default,
        presentationCoordinator: CodexPresentationCoordinator? = nil
    ) {
        self.paths = paths
        self.processor = EventFileProcessor(paths: paths)
        self.repository = StateRepository(paths: paths)
        self.presentationCoordinator = presentationCoordinator ?? CodexPresentationCoordinator()
        let restored = (try? repository.load()) ?? .empty
        self.store = CodexTaskStore(snapshot: restored)
        self.snapshot = restored
    }

    func start() {
        retireLegacyExternalExtension()
        performMigration()
        refreshInstallationState()
        observeSettings()
        if Defaults[.enableCodexIntegration] {
            enableRuntime(installIfAvailable: true)
        }
    }

    func stop() {
        finishAllActivityTrayPresentations()
        timer?.invalidate()
        timer = nil
        isRunning = false
        presentationCoordinator.dismiss()
    }

    func setEnabled(_ enabled: Bool) {
        Defaults[.enableCodexIntegration] = enabled
        if enabled {
            enableRuntime(installIfAvailable: true)
        } else {
            stop()
        }
    }

    func installOrRepair() {
        do {
            guard let helperSource = bundledHelperURL() else {
                throw CodexFeatureError.bundledHelperUnavailable
            }
            let installer = HookInstaller(paths: paths)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            _ = try installer.installHelper(from: helperSource, version: version)
            _ = try installer.installHooks(events: Self.hookEvents)
            refreshInstallationState()
            lastOperationMessage = "Codex Helper 和 Hooks 已安装或修复"
            lastError = nil
            if Defaults[.enableCodexIntegration] {
                enableRuntime(installIfAvailable: false)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstallHooks() {
        do {
            let removed = try HookInstaller(paths: paths).uninstallHooks()
            refreshInstallationState()
            lastOperationMessage = removed > 0 ? "已卸载 \(removed) 条 Codex Hook" : "没有发现 Codex Hook"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() {
        guard Defaults[.enableCodexIntegration] else { return }
        do {
            store.preferences.previewMode = Defaults[.codexShowContentPreviews] ? .projectAndPreview : .projectOnly
            var effects: [CodexStateEffect] = []
            _ = try processor.processInbox { [weak self] envelope in
                guard let self else { return }
                effects.append(contentsOf: self.store.apply(envelope))
            }
            effects.append(contentsOf: store.performMaintenance())
            if effects.contains(.persist) {
                try repository.save(store.snapshot)
            }
            snapshot = store.snapshot
            refreshInstallationState()
            diagnostics = try DiagnosticsCollector(paths: paths).collect(
                snapshot: snapshot,
                helperPath: helperInstallation?.helperPath,
                helperVersion: helperInstallation?.helperVersion,
                livenessPolicy: livenessPolicy
            )
            let completionSessionIDs = Defaults[.codexCompletionNotifications]
                ? effects.compactMap { effect -> String? in
                    guard case .showCompletion(let sessionID) = effect else { return nil }
                    guard !activityTrayPreferences.ignoredSessionIDs.contains(sessionID) else { return nil }
                    return sessionID
                }
                : []
            let runningSessionIDs = effects.compactMap { effect -> String? in
                guard case .showRunning(let sessionID) = effect else { return nil }
                guard !activityTrayPreferences.ignoredSessionIDs.contains(sessionID) else { return nil }
                return sessionID
            }
            presentationCoordinator.update(
                snapshot: presentationSnapshot(),
                runningSessionIDs: runningSessionIDs,
                completionSessionIDs: completionSessionIDs,
                ignoredSessionIDs: activityTrayPreferences.ignoredSessionIDs,
                livenessPolicy: livenessPolicy
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshPresentation() {
        guard Defaults[.enableCodexIntegration] else {
            presentationCoordinator.dismiss()
            return
        }
        presentationCoordinator.update(
            snapshot: presentationSnapshot(),
            ignoredSessionIDs: activityTrayPreferences.ignoredSessionIDs,
            livenessPolicy: livenessPolicy,
            interruptActivePulse: true
        )
    }

    func acknowledgeCompletions() {
        guard Defaults[.enableCodexIntegration] else { return }
        let effects = store.acknowledgeCompletions()
        guard !effects.isEmpty else { return }

        do {
            try repository.save(store.snapshot)
            snapshot = store.snapshot
            presentationCoordinator.update(
                snapshot: presentationSnapshot(),
                ignoredSessionIDs: activityTrayPreferences.ignoredSessionIDs,
                livenessPolicy: livenessPolicy,
                interruptActivePulse: true
            )
            lastError = nil
        } catch {
            lastError = "清除 Codex 已完成计数失败：\(error.localizedDescription)"
        }
    }

    func acknowledgeCompletion(sessionID: String) {
        acknowledgeCompletions(sessionIDs: [sessionID])
    }

    @discardableResult
    func beginActivityTrayPresentation(
        screenID: String?,
        presentationID: UUID
    ) -> Bool {
        let key = activityTrayScreenKey(screenID)
        guard let result = activityTrayPresentations.beginPresentation(
            screenKey: key,
            presentationID: presentationID
        ) else {
            CodexActivityTrayDiagnostics.log(
                event: "presentation.begin.ignored",
                screenKey: key,
                presentationID: presentationID,
                completionCount: 0,
                detail: "reason=stale_presentation"
            )
            return false
        }
        CodexActivityTrayDiagnostics.log(
            event: "presentation.begin",
            screenKey: key,
            presentationID: result.presentationID,
            completionCount: result.exposedCompletionIDs.count
        )
        return true
    }

    func updateActivityTrayVisibility(
        visibleItems: [CodexActivityTrayItem],
        allUnreadItems: [CodexActivityTrayItem],
        screenID: String?,
        presentationID: UUID
    ) {
        let key = activityTrayScreenKey(screenID)
        let contentSignature = allUnreadItems.compactMap(\.completionID)
        let visibleCompletionIDs = Set(visibleItems.compactMap(\.completionID))
        let activePresentationID = activityTrayPresentations.presentationID(screenKey: key)
        guard let newlyExposedCompletionIDs = activityTrayPresentations.updateVisibility(
            screenKey: key,
            presentationID: presentationID,
            contentSignature: contentSignature,
            visibleCompletionIDs: visibleCompletionIDs
        ) else {
            CodexActivityTrayDiagnostics.log(
                event: "visibility.ignored",
                screenKey: key,
                presentationID: presentationID,
                completionCount: visibleCompletionIDs.count,
                detail: "reason=\(activePresentationID == nil ? "missing_presentation" : "stale_presentation") content=\(contentSignature.count)"
            )
            return
        }
        CodexActivityTrayDiagnostics.log(
            event: "visibility.updated",
            screenKey: key,
            presentationID: presentationID,
            completionCount: visibleCompletionIDs.count,
            detail: "content=\(contentSignature.count) newly_exposed=\(newlyExposedCompletionIDs.count)"
        )
        guard !newlyExposedCompletionIDs.isEmpty else { return }
        recordCompletionPresentations(
            completionIDs: newlyExposedCompletionIDs,
            screenKey: key,
            presentationID: presentationID
        )
    }

    func finishActivityTrayPresentation(
        screenID: String?,
        presentationID: UUID? = nil
    ) {
        let key = activityTrayScreenKey(screenID)
        let source = presentationID == nil ? "host_teardown" : "view_disappear"
        guard let activePresentationID = activityTrayPresentations.presentationID(screenKey: key) else {
            CodexActivityTrayDiagnostics.log(
                event: "presentation.finish.ignored",
                screenKey: key,
                presentationID: presentationID,
                completionCount: 0,
                detail: "reason=missing_presentation source=\(source)"
            )
            return
        }
        if let presentationID, presentationID != activePresentationID {
            CodexActivityTrayDiagnostics.log(
                event: "presentation.finish.ignored",
                screenKey: key,
                presentationID: presentationID,
                completionCount: 0,
                detail: "reason=stale_presentation source=\(source)"
            )
            return
        }
        let completionIDs = activityTrayPresentations.finishPresentation(
            screenKey: key,
            presentationID: activePresentationID
        )
        CodexActivityTrayDiagnostics.log(
            event: "presentation.finish",
            screenKey: key,
            presentationID: activePresentationID,
            completionCount: completionIDs.count,
            detail: "source=\(source)"
        )
        guard !completionIDs.isEmpty else { return }
        acknowledgeCompletions(
            completionIDs: completionIDs,
            screenKey: key,
            presentationID: activePresentationID,
            source: source
        )
    }

    func finishAllActivityTrayPresentations() {
        for key in activityTrayPresentations.activeScreenKeys {
            guard let presentationID = activityTrayPresentations.presentationID(screenKey: key) else {
                continue
            }
            let completionIDs = activityTrayPresentations.finishPresentation(
                screenKey: key,
                presentationID: presentationID
            )
            CodexActivityTrayDiagnostics.log(
                event: "presentation.finish",
                screenKey: key,
                presentationID: presentationID,
                completionCount: completionIDs.count,
                detail: "source=runtime_stop"
            )
            guard !completionIDs.isEmpty else { continue }
            acknowledgeCompletions(
                completionIDs: completionIDs,
                screenKey: key,
                presentationID: presentationID,
                source: "runtime_stop"
            )
        }
    }

    func recordCompletionPresentations(
        completionIDs: Set<UUID>,
        screenKey: String = "all",
        presentationID: UUID? = nil
    ) {
        guard Defaults[.enableCodexIntegration] else { return }
        let presentedBefore = Set(store.snapshot.presentedCompletionIDs ?? [])
        let effects = store.recordCompletionPresentations(completionIDs: completionIDs)
        guard !effects.isEmpty else {
            CodexActivityTrayDiagnostics.log(
                event: "presentation.record.skipped",
                screenKey: screenKey,
                presentationID: presentationID,
                completionCount: completionIDs.count,
                detail: "reason=no_state_change"
            )
            return
        }

        do {
            try repository.save(store.snapshot)
            snapshot = store.snapshot
            let presentedAfter = Set(snapshot.presentedCompletionIDs ?? [])
            CodexActivityTrayDiagnostics.log(
                event: "presentation.recorded",
                screenKey: screenKey,
                presentationID: presentationID,
                completionCount: presentedAfter.subtracting(presentedBefore).count
            )
            lastError = nil
        } catch {
            let nsError = error as NSError
            CodexActivityTrayDiagnostics.log(
                event: "presentation.record.failed",
                screenKey: screenKey,
                presentationID: presentationID,
                completionCount: completionIDs.count,
                detail: "error_domain=\(nsError.domain) error_code=\(nsError.code)"
            )
            lastError = "记录 Codex 完成展示状态失败：\(error.localizedDescription)"
        }
    }

    func acknowledgeCompletions(sessionIDs: Set<String>) {
        guard Defaults[.enableCodexIntegration] else { return }
        var didChange = false
        for sessionID in sessionIDs where !sessionID.isEmpty {
            if !store.acknowledgeCompletion(sessionID: sessionID).isEmpty {
                didChange = true
            }
        }
        guard didChange else { return }

        do {
            try repository.save(store.snapshot)
            snapshot = store.snapshot
            presentationCoordinator.update(
                snapshot: presentationSnapshot(),
                ignoredSessionIDs: activityTrayPreferences.ignoredSessionIDs,
                livenessPolicy: livenessPolicy
            )
            lastError = nil
        } catch {
            lastError = "更新 Codex 完成状态失败：\(error.localizedDescription)"
        }
    }

    func acknowledgeCompletions(
        completionIDs: Set<UUID>,
        screenKey: String = "all",
        presentationID: UUID? = nil,
        source: String = "direct"
    ) {
        guard Defaults[.enableCodexIntegration] else { return }
        let acknowledgedBefore = Set(store.snapshot.acknowledgedCompletionIDs ?? [])
        let unreadBefore = store.snapshot.unacknowledgedCompletions.count
        let effects = store.acknowledgeCompletions(completionIDs: completionIDs)
        guard !effects.isEmpty else {
            CodexActivityTrayDiagnostics.log(
                event: "completion.acknowledge.skipped",
                screenKey: screenKey,
                presentationID: presentationID,
                completionCount: completionIDs.count,
                detail: "reason=no_state_change source=\(source) unread_before=\(unreadBefore)"
            )
            return
        }

        do {
            try repository.save(store.snapshot)
            snapshot = store.snapshot
            presentationCoordinator.update(
                snapshot: presentationSnapshot(),
                ignoredSessionIDs: activityTrayPreferences.ignoredSessionIDs,
                livenessPolicy: livenessPolicy,
                interruptActivePulse: true
            )
            let acknowledgedAfter = Set(snapshot.acknowledgedCompletionIDs ?? [])
            CodexActivityTrayDiagnostics.log(
                event: "completion.acknowledged",
                screenKey: screenKey,
                presentationID: presentationID,
                completionCount: acknowledgedAfter.subtracting(acknowledgedBefore).count,
                detail: "source=\(source) exposed_checkpoints=\(completionIDs.count) unread_before=\(unreadBefore) unread_after=\(snapshot.unacknowledgedCompletions.count)"
            )
            lastError = nil
        } catch {
            let nsError = error as NSError
            CodexActivityTrayDiagnostics.log(
                event: "completion.acknowledge.failed",
                screenKey: screenKey,
                presentationID: presentationID,
                completionCount: completionIDs.count,
                detail: "source=\(source) error_domain=\(nsError.domain) error_code=\(nsError.code)"
            )
            lastError = "更新 Codex 完成状态失败：\(error.localizedDescription)"
        }
    }

    private func activityTrayScreenKey(_ screenID: String?) -> String {
        guard let screenID, !screenID.isEmpty else {
            return Self.defaultActivityTrayScreenKey
        }
        return screenID
    }

    func openCodexConversation(sessionID: String) {
        guard let url = CodexAppLink.url(forSessionID: sessionID) else {
            lastError = "无法打开 Codex 对话"
            return
        }

        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(
            withBundleIdentifier: CodexAppLink.appBundleIdentifier
        ) ?? workspace.urlForApplication(toOpen: url) else {
            lastError = "找不到可打开 Codex 对话的应用"
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([url], withApplicationAt: appURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            let errorMessage = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.lastError = "无法打开 Codex 对话：\(errorMessage)"
            }
        }
        lastError = nil
    }

    func openDataDirectory() {
        try? paths.prepareDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([paths.root])
    }

    var activityTrayPreferences: CodexActivityTrayPreferences {
        CodexActivityTrayPreferences(
            pinnedProjectNames: Set(Defaults[.codexPinnedProjectNames]),
            ignoredSessionIDs: Set(Defaults[.codexIgnoredSessionIDs])
        )
    }

    var livenessPolicy: CodexTaskLivenessPolicy {
        CodexTaskLivenessPolicy(preferences: store.preferences)
    }

    func setProjectPinned(_ projectName: String, pinned: Bool) {
        var names = Set(Defaults[.codexPinnedProjectNames])
        if pinned {
            names.insert(projectName)
        } else {
            names.remove(projectName)
        }
        Defaults[.codexPinnedProjectNames] = names.sorted()
        refreshPresentation()
    }

    func setSessionIgnored(_ sessionID: String, ignored: Bool) {
        var sessionIDs = Set(Defaults[.codexIgnoredSessionIDs])
        if ignored {
            sessionIDs.insert(sessionID)
        } else {
            sessionIDs.remove(sessionID)
        }
        Defaults[.codexIgnoredSessionIDs] = sessionIDs.sorted()
        refreshPresentation()
    }

    func markSessionInterrupted(_ sessionID: String) {
        guard Defaults[.enableCodexIntegration] else { return }
        let effects = store.markInterrupted(sessionID: sessionID)
        guard !effects.isEmpty else { return }

        do {
            try repository.save(store.snapshot)
            snapshot = store.snapshot
            presentationCoordinator.update(
                snapshot: presentationSnapshot(),
                ignoredSessionIDs: activityTrayPreferences.ignoredSessionIDs,
                livenessPolicy: livenessPolicy,
                interruptActivePulse: true
            )
            lastError = nil
        } catch {
            lastError = "标记 Codex 任务中断失败：\(error.localizedDescription)"
        }
    }

    private func enableRuntime(installIfAvailable: Bool) {
        if installIfAvailable && (!hooksInstalled || helperInstallation == nil), bundledHelperURL() != nil {
            installOrRepair()
        }
        timer?.invalidate()
        isRunning = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func observeSettings() {
        guard cancellables.isEmpty else { return }
        Publishers.MergeMany([
            Defaults.publisher(.codexShowClosedStatus).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.codexShowTaskTab).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.codexShowContentPreviews).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.codexShowInFullscreen).map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refreshPresentation() }
        .store(in: &cancellables)
    }

    private func presentationSnapshot() -> CodexTaskStoreSnapshot {
        guard !Defaults[.codexShowContentPreviews] else { return snapshot }
        var redacted = snapshot
        for index in redacted.tasks.indices {
            redacted.tasks[index].promptPreview = nil
            redacted.tasks[index].resultPreview = nil
            redacted.tasks[index].approvalPreview = nil
        }
        redacted.recentCompletions = redacted.recentCompletions.map { completion in
            CodexCompletionRecord(
                id: completion.id,
                sessionID: completion.sessionID,
                projectName: completion.projectName,
                promptPreview: nil,
                resultPreview: nil,
                completedAt: completion.completedAt
            )
        }
        return redacted
    }

    private func performMigration() {
        do {
            let result = try CodexDataMigrator(paths: paths).migrateIfNeeded()
            if result.importedLegacyState {
                let restored = (try? repository.load()) ?? .empty
                store = CodexTaskStore(snapshot: restored)
                snapshot = restored
                Defaults[.enableCodexIntegration] = true
                lastOperationMessage = "已迁移旧 CodexAtoll 状态"
            }
        } catch {
            lastError = "迁移旧 CodexAtoll 数据失败：\(error.localizedDescription)"
        }
    }

    private func retireLegacyExternalExtension() {
        for bundleIdentifier in CodexPresentationConstants.legacyExternalBundleIdentifiers {
            ExtensionLiveActivityManager.shared.dismiss(
                activityID: CodexPresentationConstants.liveActivityID,
                bundleIdentifier: bundleIdentifier
            )
            ExtensionNotchExperienceManager.shared.dismiss(
                experienceID: CodexPresentationConstants.experienceID,
                bundleIdentifier: bundleIdentifier
            )
            ExtensionAuthorizationManager.shared.removeEntry(bundleIdentifier: bundleIdentifier)
        }
    }

    private func refreshInstallationState() {
        let installer = HookInstaller(paths: paths)
        helperInstallation = try? installer.loadInstallationState()
        let hooksConfig = try? installer.readHooksConfig()
        hooksInstalled = Self.hookEvents.allSatisfy { event in
            let groups = hooksConfig?.objectValue?["hooks"]?.objectValue?[event]?.arrayValue ?? []
            return groups.contains { group in
                let entries = group.objectValue?["hooks"]?.arrayValue ?? []
                return entries.contains {
                    HookConfigMerger.isProjectHook($0, helperCommand: installer.helperCommand)
                }
            }
        }
    }

    private func bundledHelperURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexHookHelper"),
            Bundle.main.url(forAuxiliaryExecutable: "CodexHookHelper"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private enum CodexFeatureError: LocalizedError {
    case bundledHelperUnavailable

    var errorDescription: String? {
        switch self {
        case .bundledHelperUnavailable:
            return "Atoll App 包中找不到 CodexHookHelper"
        }
    }
}
