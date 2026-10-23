import AppKit

@MainActor
public final class MessageEditor: NSObject, NSTextFieldDelegate {
    private let field = NSTextField(string: "")
    private let characterCounter = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: CoverMessage.defaultText)

    public override init() {
        super.init()
        configureField()
    }

    public func run(currentMessage: String) -> String? {
        field.stringValue = currentMessage

        let alert = NSAlert()
        alert.messageText = "Screen message"
        alert.informativeText = "A short message for your covered screen."
        alert.addButton(withTitle: "Save Message")
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

    func makeAccessoryView() -> NSView {
        characterCounter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        characterCounter.textColor = .secondaryLabelColor
        characterCounter.alignment = .right
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 184))
        let label = NSTextField(labelWithString: "Message (optional)")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 0, y: 162, width: 300, height: 18)
        field.frame = NSRect(x: 0, y: 128, width: 380, height: 26)
        let hint = NSTextField(labelWithString: "Leave blank to show Screen Privacy")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 0, y: 103, width: 284, height: 18)
        characterCounter.frame = NSRect(x: 288, y: 103, width: 92, height: 18)
        let caption = NSTextField(labelWithString: "Message preview")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 0, y: 79, width: 380, height: 17)
        let box = NSBox(frame: NSRect(x: 0, y: 0, width: 380, height: 76))
        box.boxType = .custom; box.titlePosition = .noTitle
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor
        box.cornerRadius = 12; box.borderWidth = 1
        box.contentViewMargins = .zero
        preview.font = .systemFont(ofSize: 16, weight: .semibold)
        preview.alignment = .center
        preview.maximumNumberOfLines = 3
        preview.frame = NSRect(x: 16, y: 12, width: 348, height: 52)
        preview.setAccessibilityLabel("Message preview")
        box.contentView?.addSubview(preview)
        for view in [label, field, hint, characterCounter, caption, box] { accessory.addSubview(view) }
        updateCharacterCounter()
        return accessory
    }

    private func updateCharacterCounter() {
        characterCounter.stringValue = "\(field.stringValue.count) / \(CoverMessage.maximumCharacters)"
        characterCounter.setAccessibilityLabel("\(field.stringValue.count) of \(CoverMessage.maximumCharacters) characters")
        preview.stringValue = CoverMessage.displayText(field.stringValue)
    }
}
