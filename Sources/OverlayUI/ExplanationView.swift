import AppKit

/// Small, readable explanations shared by native permission and welcome dialogs.
public struct ExplanationItem: Sendable {
    public let symbol: String
    public let title: String
    public let message: String
    public init(symbol: String, title: String, message: String) {
        self.symbol = symbol; self.title = title; self.message = message
    }
}

@MainActor
public final class ExplanationView: NSView {
    public override var isFlipped: Bool { true }

    public init(items: [ExplanationItem], width: CGFloat = 380, footer: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        var y: CGFloat = 4
        let textWidth = width - 36
        for item in items {
            let icon = NSImageView(frame: NSRect(x: 0, y: y + 2, width: 22, height: 22))
            icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.setAccessibilityElement(false)
            addSubview(icon)
            let title = NSTextField(labelWithString: item.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.frame = NSRect(x: 36, y: y, width: textWidth, height: 19)
            addSubview(title)
            let body = NSTextField(wrappingLabelWithString: item.message)
            body.font = .systemFont(ofSize: 13)
            body.textColor = .secondaryLabelColor
            let height = ceil((item.message as NSString).boundingRect(
                with: NSSize(width: textWidth - 4, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: body.font!]).height) + 4
            body.frame = NSRect(x: 36, y: y + 23, width: textWidth, height: max(20, height))
            addSubview(body)
            y += 23 + max(20, height) + 20
        }
        if let footer {
            let label = NSTextField(wrappingLabelWithString: footer)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            let height = ceil((footer as NSString).boundingRect(with: NSSize(width: width - 4, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!]).height) + 4
            label.frame = NSRect(x: 0, y: y, width: width, height: height)
            addSubview(label); y += height + 8
        }
        frame.size.height = max(1, y)
    }
    required init?(coder: NSCoder) { nil }
}

/// A readable note in a menu, with no disabled-text contrast penalty.
@MainActor
public final class MenuNoteView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    public init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuDashboard.width, height: 40))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        update(text: text)
    }
    required init?(coder: NSCoder) { nil }
    public func update(text: String) {
        label.stringValue = text
        let width = MenuDashboard.width - 40
        let height = ceil((text as NSString).boundingRect(with: NSSize(width: width - 4, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!]).height) + 4
        frame.size.height = max(28, height + 12)
        label.frame = NSRect(x: 20, y: 6, width: width, height: max(16, height))
        toolTip = text
    }
}
