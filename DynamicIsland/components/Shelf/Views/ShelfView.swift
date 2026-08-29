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

import SwiftUI
import AppKit

private struct ShelfBackgroundClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> BackgroundClickView {
        let view = BackgroundClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: BackgroundClickView, context: Context) {
        nsView.onClick = onClick
    }

    final class BackgroundClickView: NSView {
        var onClick: (() -> Void)?

        override func mouseUp(with event: NSEvent) {
            onClick?()
        }
    }
}

struct ShelfView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    @State private var showClearConfirmation = false
    @State private var clearConfirmationAutoCloseToken = UUID()
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
        .onChange(of: showClearConfirmation) { _, isShowing in
            vm.setAutoCloseSuppression(
                isShowing,
                token: clearConfirmationAutoCloseToken
            )
        }
        .onDisappear {
            vm.setAutoCloseSuppression(
                false,
                token: clearConfirmationAutoCloseToken
            )
        }
        .onDeleteCommand {
            removeSelectedItems()
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }

        let selectedItems = selection.selectedItems(in: tvm.items)
        let capturedIDs = selection.selectedIDs

        Task {
            var urls: [URL] = []
            for item in selectedItems {
                if let fileURL = await ShelfStateViewModel.shared.resolveFileURLAsync(for: item) {
                    urls.append(fileURL)
                } else if case .link(let url) = item.kind {
                    urls.append(url)
                }
            }

            if !urls.isEmpty {
                await MainActor.run {
                    // Only update if selection hasn't changed since we started resolving
                    if selection.selectedIDs == capturedIDs {
                        quickLookService.updateSelection(urls: urls)
                    }
                }
            }
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                ZStack {
                    ShelfBackgroundClickCatcher {
                        guard !selection.isDragging else { return }
                        selection.clear()
                    }

                    content
                        .padding()

                    if let message = tvm.addFeedbackMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(message)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.green.opacity(0.55), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        .allowsHitTesting(false)
                        .transition(
                            .move(edge: .top)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.94))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                    }

                    if !tvm.isEmpty {
                        VStack {
                            HStack(spacing: 6) {
                                if selection.hasSelection {
                                    Button(action: removeSelectedItems) {
                                        Image(systemName: "minus.circle")
                                            .font(.system(size: 13, weight: .semibold))
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.white)
                                    .background(Circle().fill(Color.black.opacity(0.72)))
                                    .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                                    .help("Remove selected items from Shelf (Delete)")
                                    .accessibilityLabel("Remove selected items from Shelf")
                                    .keyboardShortcut(.delete, modifiers: [])
                                }

                                Button(action: {
                                    // Claim the auto-close suppression before the
                                    // confirmation dialog moves focus outside the notch.
                                    vm.setAutoCloseSuppression(
                                        true,
                                        token: clearConfirmationAutoCloseToken
                                    )
                                    showClearConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white)
                                .background(Circle().fill(Color.black.opacity(0.72)))
                                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                                .help("Clear Shelf only; original files stay untouched (⌘Delete)")
                                .accessibilityLabel("Clear Shelf only; original files stay untouched")
                                .keyboardShortcut(.delete, modifiers: .command)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(10)
                    }

                    if showClearConfirmation {
                        clearConfirmationCard
                            .zIndex(20)
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: tvm.addFeedbackMessage)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showClearConfirmation)
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
    }

    private func removeSelectedItems() {
        let selectedItems = selection.selectedItems(in: tvm.items)
        guard !selectedItems.isEmpty else { return }
        tvm.remove(selectedItems)
        selection.clear()
    }

    private var clearConfirmationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.orange)
                Text("清空文件暂存？")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }

            Text("仅移除 Atoll 中的暂存记录，原文件不会被删除。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("取消") {
                    showClearConfirmation = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 64, minHeight: 28)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                )

                Button("清空暂存", role: .destructive) {
                    tvm.clear()
                    selection.clear()
                    showClearConfirmation = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .frame(minWidth: 78, minHeight: 28)
                .background(
                    Capsule()
                        .fill(Color.red.opacity(0.16))
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 10, y: 4)
        .padding(12)
        .transition(
            .scale(scale: 0.96)
                .combined(with: .opacity)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("清空文件暂存确认")
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}
