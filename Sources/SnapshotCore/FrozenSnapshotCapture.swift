import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit

public struct SnapshotDisplay: Sendable {
    public let id: CGDirectDisplayID
    public let pointWidth: Double
    public let pointHeight: Double
    /// Global display bounds used by CoreGraphics capture.
    public let screenRect: CGRect
    /// The cover window below which the display is captured.
    public let coverWindowID: CGWindowID
    /// 0 hides details behind heavy blur; 1 keeps large shapes but lets short text stay legible.
    public let blurStrength: Double

    public init(id: CGDirectDisplayID, pointWidth: Double, pointHeight: Double,
                screenRect: CGRect? = nil, coverWindowID: CGWindowID = kCGNullWindowID,
                blurStrength: Double = 0.5) {
        self.id = id
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.screenRect = screenRect ?? CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight)
        self.coverWindowID = coverWindowID
        self.blurStrength = min(max(blurStrength.isFinite ? blurStrength : 0.5, 0), 1)
    }

    // Rendering a blurred image at Retina resolution wastes memory and GPU work.
    var scale: Double { min(1, 1600 / max(1, pointWidth, pointHeight)) }
    var width: Int { max(1, Int((pointWidth * scale).rounded())) }
    var height: Int { max(1, Int((pointHeight * scale).rounded())) }
    // Gaussian radius in screen points: 18 (heavy) down to 6 (light), with the
    // historical 12-point default at the midpoint.
    var blurRadius: Double { (18 - 12 * blurStrength) * scale }
}

/// Captures each display once with ScreenCaptureKit (or CoreGraphics fallback) and blurs the result off the main actor.
public actor FrozenSnapshotCapture {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var busy = false

    public init() {}

    public func capture(displays requested: [SnapshotDisplay]) async throws -> [CGDirectDisplayID: CGImage] {
        guard !busy, CGPreflightScreenCaptureAccess() else { return [:] }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()

        var images: [CGDirectDisplayID: CGImage] = [:]

        // Query shareable content for modern ScreenCaptureKit capture.
        var scFailed = false
        var shareableContent: SCShareableContent?
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            scFailed = true
        }

        for request in requested {
            try Task.checkCancellation()
            var raw: CGImage?

            // 1. Try ScreenCaptureKit (GPU-accelerated, async, modern macOS 14+ standard)
            if !scFailed, let content = shareableContent,
               let display = content.displays.first(where: { $0.displayID == request.id }) {
                do {
                    let excludedWindows = content.windows.filter { $0.windowID == request.coverWindowID }
                    let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                    let config = SCStreamConfiguration()
                    config.width = request.width
                    config.height = request.height
                    config.scalesToFit = true
                    config.showsCursor = false
                    raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } catch {
                    raw = nil
                }
            }

            // 2. Legacy fallback to CGWindowListCreateImage if ScreenCaptureKit was unavailable or failed
            if raw == nil {
                let bounds = request.screenRect
                let option: CGWindowListOption = request.coverWindowID == kCGNullWindowID
                    ? .optionOnScreenOnly
                    : .optionOnScreenBelowWindow
                raw = CGWindowListCreateImage(bounds, option, request.coverWindowID,
                                              [.bestResolution, .boundsIgnoreFraming])
            }

            guard let rawImage = raw else {
                print("Screen Privacy: snapshot capture failed for display \(request.id)")
                continue
            }

            try Task.checkCancellation()
            if let blurred = autoreleasepool(invoking: {
                SnapshotBlur.render(rawImage, radius: request.blurRadius, context: context)
            }) {
                images[request.id] = blurred
            }
        }
        try Task.checkCancellation()
        return images
    }
}

enum SnapshotBlur {
    static func render(_ image: CGImage, radius: Double, context: CIContext) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        // Preserve the desktop colors without the native material's white tint.
        return context.createCGImage(blurred, from: input.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
