import AppKit
import AttentionCore

@MainActor
final class MotionSensorTestView: NSView {
    override var isFlipped: Bool { true }
    private let status = NSTextField(labelWithString: "Checking motion sensor…")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let axes = NSTextField(labelWithString: "—")
    private let magnitude = NSTextField(labelWithString: "—")
    private let reports = NSTextField(labelWithString: "0")
    private let age = NSTextField(labelWithString: "No readings received")
    private let movement = NSTextField(labelWithString: "—")
    private let threshold = NSTextField(labelWithString: "—")
    private let tilt = NSTextField(labelWithString: "—")
    private let result = NSTextField(labelWithString: "Waiting for sensor readings")
    private let graph = MotionSensorGraph(frame: .zero)
    let retryButton = NSButton(title: "Retry sensor", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset test", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "Motion sensor test")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        let introduction = NSTextField(wrappingLabelWithString:
            "Keep the Mac still for 3 seconds, then lift or gently tilt it. This silent test uses only the physical sensor—no camera, siren, or screen flashing.")
        status.font = .systemFont(ofSize: 16, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        result.font = .systemFont(ofSize: 15, weight: .semibold)
        for value in [axes, magnitude, reports, age, movement, threshold, tilt] {
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "X / Y / Z"), axes],
            [NSTextField(labelWithString: "Total acceleration"), magnitude],
            [NSTextField(labelWithString: "Sensor reports"), reports],
            [NSTextField(labelWithString: "Last reading"), age],
            [NSTextField(labelWithString: "Motion RMS / peak"), movement],
            [NSTextField(labelWithString: "Tilt / threshold"), tilt],
            [NSTextField(labelWithString: "Alarm threshold"), threshold]
        ])
        grid.columnSpacing = 22; grid.rowSpacing = 9
        grid.column(at: 0).xPlacement = .leading
        let graphTitle = NSTextField(labelWithString: "Motion RMS (g) · red line = alarm threshold · last 6 seconds")
        graphTitle.font = .systemFont(ofSize: 12); graphTitle.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [retryButton, resetButton, doneButton])
        buttons.spacing = 10
        doneButton.keyEquivalent = "\r"
        let footer = NSTextField(wrappingLabelWithString:
            "Alarm mode stays off after this test. Screen protection resumes when you close this window if it was previously enabled. Readings stay in memory and are never saved or uploaded.")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, introduction, status, detail, grid, graphTitle, graph, result, buttons, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            graph.heightAnchor.constraint(equalToConstant: 110)
        ])
        for view in [introduction, detail, grid, graph, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(diagnostic: MotionSensorDiagnostic, monitorStatus: String, now: TimeInterval) {
        let fresh = diagnostic.isFresh(at: now)
        let monitorStatus = monitorStatus.replacingOccurrences(of: "; using camera", with: "")
        status.stringValue = fresh ? "Sensor readings are arriving" : (diagnostic.latest == nil ? monitorStatus : "Sensor readings stopped")
        status.textColor = fresh ? .systemGreen : .secondaryLabelColor
        detail.stringValue = fresh
            ? "Physical sensor input only. At rest, total acceleration is near 1 g. Try a brief table bump, a lift, carrying, and a slow tilt; Reset test between trials."
            : "\(monitorStatus)\nAn interface being present does not prove it can detect movement. This test needs fresh readings."
        threshold.stringValue = String(format: "%.3f g for 0.35 s · sensitivity %.0f%%", diagnostic.threshold, diagnostic.sensitivity * 100)
        tilt.stringValue = String(format: "%.1f° / %.1f° for 0.5 s", diagnostic.tiltDegrees, diagnostic.tiltThreshold)
        reports.stringValue = "\(diagnostic.observedReports)" + (diagnostic.reportRate.map { String(format: " · %.1f reports/s", $0) } ?? " · measuring rate…")
        if let latest = diagnostic.latest {
            axes.stringValue = String(format: "%+.3f / %+.3f / %+.3f g", latest.x, latest.y, latest.z)
            magnitude.stringValue = String(format: "%.3f g (includes gravity)", latest.magnitude)
            age.stringValue = String(format: "%.2f seconds ago", max(0, now - latest.time))
            movement.stringValue = String(format: "%.3f g / %.3f g", latest.rmsMovement, diagnostic.peak)
        } else {
            axes.stringValue = "—"; magnitude.stringValue = "—"; movement.stringValue = "—"
            age.stringValue = "No valid readings received"
        }
        graph.values = diagnostic.samples.map { ($0.time, $0.rmsMovement) }
        graph.threshold = diagnostic.threshold
        graph.fresh = fresh
        graph.needsDisplay = true
        result.textColor = .secondaryLabelColor
        guard fresh else {
            result.stringValue = diagnostic.detectedMovement ? "Readings stopped · earlier movement was detected" : "Movement detection has not been verified"
            return
        }
        switch diagnostic.phase {
        case .alarming:
            result.stringValue = "Movement detected · sensor-only test passed" + (diagnostic.triggerReason.map { " · " + $0 } ?? "")
            result.textColor = .systemGreen
        case .armed:
            result.stringValue = "Ready · physical sensor primary · lift or tilt the Mac"
        case let .countdown(until):
            let remaining = Int(ceil(until - now))
            result.stringValue = remaining > 0 ? "Calibrating · keep still for \(remaining) s" : "Keep still briefly to finish calibration"
        default: result.stringValue = "Waiting for sensor readings"
        }
        result.setAccessibilityValue(result.stringValue)
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
        NSColor.systemRed.setStroke(); limit.stroke()
        guard let last = values.last else { return }
        let line = NSBezierPath(); line.lineWidth = 2
        for (index, sample) in values.enumerated() {
            let point = NSPoint(x: rect.maxX - min(6, max(0, last.0 - sample.0)) / 6 * rect.width,
                               y: rect.minY + sample.1 / scale * rect.height)
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        (fresh ? NSColor.systemBlue : NSColor.secondaryLabelColor).setStroke(); line.stroke()
    }
}
