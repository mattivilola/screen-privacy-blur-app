import AppKit
import AttentionCore
import OverlayUI

@MainActor
final class MotionSensorTestView: NSView {
    override var isFlipped: Bool { true }

    private let protectionWasEnabled: Bool
    private let stack = NSStackView()
    private let stateIcon = NSImageView()
    private let headline = NSTextField(wrappingLabelWithString: "Checking the built-in sensor")
    private let instruction = NSTextField(wrappingLabelWithString: "Wait while Screen Privacy checks this Mac’s motion sensor.")
    private let signalMeter = MotionSignalMeter(frame: .zero)
    private let axes = NSTextField(labelWithString: "—")
    private let magnitude = NSTextField(labelWithString: "—")
    private let reports = NSTextField(labelWithString: "0")
    private let age = NSTextField(labelWithString: "No readings received")
    private let movement = NSTextField(labelWithString: "—")
    private let threshold = NSTextField(labelWithString: "—")
    private let tilt = NSTextField(labelWithString: "—")
    private let backendStatus = NSTextField(wrappingLabelWithString: "Checking the sensor")
    private let graph = MotionSensorGraph(frame: .zero)
    private let detailsStack = NSStackView()
    let detailsButton = NSButton(title: "Sensor details", target: nil, action: nil)
    let retryButton = NSButton(title: "Retry sensor", target: nil, action: nil)
    let resetButton = NSButton(title: "Test again", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    var onLayoutChange: (() -> Void)?

    override convenience init(frame: NSRect) {
        self.init(frame: frame, protectionWasEnabled: false)
    }

    init(frame: NSRect, protectionWasEnabled: Bool) {
        self.protectionWasEnabled = protectionWasEnabled
        super.init(frame: frame)
        buildView()
        setDetailsExpanded(false, notify: false)
        updatePreferredHeight()
    }

    required init?(coder: NSCoder) { nil }

    var preferredHeight: CGFloat {
        return max(360, stack.fittingSize.height + 48)
    }

    func update(diagnostic: MotionSensorDiagnostic, monitorStatus: String, now: TimeInterval) {
        let cleanedStatus = monitorStatus.replacingOccurrences(of: "; using camera", with: "")
        let fresh = diagnostic.isFresh(at: now)
        let paused = Self.isPaused(cleanedStatus)
        let unavailable = Self.isUnavailable(cleanedStatus)
        let stale = diagnostic.latest != nil && !fresh
        let wasRetryHidden = retryButton.isHidden
        let wasResetHidden = resetButton.isHidden
        let presentation = Self.presentation(
            diagnostic: diagnostic,
            monitorStatus: cleanedStatus,
            now: now,
            fresh: fresh,
            paused: paused,
            stale: stale,
            unavailable: unavailable
        )

        headline.stringValue = presentation.title
        instruction.stringValue = presentation.instruction
        headline.textColor = presentation.tone.color
        stateIcon.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)
        stateIcon.contentTintColor = presentation.tone.color
        let accelerationRatio = diagnostic.threshold > 0
            ? (diagnostic.latest?.rmsMovement ?? 0) / diagnostic.threshold
            : 0
        let tiltRatio = diagnostic.tiltThreshold > 0
            ? diagnostic.tiltDegrees / diagnostic.tiltThreshold
            : 0
        signalMeter.update(
            value: max(0, max(accelerationRatio, tiltRatio)),
            hasLiveReadings: fresh && !unavailable && !paused,
            scale: 2,
            threshold: 1,
            tone: presentation.tone
        )

        let passed = fresh && diagnostic.phase == .alarming
        retryButton.isHidden = paused || (!unavailable && !stale)
        resetButton.isHidden = !passed
        if wasRetryHidden != retryButton.isHidden || wasResetHidden != resetButton.isHidden {
            updatePreferredHeight()
            onLayoutChange?()
        }

        axes.stringValue = diagnostic.latest.map {
            String(format: "%+.3f / %+.3f / %+.3f g", $0.x, $0.y, $0.z)
        } ?? "—"
        magnitude.stringValue = diagnostic.latest.map {
            String(format: "%.3f g (includes gravity)", $0.magnitude)
        } ?? "—"
        reports.stringValue = "\(diagnostic.observedReports)" + (diagnostic.reportRate.map {
            String(format: " · %.1f reports/s", $0)
        } ?? " · measuring rate…")
        age.stringValue = diagnostic.latest.map {
            String(format: "%.2f seconds ago", max(0, now - $0.time))
        } ?? "No valid readings received"
        movement.stringValue = String(format: "%.3f g / %.3f g", diagnostic.latest?.rmsMovement ?? 0, diagnostic.peak)
        tilt.stringValue = String(format: "%.1f° / %.1f°", diagnostic.tiltDegrees, diagnostic.tiltThreshold)
        threshold.stringValue = String(format: "%.3f g · sensitivity %.0f%%", diagnostic.threshold, diagnostic.sensitivity * 100)
        backendStatus.stringValue = cleanedStatus
        graph.values = diagnostic.samples.map { ($0.time, $0.rmsMovement) }
        graph.threshold = diagnostic.threshold
        graph.fresh = fresh
        graph.needsDisplay = true
    }

