import AVFoundation
import AttentionCore
import Vision

enum CameraEvent: Sendable {
    case faces([FacePose], time: TimeInterval)
    case unavailable(String)
}

/// All mutable capture state is confined to `queue`, including delegate callbacks.
/// The only cross-queue values are immutable events and the sendable callback.
final class CameraMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.iloapps.screenprivacy.camera", qos: .utility)
    private var session: AVCaptureSession?
    private var sink: (@Sendable (CameraEvent) -> Void)?
    private var lastAnalysis: TimeInterval = 0
    private let request: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()

    func start(deliver: @escaping @Sendable (CameraEvent) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            sink = deliver
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else {
                    deliver(.unavailable("No camera available"))
                    return
                }
                let capture = AVCaptureSession()
                capture.beginConfiguration()
                capture.sessionPreset = capture.canSetSessionPreset(.vga640x480) ? .vga640x480 : .low
                let input = try AVCaptureDeviceInput(device: camera)
                guard capture.canAddInput(input) else {
                    deliver(.unavailable("Camera is unavailable"))
                    return
                }
                capture.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.setSampleBufferDelegate(self, queue: queue)
                guard capture.canAddOutput(output) else {
                    deliver(.unavailable("Cannot read camera frames"))
                    return
                }
                capture.addOutput(output)
                capture.commitConfiguration()

                // Request a low capture rate when supported. Analysis stays capped
                // independently for cameras whose hardware minimum is higher.
                try camera.lockForConfiguration()
                if let range = camera.activeFormat.videoSupportedFrameRateRanges.first(where: {
                    $0.minFrameRate <= 4 && $0.maxFrameRate >= 4
                }) {
                    let duration = CMTime(value: 1, timescale: 4)
                    if CMTimeCompare(duration, range.maxFrameDuration) <= 0 {
                        camera.activeVideoMinFrameDuration = duration
                        camera.activeVideoMaxFrameDuration = duration
                    }
                }
                camera.unlockForConfiguration()
                session = capture
                lastAnalysis = 0
                capture.startRunning()
                if !capture.isRunning { deliver(.unavailable("Camera could not start")) }
            } catch {
                deliver(.unavailable("Camera could not be opened"))
            }
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        sink = nil
        if let session {
            for output in session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            session.stopRunning()
        }
        session = nil
        lastAnalysis = 0
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let sink, session?.isRunning == true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= 0.24 else { return }
        lastAnalysis = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            sink(.unavailable("Camera frames are unavailable"))
            return
        }
        autoreleasepool {
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                let observations = request.results ?? []
                // Keep ambiguous detections: dropping one could make multiple
                // people appear to be a single trusted attention signal.
                let faces = observations.map { face in
                    FacePose(yaw: face.confidence >= 0.7 ? (face.yaw?.doubleValue ?? .nan) : .nan,
                             pitch: face.confidence >= 0.7 ? (face.pitch?.doubleValue ?? .nan) : .nan)
                }
                sink(.faces(faces, time: now))
            } catch {
                sink(.unavailable("Attention detection is unavailable"))
            }
        }
    }
}
