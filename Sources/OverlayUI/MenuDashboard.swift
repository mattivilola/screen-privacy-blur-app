import AppKit

/// Layout shared by the views embedded in the status menu.
public enum MenuDashboard {
    public static let width: CGFloat = 300
    fileprivate static let inset: CGFloat = 18
    fileprivate static let contentWidth = width - inset * 2
}

/// Semantic color of a status, so meaning is consistent across the menu.
public enum DashboardTone: Sendable {
    case good, balanced, caution, alert, inactive

    public var color: NSColor {
        switch self {
        case .good: .systemGreen
        case .balanced: .systemBlue
        case .caution: .systemOrange
        case .alert: .systemRed
        case .inactive: .tertiaryLabelColor
        }
    }
}

/// What a setting slider shows for its current value.
public struct SettingReading: Equatable {
    public let valueText: String
    public let tierName: String
    public let tone: DashboardTone
    public let detail: String

    public init(valueText: String, tierName: String, tone: DashboardTone, detail: String) {
        self.valueText = valueText
        self.tierName = tierName
        self.tone = tone
        self.detail = detail
    }
}

/// What the live head-direction meter shows.
public struct AttentionMeterReading: Equatable {
    public let statusText: String
    public let tone: DashboardTone
    /// Pose relative to the look-away limit (1 is the limit); nil leaves the bar empty.
    public let ratio: Double?
    public let detail: String

    public init(statusText: String, tone: DashboardTone, ratio: Double?, detail: String) {
        self.statusText = statusText
        self.tone = tone
        self.ratio = ratio
        self.detail = detail
    }
}

public enum AttentionMeterScale {
    /// The bar's full width represents 150% of the look-away limit.
    public static let maximumRatio = 1.5

    public static func fillFraction(for ratio: Double) -> Double {
        guard ratio.isFinite else { return 0 }
        return min(max(ratio / maximumRatio, 0), 1)
    }

    public static func tone(forRatio ratio: Double, recoveryFraction: Double) -> DashboardTone {
        if ratio <= recoveryFraction { return .good }
        if ratio <= 1 { return .caution }
        return .alert
    }
}

// MARK: - Views

@MainActor
private func makeLabel(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, frame: NSRect,
                       alignment: NSTextAlignment = .left) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.alignment = alignment
    field.lineBreakMode = .byTruncatingTail
    field.allowsDefaultTighteningForTruncation = true
    field.maximumNumberOfLines = 1
    field.frame = frame
    return field
}

/// A filled circle that resolves its dynamic color at draw time.
@MainActor
private final class ToneDotView: NSView {
    var tone: DashboardTone = .inactive {
        didSet { if tone != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        tone.color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Protection status: a tone dot, the status text and the selected camera.
@MainActor
public final class StatusHeaderView: NSView {
    private let dot = ToneDotView(frame: NSRect(x: MenuDashboard.inset, y: 28, width: 8, height: 8))
    private let titleField = makeLabel(size: 13, weight: .semibold,
                                       frame: NSRect(x: 34, y: 23, width: MenuDashboard.width - 34 - MenuDashboard.inset, height: 18))
    private let subtitleField = makeLabel(size: 11, color: .secondaryLabelColor,
                                          frame: NSRect(x: 34, y: 6, width: MenuDashboard.width - 34 - MenuDashboard.inset, height: 15))

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuDashboard.width, height: 48))
        addSubview(dot)
        addSubview(titleField)
        addSubview(subtitleField)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(title: String, subtitle: String, tone: DashboardTone) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        dot.tone = tone
        // Longer statuses truncate in the fixed width; the tooltip keeps them readable.
        toolTip = "\(title)\n\(subtitle)"
        setAccessibilityLabel("\(title). \(subtitle)")
    }
}

/// A titled slider with a live value badge, end labels and a one-line explanation.
@MainActor
public final class SettingSliderView: NSView {
    private let describe: @MainActor (Double) -> SettingReading
    private let onChange: @MainActor (Double) -> Void
    private let slider: NSSlider
    private let badgeDot = ToneDotView(frame: NSRect(x: 0, y: 75, width: 8, height: 8))
    private let badgeField: NSTextField
    private let detailField: NSTextField

