import AppKit
import Plume
import SwiftUI

/// Installs Canoe's chrome into Plume's `EditorTheme` seam: the one-time,
/// launch-time assignment of every token the editor base library reads.
/// Colors are dynamic (light/dark adaptive), so a single install at launch
/// keeps both appearances correct; nothing re-reads these after startup.
enum EditorThemeInstallation {
    static func install() {
        // Semantic colors
        EditorTheme.accent = AppColor.accent
        EditorTheme.success = AppColor.success
        EditorTheme.error = AppColor.error
        EditorTheme.warning = AppColor.warning
        EditorTheme.textPrimary = AppColor.textPrimary
        EditorTheme.textSecondary = AppColor.textSecondary
        EditorTheme.tertiaryText = AppColor.tertiaryText
        EditorTheme.border = AppColor.border
        EditorTheme.borderStrong = AppColor.borderStrong
        EditorTheme.destructiveBorder = AppColor.destructiveBorder
        EditorTheme.controlBackground = AppColor.controlBackground
        EditorTheme.fieldBackground = AppColor.fieldBackground
        EditorTheme.subtleBackground = AppColor.subtleBackground
        EditorTheme.tabHoverBackground = AppColor.tabHoverBackground
        EditorTheme.tabActiveBackground = AppColor.tabActiveBackground
        EditorTheme.popupShadow = AppColor.popupShadow

        // AppKit fills
        EditorTheme.textPrimaryNS = AppColor.textPrimaryNS
        EditorTheme.codeBackgroundNS = AppColor.codeBackgroundNS

        // Syntax palette (the GitHub-ish token colors)
        EditorTheme.syntaxKey = AppColor.syntaxKey
        EditorTheme.syntaxString = AppColor.syntaxString
        EditorTheme.syntaxNumber = AppColor.syntaxNumber
        EditorTheme.syntaxKeyword = AppColor.syntaxKeyword
        EditorTheme.syntaxPlain = AppColor.syntaxPlain

        // Fonts
        EditorTheme.fontSmall = AppFont.small
        EditorTheme.fontMonoSubheadline = AppFont.monoSubheadline
        EditorTheme.fontMonoBody = AppFont.monoBody
        EditorTheme.fontMonoURLBar = AppFont.monoURLBar
        EditorTheme.fontMonoCaption = AppFont.monoCaption
        EditorTheme.fontIconCompact = AppFont.iconCompact

        // Metrics
        EditorTheme.spaceXSmall = AppSpacing.xSmall
        EditorTheme.spaceSmall = AppSpacing.small
        EditorTheme.spaceCompact = AppSpacing.compact
        EditorTheme.spaceMedium = AppSpacing.medium
        EditorTheme.radiusSmall = AppRadius.small
        EditorTheme.radiusMedium = AppRadius.medium
        EditorTheme.lineField = AppLine.field
        EditorTheme.lineFocusedField = AppLine.focusedField
        EditorTheme.toggleControlSize = AppSize.topBarControlHeight
        EditorTheme.opacityDisabled = AppOpacity.disabled
        EditorTheme.motionQuick = AppMotion.quick
    }
}
