import AppKit

@MainActor
public final class MessageEditor: NSObject, NSTextFieldDelegate {
    private let field = NSTextField(string: "")
    private let characterCounter = NSTextField(labelWithString: "")

    public override init() {
        super.init()
        configureField()
    }

    public func run(currentMessage: String) -> String? {
        field.stringValue = currentMessage

        let alert = NSAlert()
        alert.messageText = "Custom message"
        alert.informativeText = "Use up to 120 characters. Text wraps automatically into up to 3 lines on screen. Leave blank to use the app name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = makeAccessoryView()
        // Keep the editor accessible if attention is lost while it is open.
        alert.window.level = .statusBar
        alert.window.initialFirstResponder = field

        updateCharacterCounter()
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return CoverMessage.normalized(field.stringValue)
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard !hasMarkedText else {
            updateCharacterCounter()
            return
        }

        let limited = String(field.stringValue.prefix(CoverMessage.maximumCharacters))
        if field.stringValue != limited {
            field.stringValue = limited
        }
        updateCharacterCounter()
    }

    private var hasMarkedText: Bool {
        guard let editor = field.currentEditor() as? NSTextView else { return false }
        return editor.markedRange().location != NSNotFound
    }

    private func configureField() {
        field.delegate = self
        field.placeholderString = CoverMessage.defaultText
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.isBezeled = true
        field.isEditable = true
        field.isSelectable = true
        field.setAccessibilityLabel("Custom screen message")
    }

    private func makeAccessoryView() -> NSView {
        characterCounter.textColor = .secondaryLabelColor
        characterCounter.alignment = .right

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 70))
        field.frame = NSRect(x: 0, y: 36, width: 380, height: 24)
        characterCounter.frame = NSRect(x: 0, y: 8, width: 380, height: 18)
        accessory.addSubview(field)
        accessory.addSubview(characterCounter)
        return accessory
    }

    private func updateCharacterCounter() {
        characterCounter.stringValue = "\(field.stringValue.count) / \(CoverMessage.maximumCharacters)"
    }
}