    public init(title: String, leftLabel: String, rightLabel: String, accessibilityLabel: String,
                toolTip: String, value: Double,
                describe: @escaping @MainActor (Double) -> SettingReading,
                onChange: @escaping @MainActor (Double) -> Void) {
        self.describe = describe
        self.onChange = onChange
        let inset = MenuDashboard.inset
        let width = MenuDashboard.width
        slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = NSRect(x: 16, y: 44, width: width - 32, height: 24)
        badgeField = makeLabel(size: 12, weight: .medium, frame: NSRect(x: 120, y: 70, width: width - 120 - inset, height: 18),
                               alignment: .right)
        badgeField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        detailField = makeLabel(size: 11, color: .secondaryLabelColor,
                                frame: NSRect(x: inset, y: 8, width: MenuDashboard.contentWidth, height: 16))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 96))

        addSubview(makeLabel(title, frame: NSRect(x: inset, y: 70, width: 100, height: 18)))
        addSubview(badgeDot)
        addSubview(badgeField)
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.toolTip = toolTip
        addSubview(slider)
        addSubview(makeLabel(leftLabel, size: 11, color: .secondaryLabelColor,
                             frame: NSRect(x: inset, y: 26, width: 105, height: 16)))
        addSubview(makeLabel(rightLabel, size: 11, color: .secondaryLabelColor,
                             frame: NSRect(x: width - inset - 109, y: 26, width: 109, height: 16),
                             alignment: .right))
        addSubview(detailField)
        refresh(for: value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func sliderChanged(_ sender: NSSlider) {
        refresh(for: sender.doubleValue)
        onChange(sender.doubleValue)
    }

    private func refresh(for value: Double) {
        let reading = describe(value)
        badgeField.stringValue = "\(reading.valueText) · \(reading.tierName)"
        badgeField.textColor = reading.tone.color
        detailField.stringValue = reading.detail
        badgeDot.tone = reading.tone
        // The badge is right-aligned, so the dot trails the measured text to its left.
        let textWidth = ceil(badgeField.attributedStringValue.size().width)
        badgeDot.frame.origin.x = badgeField.frame.maxX - textWidth - 6 - badgeDot.frame.width
        slider.setAccessibilityValueDescription("\(reading.valueText), \(reading.tierName)")
    }
}

/// Track, tone fill and the limit and return-range ticks of the live meter.
@MainActor
private final class MeterBarView: NSView {
    private let recoveryFraction: Double
    private var fill = 0.0
    private var tone: DashboardTone = .inactive

    init(frame: NSRect, recoveryFraction: Double) {
        self.recoveryFraction = recoveryFraction
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(ratio: Double?, tone: DashboardTone) {
        let newFill = ratio.map(AttentionMeterScale.fillFraction(for:)) ?? 0
        guard newFill != fill || tone != self.tone else { return }
        fill = newFill
        self.tone = tone
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: 2, width: bounds.width, height: 6)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        NSColor.quaternaryLabelColor.setFill()
        trackPath.fill()

        if fill > 0 {
            NSGraphicsContext.saveGraphicsState()
            trackPath.addClip()
            tone.color.setFill()
            NSRect(x: 0, y: track.minY, width: bounds.width * fill, height: track.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        tick(at: 1 / AttentionMeterScale.maximumRatio, color: .labelColor)
        tick(at: recoveryFraction / AttentionMeterScale.maximumRatio,
             color: NSColor.labelColor.withAlphaComponent(0.4))
    }

    private func tick(at fraction: Double, color: NSColor) {
        color.setFill()
        NSRect(x: bounds.width * fraction - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// Live head direction against the look-away limit.
@MainActor
public final class AttentionMeterView: NSView {
    private let statusField = makeLabel(size: 12, weight: .medium,
                                        frame: NSRect(x: 130, y: 44, width: MenuDashboard.width - 130 - MenuDashboard.inset, height: 18),
                                        alignment: .right)
    private let bar: MeterBarView
    private let detailField = makeLabel(size: 11, color: .secondaryLabelColor,
                                        frame: NSRect(x: MenuDashboard.inset, y: 8, width: MenuDashboard.contentWidth, height: 16))
    private var current: AttentionMeterReading?

    public init(recoveryFraction: Double) {
        bar = MeterBarView(frame: NSRect(x: MenuDashboard.inset, y: 28, width: MenuDashboard.contentWidth, height: 10),
                           recoveryFraction: recoveryFraction)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuDashboard.width, height: 70))
        addSubview(makeLabel("Head direction", frame: NSRect(x: MenuDashboard.inset, y: 44, width: 110, height: 18)))
        addSubview(statusField)
        addSubview(bar)
        addSubview(detailField)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Live head direction")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(_ reading: AttentionMeterReading) {
        guard reading != current else { return }
        current = reading
        statusField.stringValue = reading.statusText
        statusField.textColor = reading.tone.color
        detailField.stringValue = reading.detail
        bar.update(ratio: reading.ratio, tone: reading.tone)
        setAccessibilityValue("\(reading.statusText). \(reading.detail)")
    }
}
