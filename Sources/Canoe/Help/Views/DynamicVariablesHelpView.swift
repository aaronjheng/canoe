import SwiftUI

/// Contents of the Dynamic Variables window (Help ▸ Dynamic Variables): the
/// full, always-current list of the Postman-style `{{$dynamic}}` generators,
/// one row per variable with a one-line explanation.
///
/// The list renders `DynamicVariables.entries` as-is (this is a reading aid,
/// not a second source of truth - new entries need no UI work). Clicking a
/// row copies its `{{$key}}` placeholder, so the sheet doubles as a picker.
struct DynamicVariablesHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                intro
                LazyVStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    ForEach(DynamicVariables.entries, id: \.key) { entry in
                        DynamicVariableRow(entry: entry)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.vertical, AppSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColor.controlBackground)
        // Window root: no control here takes focus, but the scroll view can
        // (see the focus-ring checklist in AGENTS.md).
        .focusEffectDisabled()
    }

    private var intro: some View {
        Text(
            "Dynamic variables generate a fresh value every time they resolve - no definition needed."
                + " Type {{ in any field and pick one from the Dynamic Variables section, or type $ to"
                + " filter the suggestions down to them. Click a row to copy its placeholder."
        )
        .font(AppFont.emptyStateBody)
        .foregroundStyle(AppColor.textSecondary)
    }
}

/// One dynamic-variables row: the `{{$key}}` placeholder, its explanation,
/// and a click that copies the placeholder (so the sheet doubles as a
/// picker). The copy acknowledgement is row-local - see
/// `CopyAcknowledgement`.
private struct DynamicVariableRow: View {
    let entry: DynamicVariables.Entry
    @State private var copyAck = CopyAcknowledgement()

    var body: some View {
        Button {
            copy()
        } label: {
            // Key and explanation stack vertically (like the inspector's
            // variable rows): a horizontal layout would let the trailing
            // copy glyph's width change - doc.on.doc vs checkmark - squeeze
            // the explanation into a different wrap on copy, and the row
            // height would jump every time it was clicked.
            HStack(alignment: .center, spacing: AppSpacing.medium) {
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text("{{\(entry.key)}}")
                        .font(AppFont.monoBody)
                        .foregroundStyle(AppColor.textPrimary)
                        .textSelection(.enabled)
                    Text(entry.summary)
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.textSecondary)
                }
                Spacer(minLength: 0)
                Group {
                    if copyAck.didCopy {
                        Image(systemName: "checkmark")
                            .foregroundStyle(AppColor.success)
                    } else {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
                .font(AppFont.iconRow)
            }
            .padding(.vertical, AppSpacing.xSmall)
            .padding(.horizontal, AppSpacing.small)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(copyAck.didCopy ? AppColor.selectionBackground : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help("Copy {{\(entry.key)}}")
    }

    private func copy() {
        // clearContents first, like every other copy path: a stale declared
        // type from a previous owner can otherwise survive and a paste
        // elsewhere may deliver the old content.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("{{\(entry.key)}}", forType: .string)
        copyAck.acknowledge()
    }
}
