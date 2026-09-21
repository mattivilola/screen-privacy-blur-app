import AppKit

/// Typography is measured only when the message or display geometry changes.
@MainActor
struct CoverLayout {
    let frame: NSRect
    let iconFrame: NSRect
    let textFrame: NSRect
    let font: NSFont
    let lineCount: Int

    init(screenSize: NSSize, message: String) {
        let text = CoverMessage.displayText(message)
        let width = min(screenSize.width / 3, 520)
        let maximumHeight = min(screenSize.height / 3, 300)
        let padding = min(24, min(width, maximumHeight) * 0.08)
        let gap = min(14, maximumHeight * 0.055)
        let iconSize = min(96, min(width * 0.24, (maximumHeight - padding * 2) * 0.38))
        let textWidth = max(1, width - padding * 2)
        let availableHeight = max(1, maximumHeight - padding * 2 - iconSize - gap)
        var fontSize = min(28, min(width * 0.07, availableHeight / 1.2))
        let minimumFontSize = min(12, fontSize)

        while fontSize > minimumFontSize {
            let candidate = Self.measure(text, fontSize: fontSize, width: textWidth)
            if candidate.lines <= 3 && candidate.height <= availableHeight { break }
            fontSize = max(minimumFontSize, fontSize - 0.5)
        }

        let measured = Self.measure(text, fontSize: fontSize, width: textWidth,
                                    maximumLines: 3, height: availableHeight)
        let textHeight = min(availableHeight, ceil(measured.height))
        let height = min(maximumHeight, padding * 2 + iconSize + gap + textHeight)
        frame = NSRect(x: (screenSize.width - width) / 2,
                       y: (screenSize.height - height) / 2, width: width, height: height)
        textFrame = NSRect(x: padding, y: padding, width: textWidth, height: textHeight)
        iconFrame = NSRect(x: (width - iconSize) / 2, y: padding + textHeight + gap,
                           width: iconSize, height: iconSize)
        font = .systemFont(ofSize: fontSize, weight: .semibold)
        lineCount = measured.lines
    }

    static func attributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private static func measure(_ text: String, fontSize: CGFloat, width: CGFloat,
                                maximumLines: Int = 0, height: CGFloat = .greatestFiniteMagnitude)
        -> (height: CGFloat, lines: Int) {
        let storage = NSTextStorage(string: text,
                                    attributes: attributes(font: .systemFont(ofSize: fontSize, weight: .semibold)))
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: height))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maximumLines
        container.lineBreakMode = maximumLines == 0 ? .byWordWrapping : .byTruncatingTail
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in
            lines += 1
        }
        return (manager.usedRect(for: container).height, lines)
    }
}

@MainActor
public final class CoverBrandingView: NSVisualEffectView {
    private let screenSize: NSSize
    private let iconView = NSImageView()
    private let messageView: NSTextView
    private var message: String

    public init(screenSize: NSSize, message: String, icon: NSImage?) {
        self.screenSize = screenSize
        self.message = CoverMessage.displayText(message)

        // Use the same TextKit layout rules for measurement and drawing.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 3
        container.lineBreakMode = .byTruncatingTail
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        messageView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        messageView.isEditable = false
        messageView.isSelectable = false
        messageView.drawsBackground = false
        messageView.textContainerInset = .zero
        messageView.isHorizontallyResizable = false
        messageView.isVerticallyResizable = false
        container.widthTracksTextView = true
        container.heightTracksTextView = true
        addSubview(messageView)
        applyLayout()
    }

    required init?(coder: NSCoder) { nil }

    public func updateMessage(_ value: String) {
        let normalized = CoverMessage.displayText(value)
        guard message != normalized else { return }
        message = normalized
        applyLayout()
    }

    private func applyLayout() {
        let layout = CoverLayout(screenSize: screenSize, message: message)
        frame = layout.frame
        layer?.cornerRadius = min(22, min(frame.width, frame.height) * 0.1)
        iconView.frame = layout.iconFrame
        messageView.frame = layout.textFrame
        messageView.textStorage?.setAttributedString(
            NSAttributedString(string: message, attributes: CoverLayout.attributes(font: layout.font))
        )
    }
}
