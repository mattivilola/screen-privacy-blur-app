import AttentionCore
import Foundation
import MotionSensorCore

/// A direct SPU device subscription. Hardware presence, successful opening, and
/// fresh physical readings are separate states; only the last can protect the Mac.
@MainActor
final class HardwareMotionMonitor: MotionSensorReadingSource {
    private let stream = SPUAccelerometerStream(activateReportInterval: true)
    private var filter = MotionSensorFilter()
    private var lastDelivery = 0.0
    private var lastMotionReportAt: TimeInterval?
    private var monitoringRequested = false
    private var generation = UUID()
    private var recoveryError: String?

    var statusText: String { recoveryError ?? stream.status.description }

    @discardableResult
    func recoverPendingInterval() -> String? {
        do { try SPUAccelerometerStream.recoverPendingInterval(); recoveryError = nil }
        catch { recoveryError = "Sensor recovery pending · " + error.localizedDescription }
        return recoveryError
    }
    var isMonitoring: Bool {
        guard monitoringRequested, let lastMotionReportAt else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        return now >= lastMotionReportAt && now - lastMotionReportAt <= 1.5
    }

    func start(onMotion: @escaping @MainActor @Sendable (Double) -> Void) {
        startSamples { onMotion($0.movement) }
    }

    func startSamples(onSample: @escaping @MainActor @Sendable (MotionSensorReading) -> Void) {
        stop()
        guard recoverPendingInterval() == nil else { return }
        monitoringRequested = true
        let token = UUID(); generation = token
        stream.start { [weak self] report in
            guard let self, self.monitoringRequested, self.generation == token,
                  let axes = MotionSensorReport.axes(Array(report.rawReport)),
                  let sample = self.filter.sample(x: axes.x, y: axes.y, z: axes.z, at: report.captureTime),
                  sample.isFresh(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.lastMotionReportAt = sample.time
            // Filter every native report; throttle only the UI/alarm delivery.
            guard sample.time - self.lastDelivery >= 0.05 else { return }
            self.lastDelivery = sample.time
            onSample(sample)
        }
    }

    func stop() {
        generation = UUID()
        monitoringRequested = false
        stream.stop()
        filter = MotionSensorFilter()
        lastDelivery = 0
        lastMotionReportAt = nil
    }
}
