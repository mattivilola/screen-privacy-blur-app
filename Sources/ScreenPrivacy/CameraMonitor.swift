import AVFoundation
import AttentionCore
import Vision

enum CameraEvent: Sendable {
    case faces([FacePose], time: TimeInterval)
    case unavailable(String)
}

public struct CameraDevice: Identifiable, Sendable, Equatable {
    public let id: String
    public let localizedName: String
    public let isSuspended: Bool

    public init(id: String, localizedName: String, isSuspended: Bool = false) {
        self.id = id
        self.localizedName = localizedName
        self.isSuspended = isSuspended
    }
}

/// All mutable capture state is confined to `queue`, including delegate callbacks.
/// The only cross-queue values are immutable events and the sendable callback.
final class CameraMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.iloapps.screenprivacy.camera", qos: .utility)
    private var session: AVCaptureSession?
    private var sink: (@Sendable (CameraEvent) -> Void)?
    private var lastAnalysis: TimeInterval = 0
    var preferredDeviceID: String?
    private let request: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()

    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CameraDevice(id: $0.uniqueID, localizedName: $0.localizedName, isSuspended: $0.isSuspended)
        }
    }

    func start(deliver: @escaping @Sendable (CameraEvent) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            sink = deliver
            do {
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .externalUnknown, .continuityCamera],
                    mediaType: .video,
                    position: .unspecified
                )
                let available = discovery.devices

                // Prefer user-selected device -> system default -> first active non-suspended device
                let camera: AVCaptureDevice?
                if let preferredID = preferredDeviceID,
                   let match = available.first(where: { $0.uniqueID == preferredID && !$0.isSuspended }) {
                    camera = match
                } else if let defaultCam = AVCaptureDevice.default(for: .video), !defaultCam.isSuspended {
                    camera = defaultCam
                } else {
                    camera = available.first(where: { !$0.isSuspended }) ?? available.first
                }

                guard let camera else {
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

                // Hardware throttling: request 4 FPS if supported; otherwise throttle sensor
                // to the lowest supported frame rate (longest frame duration) to save battery.
                try camera.lockForConfiguration()
                if let lowestRange = camera.activeFormat.videoSupportedFrameRateRanges.min(by: { $0.minFrameRate < $1.minFrameRate }) {
                    if lowestRange.minFrameRate <= 4 && lowestRange.maxFrameRate >= 4 {
                        let duration = CMTime(value: 1, timescale: 4)
                        if CMTimeCompare(duration, lowestRange.maxFrameDuration) <= 0 {
                            camera.activeVideoMinFrameDuration = duration
                            camera.activeVideoMaxFrameDuration = duration
                        }
                    } else {
                        camera.activeVideoMinFrameDuration = lowestRange.maxFrameDuration
                        camera.activeVideoMaxFrameDuration = lowestRange.maxFrameDuration
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
