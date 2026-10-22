import AVFoundation
import AttentionCore
import CoreImage
import Vision

/// One analyzed camera frame: the poses for `AttentionState` plus what the
/// frame looked like, so the menu can explain why a face was not found.
struct FrameAnalysis: Sendable {
    let faces: [FacePose]
    let time: TimeInterval
    let lighting: LightingCondition
    let usedLightAssist: Bool
}

enum CameraEvent: Sendable {
    case frame(FrameAnalysis)
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
    private var ciContext: CIContext?
    private var preferredAssist: LightAssist?
    var preferredDeviceID: String?
    private let request: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()

    /// Software re-exposures for frames where the face is too backlit or washed out
    /// to detect. Built-in cameras expose no exposure controls, so this is done on
    /// the pixel buffer. At most two run, only when the normal pass is unclear.
    private enum LightAssist: CaseIterable {
        /// Backlit silhouette: open up shadows.
        case liftShadows
        /// Washed-out face in direct sun: pull highlights down.
        case tameHighlights

        func apply(to image: CIImage, adjustment: LightAssistAdjustment) -> CIImage {
            switch self {
            case .liftShadows:
                return image
                    .applyingFilter("CIHighlightShadowAdjust",
                                    parameters: ["inputShadowAmount": 1.0, "inputHighlightAmount": 0.6])
                    // Lift dark midtones without blowing out the bright background.
                    .applyingFilter("CIGammaAdjust", parameters: ["inputPower": adjustment.shadowGamma])
            case .tameHighlights:
                return image
                    .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adjustment.highlightEV])
                    .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.3])
                    .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.25])
            }
        }
    }

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
                let input = try AVCaptureDeviceInput(device: camera)
                guard capture.canAddInput(input) else {
                    deliver(.unavailable("Camera is unavailable"))
                    return
                }
                capture.addInput(input)
                // Check presets with the selected camera attached so low-resolution
                // external cameras keep their supported fallback.
                capture.sessionPreset = capture.canSetSessionPreset(.hd1280x720) ? .hd1280x720
                    : (capture.canSetSessionPreset(.vga640x480) ? .vga640x480 : .low)
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
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                    if camera.isExposurePointOfInterestSupported {
                        camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    }
                }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
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
        ciContext = nil
        preferredAssist = nil
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
                let lighting = Self.lighting(of: buffer)
                let primary = try detectFaces(with: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up))
                var chosen = primary
                var usedLightAssist = false
                if !FaceDetectionMerge.isConclusive(primary) {
                    let assisted = lightAssistedFaces(from: buffer, lighting: lighting.condition,
                                                      adjustment: lighting.adjustment, primary: primary)
                    chosen = FaceDetectionMerge.preferred(primary, assisted)
                    usedLightAssist = chosen == assisted && FaceDetectionMerge.isConclusive(assisted)
                }
                sink(.frame(FrameAnalysis(faces: FaceDetectionMerge.poses(chosen), time: now,
                                          lighting: lighting.condition, usedLightAssist: usedLightAssist)))
            } catch {
                sink(.unavailable("Attention detection is unavailable"))
            }
        }
    }

    private func detectFaces(with handler: VNImageRequestHandler) throws -> [DetectedFace] {
        try handler.perform([request])
        // Keep ambiguous detections: dropping one could make multiple people
        // appear to be a single trusted attention signal. Pose trust is decided
        // later by `FaceDetectionMerge.poses`.
        return (request.results ?? []).map {
            DetectedFace(confidence: Double($0.confidence), yaw: $0.yaw?.doubleValue, pitch: $0.pitch?.doubleValue)
        }
    }

    /// Try the likely correction first, then the other correction on this same
    /// frame if needed. Alternating across frames can repeatedly interrupt the
    /// steady evidence needed to uncover. Never discard primary face evidence.
    private func lightAssistedFaces(from buffer: CVPixelBuffer, lighting: LightingCondition,
                                    adjustment: LightAssistAdjustment, primary: [DetectedFace]) -> [DetectedFace] {
        let first = preferredAssist ?? (lighting == .bright ? .tameHighlights : .liftShadows)
        let variants = [first] + LightAssist.allCases.filter { $0 != first }
        let context = ciContext ?? CIContext(options: [.cacheIntermediates: false])
        ciContext = context
        var chosen = primary
        for variant in variants {
            let image = variant.apply(to: CIImage(cvPixelBuffer: buffer), adjustment: adjustment)
            let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [.ciContext: context])
            let faces = (try? detectFaces(with: handler)) ?? []
            chosen = FaceDetectionMerge.preferred(chosen, faces)
            if FaceDetectionMerge.isConclusive(chosen) {
                preferredAssist = variant
                return chosen
            }
        }
        preferredAssist = nil
        return chosen
    }

    /// Samples every 8th luma pixel; a full pass over the frame is not needed
    /// to tell sunlit or dark scenes apart.
    private static func lighting(of buffer: CVPixelBuffer)
        -> (condition: LightingCondition, adjustment: LightAssistAdjustment) {
        let fallback: (LightingCondition, LightAssistAdjustment) =
            (.normal, LightAssistAdjustment(centerMeanLuma: 0.4, highlightFraction: 0))
        guard CVPixelBufferGetPlaneCount(buffer) > 0 else { return fallback }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return fallback }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let step = 8
        var sum = 0.0, highlights = 0.0, shadows = 0.0, count = 0.0
        var centerSum = 0.0, centerCount = 0.0
        for y in stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: width, by: step) {
                let luma = Double(row[x]) / 255
                sum += luma
                if luma >= 0.92 { highlights += 1 }
                if luma <= 0.08 { shadows += 1 }
                count += 1
                if x >= width / 4, x < width * 3 / 4, y >= height / 4, y < height * 3 / 4 {
                    centerSum += luma
                    centerCount += 1
                }
            }
        }
        guard count > 0 else { return fallback }
        let center = centerCount > 0 ? centerSum / centerCount : sum / count
        let condition = LightingCondition.classify(meanLuma: sum / count, highlightFraction: highlights / count,
                                          shadowFraction: shadows / count,
                                          centerMeanLuma: center)
        return (condition, LightAssistAdjustment(centerMeanLuma: center, highlightFraction: highlights / count))
    }
}
