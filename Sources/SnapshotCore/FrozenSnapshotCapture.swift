import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit

public struct SnapshotDisplay: Sendable {
    public let id: CGDirectDisplayID
    public let pointWidth: Double
    public let pointHeight: Double

    public init(id: CGDirectDisplayID, pointWidth: Double, pointHeight: Double) {
        self.id = id
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
    }

    // Rendering a blurred image at Retina resolution wastes memory and GPU work.
    var scale: Double { min(1, 1600 / max(1, pointWidth, pointHeight)) }
    var width: Int { max(1, Int((pointWidth * scale).rounded())) }
    var height: Int { max(1, Int((pointHeight * scale).rounded())) }
    var blurRadius: Double { 12 * scale }
}

/// Owns image processing off the main actor. There is no stream or capture timer.
public actor FrozenSnapshotCapture {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var busy = false

    public init() {}

    public func capture(displays requested: [SnapshotDisplay]) async throws -> [CGDirectDisplayID: CGImage] {
        // A cancelled ScreenCaptureKit request may still be finishing. Never pile
        // up screenshot requests during rapid cover/uncover or display changes.
        guard !busy, CGPreflightScreenCaptureAccess() else { return [:] }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // Never capture our neutral cover or branding into the frozen image.
        guard !ownApps.isEmpty else { return [:] }
        var images: [CGDirectDisplayID: CGImage] = [:]
        for request in requested {
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == request.id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = request.width
            configuration.height = request.height
            configuration.showsCursor = false
            configuration.capturesAudio = false
            do {
                let raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                try Task.checkCancellation()
                // Only the blurred image crosses back to the UI. Raw pixels are
                // transient; nothing is written to disk, logged, or transmitted.
                if let blurred = autoreleasepool(invoking: {
                    SnapshotBlur.render(raw, radius: request.blurRadius, context: context)
                }) {
                    images[request.id] = blurred
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unavailable display must not prevent covering the others.
                // Its opaque placeholder remains in place.
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
