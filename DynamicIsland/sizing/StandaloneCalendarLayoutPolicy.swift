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

enum StandaloneCalendarLayoutPolicy {
    static let preferredOpenNotchHeight: CGFloat = 350

    static func resolvedOpenNotchHeight(
        baseHeight: CGFloat,
        showCalendar: Bool,
        enableMinimalisticUI: Bool,
        showStandardMediaControls: Bool,
        autoHideInactiveMediaPlayer: Bool,
        hasActiveMusicSession: Bool
    ) -> CGFloat {
        guard showCalendar, !enableMinimalisticUI else { return baseHeight }

        let mediaPlayerVisible = showStandardMediaControls
            && (!autoHideInactiveMediaPlayer || hasActiveMusicSession)
        guard !mediaPlayerVisible else { return baseHeight }

        return max(baseHeight, preferredOpenNotchHeight)
    }
}
