import AppKit
import SwiftUI

/// A borderless single-line field that takes the keyboard as soon as it is
/// on screen.
///
/// The panel's search field holds SwiftUI focus, and a `@FocusState` set on a
/// field inserted next to it is ignored, so a new field there never got the
/// keys. This one asks its window for first responder directly.
struct AutoFocusTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 11, weight: .medium)
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> FocusingField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.font = font
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: FocusingField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoFocusTextField

        init(parent: AutoFocusTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // A turn later: SwiftUI is still settling the hierarchy, and the
            // search field would take the keys back.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
