import AppKit

/// Layout shared by the views embedded in the status menu.
public enum MenuDashboard {
    public static let width: CGFloat = 340
    fileprivate static let inset: CGFloat = 20
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
    public let technicalDetail: String?

    public init(valueText: String, tierName: String, tone: DashboardTone, detail: String, technicalDetail: String? = nil) {
        self.valueText = valueText
        self.tierName = tierName
        self.tone = tone
        self.detail = detail
        self.technicalDetail = technicalDetail
    }
}

/// What the live head-direction meter shows.
public struct AttentionMeterReading: Equatable {
    public let statusText: String
    public let tone: DashboardTone
    /// Pose relative to the look-away limit (1 is the limit); nil leaves the bar empty.
    public let ratio: Double?
    public let detail: String
    public let technicalDetail: String?

    public init(statusText: String, tone: DashboardTone, ratio: Double?, detail: String, technicalDetail: String? = nil) {
        self.statusText = statusText
        self.tone = tone
        self.ratio = ratio
        self.detail = detail
        self.technicalDetail = technicalDetail
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

/// A clear protection state, backed by text and a familiar symbol.
@MainActor
public final class StatusHeaderView: NSView {
    private let icon = NSImageView(frame: NSRect(x: 20, y: 27, width: 28, height: 28))
    private let titleField = makeLabel(size: 15, weight: .semibold,
        frame: NSRect(x: 62, y: 31, width: MenuDashboard.width - 82, height: 40))
    private let subtitleField = makeLabel(size: 12, color: .secondaryLabelColor,
        frame: NSRect(x: 62, y: 10, width: MenuDashboard.width - 82, height: 18))

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuDashboard.width, height: 80))
        titleField.maximumNumberOfLines = 2
        titleField.lineBreakMode = .byWordWrapping
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        icon.setAccessibilityElement(false)
        addSubview(icon); addSubview(titleField); addSubview(subtitleField)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func update(title: String, subtitle: String, tone: DashboardTone, symbolName: String? = nil) {
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        let symbol = symbolName ?? (tone == .inactive ? "pause.circle" : "eye")
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tone.color
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
    private let settingHint: String
    private let badgeField: NSTextField
    private let detailField: NSTextField

    public init(title: String, leftLabel: String, rightLabel: String, accessibilityLabel: String,
                toolTip: String, value: Double,
                describe: @escaping @MainActor (Double) -> SettingReading,
                onChange: @escaping @MainActor (Double) -> Void) {
        self.describe = describe
        self.onChange = onChange
        self.settingHint = toolTip
        let inset = MenuDashboard.inset
        let width = MenuDashboard.width
        slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = NSRect(x: 18, y: 38, width: width - 36, height: 24)
        badgeField = makeLabel(size: 12, weight: .medium, frame: NSRect(x: 146, y: 64, width: width - 146 - inset, height: 18),
                               alignment: .right)
        badgeField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        detailField = makeLabel(size: 11, color: .secondaryLabelColor,
                                frame: NSRect(x: inset, y: 3, width: MenuDashboard.contentWidth, height: 17))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 88))

        addSubview(makeLabel(title, weight: .medium, frame: NSRect(x: inset, y: 64, width: 130, height: 18)))
        addSubview(badgeField)
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.toolTip = toolTip
        addSubview(slider)
        addSubview(makeLabel(leftLabel, size: 11, color: .secondaryLabelColor,
                             frame: NSRect(x: inset, y: 22, width: 135, height: 16)))
        addSubview(makeLabel(rightLabel, size: 11, color: .secondaryLabelColor,
                             frame: NSRect(x: width - inset - 135, y: 22, width: 135, height: 16),
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
        badgeField.stringValue = [reading.valueText, reading.tierName].filter { !$0.isEmpty }.joined(separator: " · ")
        badgeField.textColor = .secondaryLabelColor
        detailField.stringValue = reading.detail
        slider.toolTip = [settingHint, reading.technicalDetail].compactMap { $0 }.joined(separator: "\n")
        slider.setAccessibilityValueDescription([reading.valueText, reading.tierName].filter { !$0.isEmpty }.joined(separator: ", "))
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
    private let statusField = makeLabel(size: 15, weight: .semibold,
        frame: NSRect(x: MenuDashboard.inset, y: 62, width: MenuDashboard.contentWidth, height: 22))
    private let bar: MeterBarView
    private let detailField = makeLabel(size: 12, color: .secondaryLabelColor,
        frame: NSRect(x: MenuDashboard.inset, y: 6, width: MenuDashboard.contentWidth, height: 34))
    private var current: AttentionMeterReading?
    private var accessibilitySummary: String?

    public init(recoveryFraction: Double) {
        bar = MeterBarView(frame: NSRect(x: MenuDashboard.inset, y: 44, width: MenuDashboard.contentWidth, height: 10),
                           recoveryFraction: recoveryFraction)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuDashboard.width, height: 92))
        detailField.maximumNumberOfLines = 2
        detailField.lineBreakMode = .byWordWrapping
        detailField.cell?.wraps = true
        detailField.cell?.isScrollable = false
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
        statusField.textColor = .labelColor
        detailField.stringValue = reading.detail
        bar.update(ratio: reading.ratio, tone: reading.tone)
        let summary = "\(reading.statusText). \(reading.detail)"
        if summary != accessibilitySummary { setAccessibilityValue(summary); accessibilitySummary = summary }
        toolTip = [reading.statusText, reading.detail, reading.technicalDetail].compactMap { $0 }.joined(separator: "\n")
    }
}
