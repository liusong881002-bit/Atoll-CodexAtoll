/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import CoreGraphics

enum NotchTabSizeSynchronizationPolicy {
    static func contentSizeAfterTabSwitch(
        isOpen: Bool,
        currentSize: CGSize,
        resolvedSize: CGSize
    ) -> CGSize {
        guard isOpen else { return currentSize }
        return resolvedSize
    }
}
