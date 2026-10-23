import AttentionCore
import Foundation

@MainActor
protocol MotionSensorReadingSource: AnyObject {
    var statusText: String { get }
    func startSamples(onSample: @escaping @MainActor @Sendable (MotionSensorReading) -> Void)
    func stop()
}

/// Owns only physical sensor input and an effect-free simulation. No camera,
/// audio, keep-awake helper, or real alarm controller can be reached from here.
@MainActor
final class MotionSensorTestSession {
    private let monitor: any MotionSensorReadingSource
    private let now: () -> TimeInterval
    private var wantsMonitoring = false
    private var sleeping = false
    private var generation = UUID()
    private(set) var diagnostic: MotionSensorDiagnostic
    var onChange: (() -> Void)?
    var statusText: String { sleeping ? "Sensor test paused while the Mac sleeps" : monitor.statusText }

    init(sensitivity: Double, monitor: any MotionSensorReadingSource, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        diagnostic = MotionSensorDiagnostic(sensitivity: sensitivity)
        self.monitor = monitor; self.now = now
    }
    func start() {
        wantsMonitoring = true
        guard !sleeping else { return }
        let token = UUID(); generation = token
        monitor.startSamples { [weak self] sample in
            guard let self, self.generation == token, self.wantsMonitoring, !self.sleeping,
                  sample.isFresh(at: self.now()) else { return }
            self.diagnostic.receive(sample)
        }
        onChange?()
    }
    func stop() {
        wantsMonitoring = false
        generation = UUID()
        monitor.stop()
    }
    func reset() {
        diagnostic.reset(sensitivity: diagnostic.sensitivity)
        onChange?()
    }
    func setSensitivity(_ value: Double) {
        diagnostic.reset(sensitivity: value)
        onChange?()
    }
    func retry() { stop(); reset(); start() }
    func pauseForSleep() {
        sleeping = true
        generation = UUID()
        monitor.stop()
        reset()
    }
    func resumeAfterWake() {
        guard sleeping else { return }
        sleeping = false
        if wantsMonitoring { start() }
    }
}