    func setDetailsExpanded(_ expanded: Bool) {
        setDetailsExpanded(expanded, notify: true)
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Motion sensor test")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .secondaryLabelColor

        headline.font = .systemFont(ofSize: 23, weight: .bold)
        headline.maximumNumberOfLines = 2
        headline.lineBreakMode = .byWordWrapping
        instruction.font = .systemFont(ofSize: 15)
        instruction.textColor = .secondaryLabelColor
        instruction.maximumNumberOfLines = 3
        instruction.lineBreakMode = .byWordWrapping

        stateIcon.imageScaling = .scaleProportionallyDown
        stateIcon.setContentHuggingPriority(.required, for: .horizontal)
        stateIcon.setContentHuggingPriority(.required, for: .vertical)
        stateIcon.widthAnchor.constraint(equalToConstant: 42).isActive = true
        stateIcon.heightAnchor.constraint(equalToConstant: 42).isActive = true
        stateIcon.setAccessibilityElement(false)
        let stateCopy = NSStackView(views: [headline, instruction])
        stateCopy.orientation = .vertical
        stateCopy.alignment = .leading
        stateCopy.spacing = 7
        let stateRow = NSStackView(views: [stateIcon, stateCopy])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 18

        let meterLabel = NSTextField(labelWithString: "Live movement and tilt signal")
        meterLabel.font = .systemFont(ofSize: 13, weight: .medium)
        signalMeter.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let meterStack = NSStackView(views: [meterLabel, signalMeter])
        meterStack.orientation = .vertical
        meterStack.alignment = .leading
        meterStack.spacing = 8
        signalMeter.widthAnchor.constraint(equalTo: meterStack.widthAnchor).isActive = true

        for value in [axes, magnitude, reports, age, movement, threshold, tilt] {
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        backendStatus.font = .systemFont(ofSize: 12)
        backendStatus.textColor = .secondaryLabelColor
        backendStatus.maximumNumberOfLines = 3
        backendStatus.lineBreakMode = .byWordWrapping
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "X / Y / Z"), axes],
            [NSTextField(labelWithString: "Total acceleration"), magnitude],
            [NSTextField(labelWithString: "Sensor reports"), reports],
            [NSTextField(labelWithString: "Last reading"), age],
            [NSTextField(labelWithString: "Motion RMS / peak"), movement],
            [NSTextField(labelWithString: "Tilt / threshold"), tilt],
            [NSTextField(labelWithString: "Alarm threshold"), threshold],
            [NSTextField(labelWithString: "Backend status"), backendStatus]
        ])
        grid.columnSpacing = 18
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .leading

        let graphTitle = NSTextField(labelWithString: "Motion RMS (g) · threshold · last 6 seconds")
        graphTitle.font = .systemFont(ofSize: 12)
        graphTitle.textColor = .secondaryLabelColor
        graph.heightAnchor.constraint(equalToConstant: 110).isActive = true
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 12
        detailsStack.addArrangedSubview(grid)
        detailsStack.addArrangedSubview(graphTitle)
        detailsStack.addArrangedSubview(graph)
        grid.widthAnchor.constraint(equalTo: detailsStack.widthAnchor).isActive = true
        graphTitle.widthAnchor.constraint(equalTo: detailsStack.widthAnchor).isActive = true
        graph.widthAnchor.constraint(equalTo: detailsStack.widthAnchor).isActive = true
        detailsStack.setAccessibilityElement(true)
        detailsStack.setAccessibilityRole(.group)
        detailsStack.setAccessibilityLabel("Technical sensor details")

        detailsButton.setButtonType(.onOff)
        detailsButton.bezelStyle = .regularSquare
        detailsButton.isBordered = false
        detailsButton.imagePosition = .imageLeading
        detailsButton.setAccessibilityRole(.disclosureTriangle)
        detailsButton.title = "Sensor details"
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails(_:))
        detailsButton.setAccessibilityLabel("Sensor details")

        retryButton.controlSize = .large
        resetButton.controlSize = .large
        doneButton.controlSize = .large
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityLabel("Done and close sensor test")
        let buttons = NSStackView(views: [retryButton, resetButton, doneButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = NSView()
        buttonRow.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            buttonRow.heightAnchor.constraint(equalTo: buttons.heightAnchor)
        ])

        let footerText = protectionWasEnabled
            ? "The alarm is off during this test. Screen protection resumes when you close this window. Readings stay in memory and are never saved or uploaded."
            : "The alarm and screen protection are off during this test and remain off when you close this window. Readings stay in memory and are never saved or uploaded."
        let footer = NSTextField(wrappingLabelWithString: footerText)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.maximumNumberOfLines = 3
        footer.lineBreakMode = .byWordWrapping
        footer.setAccessibilityLabel(footerText)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(stateRow)
        stack.addArrangedSubview(meterStack)
        stack.addArrangedSubview(detailsButton)
        stack.addArrangedSubview(detailsStack)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(footer)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            stateCopy.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60),
            meterStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for view in [detailsStack, footer, stateRow, meterStack, buttonRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        retryButton.isHidden = true
        resetButton.isHidden = true
    }

    @objc private func toggleDetails(_ sender: NSButton) {
        setDetailsExpanded(sender.state == .on)
    }

    private func setDetailsExpanded(_ expanded: Bool, notify: Bool) {
        detailsStack.isHidden = !expanded
        detailsButton.state = expanded ? .on : .off
        detailsButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        detailsButton.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
        updatePreferredHeight()
        if notify { onLayoutChange?() }
    }

    private func updatePreferredHeight() {
        stack.needsLayout = true
    }

    private static func isUnavailable(_ status: String) -> Bool {
        let text = status.lowercased()
        return ["no built-in", "could not be opened", "activation failed", "unsupported", "ambiguous", "matching spu accelerometer", "recovery pending", "has not reported", "no reports", "inaccessible"]
            .contains(where: text.contains)
    }

    private static func isPaused(_ status: String) -> Bool {
        status.localizedCaseInsensitiveContains("sensor test paused while the mac sleeps")
    }

    private static func presentation(
        diagnostic: MotionSensorDiagnostic,
        monitorStatus: String,
        now: TimeInterval,
        fresh: Bool,
        paused: Bool,
        stale: Bool,
        unavailable: Bool
    ) -> (title: String, instruction: String, symbol: String, tone: DashboardTone) {
        if paused {
            return ("Sensor test paused", "It will resume when this Mac wakes.", "pause.circle.fill", .inactive)
        }
        if stale {
            return ("Sensor readings stopped", "Choose Retry sensor to start a fresh test.", "exclamationmark.triangle.fill", .alert)
        }
        if unavailable {
            return ("Sensor unavailable", "This Mac isn’t sending usable sensor readings. Retry, or use camera movement in Alarm mode.", "exclamationmark.triangle.fill", .alert)
        }
        guard fresh else {
            let isChecking = monitorStatus.localizedCaseInsensitiveContains("search")
                || monitorStatus.localizedCaseInsensitiveContains("checking")
                || monitorStatus.localizedCaseInsensitiveContains("waiting for reports")
                || monitorStatus == "Fake sensor for deterministic tests"
            return isChecking
                ? ("Checking the built-in sensor", "Wait while Screen Privacy connects to this Mac’s motion sensor.", "gyroscope", .balanced)
                : ("Waiting for the sensor", "Keep the Mac still while Screen Privacy waits for a fresh reading.", "gyroscope", .balanced)
        }
        switch diagnostic.phase {
        case .alarming:
            return ("Motion detected", "The sensor-only test passed. Choose Test again to repeat it, or Done to close.", "checkmark.circle.fill", .good)
        case .armed:
            return ("Now lift or gently tilt the Mac", "Pick up the Mac or slowly tilt it to finish the test.", "move.3d", .balanced)
        case let .countdown(until):
            let remaining = max(0, Int(ceil(until - now)))
            let detail = remaining > 0 ? "Keep the Mac still for \(remaining) seconds." : "Keep the Mac still for the final moment."
            return ("Keep the Mac still", detail, "hand.raised.fill", .caution)
        case .off, .waiting:
            return ("Keep the Mac still", "Set the Mac down and keep it still while the sensor calibrates.", "hand.raised.fill", .caution)
        }
    }
}

