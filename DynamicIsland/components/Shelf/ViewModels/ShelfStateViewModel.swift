/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AppKit

struct ShelfAddEvent: Equatable, Sendable {
    let itemIDs: [UUID]
    let count: Int
    let focusShelf: Bool
    let token: UUID
}

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet {
            ShelfPersistenceService.shared.save(items)
            ShelfSelectionModel.shared.reconcileSelection(with: items)
        }
    }

    @Published var isLoading: Bool = false
    @Published private(set) var lastAddEvent: ShelfAddEvent?
    @Published private(set) var addFeedbackMessage: String?

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?
    private var addFeedbackTask: Task<Void, Never>?
    
    // Cache for URL-to-item mapping to avoid resolving all bookmarks for lookup
    private var urlToItemCache: [String: ShelfItem.ID] = [:]
    private var urlCacheInvalidated = true

    private init() {
        items = ShelfPersistenceService.shared.load()
    }


    @discardableResult
    func add(_ newItems: [ShelfItem]) -> ShelfAddEvent? {
        add(newItems, focusShelf: false)
    }

    @discardableResult
    func add(_ newItems: [ShelfItem], focusShelf: Bool) -> ShelfAddEvent? {
        guard !newItems.isEmpty else { return nil }
        var merged = items
        // Deduplicate without synchronously resolving security-scoped
        // bookmarks on the main actor. The resolved identity remains
        // available for async lookup paths, while insertion uses the stable
        // bookmark payload as a fast key.
        var seen: Set<String> = Set(merged.map { $0.fastIdentityKey })
        var addedIDs: [String] = []
        for it in newItems {
            let key = it.fastIdentityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
                addedIDs.append(it.id.uuidString)
            }
        }
        guard !addedIDs.isEmpty else { return nil }

        items = merged
        invalidateURLCache()
        let event = ShelfAddEvent(
            itemIDs: addedIDs.compactMap(UUID.init(uuidString:)),
            count: addedIDs.count,
            focusShelf: focusShelf,
            token: UUID()
        )
        lastAddEvent = event
        addFeedbackMessage = String(localized: "Added to Shelf")
        scheduleAddFeedbackReset(for: event)
        ExtensionRPCServer.shared.notifyShelfItemsChanged(itemIDs: addedIDs, action: "added")
        return event
    }

    private func scheduleAddFeedbackReset(for event: ShelfAddEvent) {
        addFeedbackTask?.cancel()
        addFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self,
                  self.lastAddEvent?.token == event.token else { return }
            self.lastAddEvent = nil
            self.addFeedbackMessage = nil
        }
    }

    func remove(_ item: ShelfItem) {
        remove([item])
    }

    func remove(_ itemsToRemove: [ShelfItem]) {
        guard !itemsToRemove.isEmpty else { return }

        let ids = Set(itemsToRemove.map(\.id))
        let removedItems = items.filter { ids.contains($0.id) }
        guard !removedItems.isEmpty else { return }

        // Publish the in-memory/persisted Shelf change immediately. Cleanup of
        // Atoll-owned temporary copies is deliberately deferred so the UI and
        // the clear action never wait on bookmark resolution or file I/O.
        items.removeAll { ids.contains($0.id) }
        invalidateURLCache()
        ExtensionRPCServer.shared.notifyShelfItemsChanged(
            itemIDs: removedItems.map { $0.id.uuidString },
            action: "removed"
        )

        Task { @MainActor in
            for item in removedItems {
                await item.cleanupStoredDataAsync()
            }
        }
    }

    func clear() {
        remove(items)
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
        invalidateURLCache()
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider], policy: ShelfDropPolicy = .all) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers, policy: policy)
            await MainActor.run {
                self?.add(dropped, focusShelf: policy == .filesOnly)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var keep: [ShelfItem] = []
            for item in self.items {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if await bookmark.validate() {
                        keep.append(item)
                    } else {
                        await item.cleanupStoredDataAsync()
                    }
                default:
                    keep.append(item)
                }
            }
            await MainActor.run { self.items = keep }
        }
    }

    // Async version that resolves bookmark on background thread
    func resolveFileURLAsync(for item: ShelfItem) async -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = await bookmark.resolveAsync()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            await MainActor.run { scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed) }
        }
        return result.url
    }

    // Async version for user-initiated actions
    func resolveAndUpdateBookmarkAsync(for item: ShelfItem) async -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = await bookmark.resolveAsync()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            await MainActor.run { updateBookmark(for: item, bookmark: refreshed) }
        }
        return result.url
    }

    // Find item by URL using cached mapping (avoids resolving all bookmarks)
    func findItem(by url: URL) async -> ShelfItem? {
        let path = url.standardizedFileURL.path
        if urlCacheInvalidated {
            await rebuildURLCache()
        }
        if let itemID = urlToItemCache[path],
           let idx = items.firstIndex(where: { $0.id == itemID }) {
            return items[idx]
        }
        // Fallback: async resolution for cache miss
        for itm in items {
            if case .file = itm.kind {
                if let resolved = await resolveFileURLAsync(for: itm),
                   resolved.standardizedFileURL.path == path {
                    return itm
                }
            }
        }
        return nil
    }

    // Sync wrapper for backward compatibility
    func findItemSync(by url: URL) -> ShelfItem? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: ShelfItem?
        Task.detached { [weak self] in
            guard let self = self else { return }
            result = await self.findItem(by: url)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5.0)
        return result
    }
    
    private func rebuildURLCache() async {
        urlToItemCache.removeAll()
        for item in items {
            if case .file(let bookmarkData) = item.kind {
                let bookmark = Bookmark(data: bookmarkData)
                let result = await bookmark.resolveAsync()
                if let url = result.url {
                    urlToItemCache[url.standardizedFileURL.path] = item.id
                }
            }
        }
        urlCacheInvalidated = false
    }
    
    private func invalidateURLCache() {
        urlCacheInvalidated = true
    }

    // Async version - resolves file URLs without blocking
    func resolveFileURLsAsync(for items: [ShelfItem]) async -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = await resolveFileURLAsync(for: it) { urls.append(u) }
        }
        return urls
    }

    // Sync wrapper for backward compatibility - resolves on background thread with timeout
    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [URL] = []
        Task.detached { [weak self] in
            guard let self = self else { return }
            result = await self.resolveFileURLsAsync(for: items)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10.0)
        return result
    }
}
