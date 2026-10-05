import SwiftUI

/// The preview's text: the clip's own, and its translation when there is one,
/// one at a time under a two-segment control.
///
/// One panel for every clip that carries text. Under an image clip's picture
/// it holds the recognised text; for a text clip it is the whole pane. The
/// original is never hidden by a translation, only put one click (or ⌘T)
/// away, and which tab shows is `PreviewTextPanelModel`'s decision.
///
/// The panel never sizes itself to its text. Its body is a scroll view, which
/// takes the height it is given whatever is inside it, so text streaming in
/// fills the panel in place instead of growing it.
struct PreviewTextPanel: View {
    /// What the panel sits in, which decides its header and how it renders.
    enum Context {
        /// Under an image clip's picture: an `Extracted Text` label when
        /// there is nothing to switch to, and tables drawn as grids.
        case image
        /// A text clip's whole pane: no header until there is a translation,
        /// and the text exactly as it was copied.
        case text
    }

    let context: Context
    /// The text the translation is made from.
    let original: String
    /// A line under the original, such as `ClipDisplay.previewBody`'s
    /// truncation notice.
    var notice: String? = nil
    /// The translation so far, or the finished one.
    let translation: ClipTranslationResult?
    /// Whether the translation is still being made.
    let isTranslating: Bool
    /// The BCP-47 identifier of the language being translated into, named on
    /// the translation's segment before the first chunk has arrived.
    let targetLanguage: String
    /// Bumped by the panel's ⌘T to flip between the two tabs.
    var toggleRequest: Int = 0
    /// The selection in the visible text, published so ⌘C and the pane's
    /// right-click menu can act on it.
    var onSelectionChange: ((String?) -> Void)? = nil

    /// Starts from the session's last pick, so the next clip opens the way
    /// the user prefers. A fresh panel per clip: the caller gives it the
    /// clip's identity.
    @State private var model = PreviewTextPanelModel(preference: PreviewTextTabPreference.lastPick)

    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = Design.Typography.previewBodySize

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.snug) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.normal) {
                    switch model.visibleTab {
                    case .original:
                        renderedText(original)
                        if let notice {
                            Text(notice)
                                .font(Design.Typography.meta)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                    case .translation:
                        if let translation {
                            renderedText(translation.text)
                                // `.contain` rather than `.combine`: the text
                                // stays its own element, so it can be read,
                                // navigated and selected, and the group says
                                // what it is.
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(translation.accessibilityDescription)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollMoreHint()
        }
        .onChange(of: translation != nil, initial: true) { syncModel() }
        .onChange(of: isTranslating, initial: true) { syncModel() }
        .onChange(of: toggleRequest) {
            model.toggle()
            remember()
        }
        // A selection belongs to the text it was made in.
        .onChange(of: model.visibleTab) { onSelectionChange?(nil) }
    }

    // MARK: Header

    /// The label or the control over the text, or nothing for a text clip
    /// with no translation, whose pane looks exactly as it always has.
    @ViewBuilder
    private var header: some View {
        if model.availableTabs.count > 1 {
            HStack(spacing: Design.Space.normal) {
                Picker(loc("Original or translation"), selection: tabBinding) {
                    Text(loc("Original"))
                        .accessibilityLabel(loc("Show original text"))
                        .tag(PreviewTextTab.original)
                    Text(targetName)
                        .accessibilityLabel(loc("Show translation into %@", targetName))
                        .tag(PreviewTextTab.translation)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help(loc("Switch between the original and the translation (⌘T)"))

                if isTranslating {
                    // Small and unlabelled: the segment beside it already
                    // says what is being made.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: Design.Space.normal)

                if let translation {
                    Text(translation.languagePair)
                        .font(Design.Typography.meta)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
        } else if context == .image {
            Text(loc("Extracted Text"))
                .font(Design.Typography.meta)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }

    /// The picker's selection: what the model shows, and a user pick when it
    /// is set.
    private var tabBinding: Binding<PreviewTextTab> {
        Binding(
            get: { model.visibleTab },
            set: { tab in
                model.pick(tab)
                remember()
            }
        )
    }

    /// The translation segment's name: the language being translated into,
    /// capitalised because it stands alone as a label.
    private var targetName: String {
        let name = LanguageDetector.displayName(forIdentifier: translation?.targetLanguage ?? targetLanguage)
        guard let first = name.first else { return name }
        return String(first).capitalized(with: Locale.current) + name.dropFirst()
    }

    // MARK: State

    private func syncModel() {
        model.update(hasTranslation: translation != nil, isTranslating: isTranslating)
    }

    /// Record the user's pick as the session's preference.
    private func remember() {
        if let pick = model.explicitPick {
            PreviewTextTabPreference.lastPick = pick
        }
    }

    // MARK: Body

    @ViewBuilder
    private func renderedText(_ text: String) -> some View {
        switch context {
        case .image:
            TableAwareText(text: text, size: bodyFontSize, onSelectionChange: onSelectionChange)
        case .text:
            SelectableText(text: text, size: bodyFontSize, onSelectionChange: onSelectionChange)
        }
    }
}

/// Text with any Markdown table in it drawn as a table.
///
/// Recognition stores tables as Markdown (see `TableLayout`), which is the
/// right thing to store and the wrong thing to show: a column of pipes in a
/// proportional font is harder to read than the screenshot it came from. So
/// the tables are parsed back out and laid on a grid, and everything else is
/// left as plain, selectable text. The original and its translation both
/// come through here, so a table reads the same in either language.
struct TableAwareText: View {
    let text: String
    let size: CGFloat
    var onSelectionChange: ((String?) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.roomy) {
            ForEach(Array(MarkdownTable.blocks(in: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        SelectableText(text: trimmed, size: size, onSelectionChange: onSelectionChange)
                    }
                case .table(let table):
                    tableGrid(table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One table. Monospaced digits so a column of numbers lines up under
    /// its header the way it did on screen, and a rule under the header row
    /// because that is the only thing separating it from the data once the
    /// pipes are gone.
    private func tableGrid(_ table: MarkdownTable) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Design.Space.loose, verticalSpacing: Design.Space.snug) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .font(.system(size: size, weight: .semibold))
                        .textSelection(.enabled)
                }
            }
            Divider().gridCellColumns(table.columnCount)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.system(size: size).monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