@MainActor
private final class MotionSignalMeter: NSView {
    private var value = 0.0
    private var scale = 0.25
    private var threshold = 0.1
    private var tone: DashboardTone = .balanced

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Live movement and tilt signal")
    }

    required init?(coder: NSCoder) { nil }

    func update(value: Double, hasLiveReadings: Bool, scale: Double, threshold: Double, tone: DashboardTone) {
        self.value = hasLiveReadings && value.isFinite ? max(0, value) : 0
        self.scale = scale.isFinite ? max(0.01, scale) : 0.25
        self.threshold = threshold.isFinite ? max(0, threshold) : 0.1
        self.tone = tone
        let description = !hasLiveReadings ? "No live readings" : (self.value >= self.threshold ? "Trigger level reached" : "Below trigger level")
        if accessibilityValue() as? String != description { setAccessibilityValue(description) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = bounds.insetBy(dx: 1, dy: 1)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        let fraction = min(1, max(0, value / scale))
        if fraction > 0 {
            let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height)
            tone.color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        }
        let triggerX = bar.minX + bar.width * min(1, max(0, threshold / scale))
        let marker = NSBezierPath()
        marker.lineWidth = 2
        marker.move(to: NSPoint(x: triggerX, y: bar.minY - 1))
        marker.line(to: NSPoint(x: triggerX, y: bar.maxY + 1))
        NSColor.secondaryLabelColor.setStroke()
        marker.stroke()
    }
}

@MainActor
private final class MotionSensorGraph: NSView {
    var values: [(TimeInterval, Double)] = []
    var threshold = 0.1
    var fresh = false
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let rect = bounds.insetBy(dx: 10, dy: 10)
        let scale = max(0.25, (values.map(\.1).max() ?? 0) * 1.2, threshold * 1.2)
        let limit = NSBezierPath()
        limit.move(to: NSPoint(x: rect.minX, y: rect.minY + threshold / scale * rect.height))
        limit.line(to: NSPoint(x: rect.maxX, y: rect.minY + threshold / scale * rect.height))
        limit.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        limit.stroke()
        guard let last = values.last else { return }
        let line = NSBezierPath()
        line.lineWidth = 2
        for (index, sample) in values.enumerated() {
            let point = NSPoint(
                x: rect.maxX - min(6, max(0, last.0 - sample.0)) / 6 * rect.width,
                y: rect.minY + sample.1 / scale * rect.height
            )
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        (fresh ? DashboardTone.balanced.color : NSColor.secondaryLabelColor).setStroke()
        line.stroke()
    }
}
