import AppKit
import SwiftUI

/// The "Code Snippet" inspector on the right edge of the detail area
/// (Postman-style): renders the currently selected request as
/// copy-pasteable HTTP / cURL / HTTPie code, with variables already resolved
/// exactly as a real send would resolve them.
///
/// Without a request it shows an actionable empty state pointing at the
/// sidebar instead of an empty panel.
struct CodeSnippetSidebarView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("codeSnippetLanguage") private var languageRaw = CodeSnippetLanguage.curl.rawValue
    @State private var copied = false

    private var language: CodeSnippetLanguage {
        CodeSnippetLanguage(rawValue: languageRaw) ?? .curl
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.selectedRequest != nil {
                pickerBar
                Divider()
                codeArea
            } else {
                emptyState
            }
        }
        // Greedy in both dimensions so the panel fills the inspector pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.sidebarBackground)
    }

    // MARK: - Header

    private var header: some View {
        InspectorHeader(closeHelp: "Hide Code Snippet") {
            store.showCodeSnippetSidebar = false
        }
    }

    // MARK: - Picker + code

    private var pickerBar: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Picker("Language", selection: $languageRaw) {
                ForEach(CodeSnippetLanguage.allCases) { language in
                    Text(language.rawValue).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help("Snippet language")
            Spacer(minLength: 0)
            copyButton
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
    }

    /// Icon-only copy, mirroring Postman's snippet toolbar.
    private var copyButton: some View {
        Button {
            copySnippet()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.subheadline)
                .foregroundStyle(copied ? AppColor.success : .secondary)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(copied)
        .help("Copy snippet to the clipboard")
    }

    private var code: String {
        guard let request = store.selectedRequest else { return "" }
        return CodeSnippetGenerator.generate(
            request: request,
            variables: store.variablesForRequest(request),
            authorization: store.authorizationForRequest(request),
            language: CodeSnippetLanguage(rawValue: languageRaw) ?? .curl
        )
    }

    /// Postman-style code pane with a line-number gutter. Lines render as
    /// individual rows so the gutter stays aligned; long lines wrap at the
    /// pane width, with the row number on the first visual line.
    private var codeArea: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // Computed once: `code` regenerates the whole snippet, so
                // evaluating it per line below would redo it N+1 times.
                let snippet = code
                let lines = snippet.components(separatedBy: "\n")
                // For the raw HTTP format, headers run until the first
                // blank line; everything after it is body.
                let httpBlank = language == .http ? lines.firstIndex(where: { $0.isEmpty }) : nil
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    let isBody = httpBlank.map { index > $0 } ?? false
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.medium) {
                        Text("\(index + 1)")
                            .font(AppFont.monoSubheadline)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(
                            SnippetHighlighter.attributedLine(
                                line,
                                language: language,
                                isFirstLine: index == 0,
                                isBody: isBody
                            )
                        )
                        .font(AppFont.monoSubheadline)
                        .textSelection(.enabled)
                        // Wrap at the pane width instead of scrolling
                        // horizontally; the gutter number stays on the
                        // first visual line via the baseline alignment.
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(AppSpacing.medium)
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.small) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Request Selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open a request to generate its code snippet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Snippet syntax highlighting

/// Lightweight line-based syntax coloring for the generated snippets,
/// reusing the app's existing syntax palette (no grammars needed for the
/// three shell/HTTP formats).
private enum SnippetHighlighter {
    static func attributedLine(
        _ line: String,
        language: CodeSnippetLanguage,
        isFirstLine: Bool,
        isBody: Bool
    ) -> AttributedString {
        var result = AttributedString(line)
        switch language {
        case .curl, .httpie:
            color(result: &result, pattern: "(?:^|\\s)(-{1,2}[A-Za-z][A-Za-z0-9-]*)", capture: 1, color: AppColor.syntaxKey)
            color(result: &result, pattern: "'(?:[^'\\\\]|\\\\.)*'", capture: 0, color: AppColor.syntaxString)
        case .http:
            if isFirstLine {
                color(result: &result, pattern: "^[A-Z]+", capture: 0, color: AppColor.syntaxKeyword)
                color(result: &result, pattern: "HTTP/[0-9.]+$", capture: 0, color: .secondary)
            } else if !isBody {
                color(result: &result, pattern: "^[A-Za-z0-9-]+(?=\\s*:)", capture: 0, color: AppColor.syntaxKey)
            }
        }
        return result
    }

    private static func color(
        result: inout AttributedString,
        pattern: String,
        capture: Int,
        color: Color
    ) {
        guard let regex = cachedRegex(for: pattern) else { return }
        let line = String(result.characters)
        let fullRange = NSRange(line.startIndex..., in: line)
        for match in regex.matches(in: line, options: [], range: fullRange) {
            let range = match.range(at: capture)
            guard range.location != NSNotFound,
                let stringRange = Range(range, in: line),
                let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                let upper = AttributedString.Index(stringRange.upperBound, within: result)
            else { continue }
            result[lower..<upper].foregroundColor = color
        }
    }

    /// Compiled once per pattern: the pane highlights every visible line, so
    /// recompiling per line would redo the same work dozens of times per
    /// frame. An immutable table - safe to share across threads.
    private static let regexes: [String: NSRegularExpression] = {
        let patterns = [
            "(?:^|\\s)(-{1,2}[A-Za-z][A-Za-z0-9-]*)",
            "'(?:[^'\\\\]|\\\\.)*'",
            "^[A-Z]+",
            "HTTP/[0-9.]+$",
            "^[A-Za-z0-9-]+(?=\\s*:)",
        ]
        var table: [String: NSRegularExpression] = [:]
        for pattern in patterns {
            if let compiled = try? NSRegularExpression(pattern: pattern) {
                table[pattern] = compiled
            }
        }
        return table
    }()

    private static func cachedRegex(for pattern: String) -> NSRegularExpression? {
        if let compiled = regexes[pattern] { return compiled }
        return try? NSRegularExpression(pattern: pattern)
    }
}
