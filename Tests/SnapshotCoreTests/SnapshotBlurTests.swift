import CoreGraphics
import CoreImage
import Testing
@testable import SnapshotCore

struct SnapshotBlurTests {
    @Test func captureSizeBoundsMemoryAndPreservesAspectRatio() {
        for (width, height) in [(1512.0, 982.0), (3840, 2160), (1080, 3840), (7680, 4320)] {
            let display = SnapshotDisplay(id: 1, pointWidth: width, pointHeight: height)
            #expect(max(display.width, display.height) <= 1600)
            #expect(abs(Double(display.width) / Double(display.height) - width / height) < 0.005)
            // The original fixed 12-point default remains the no-argument default.
            #expect(abs(display.blurRadius / display.scale - 12) < 0.001)
        }
    }

    @Test func snapshotRequestPreservesDisplayBoundsAndCoverWindow() {
        let frame = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let display = SnapshotDisplay(id: 7, pointWidth: 1440, pointHeight: 900,
                                      screenRect: frame, coverWindowID: 42)
        #expect(display.screenRect == frame)
        #expect(display.coverWindowID == 42)
    }

    @Test func blurStrengthMapsToGaussianRadiusInRange() {
        // Strength 0 is the heaviest 18-point blur; 1 is the lightest 6-point blur.
        let expectations: [(strength: Double, radius: Double)] = [
            (0, 18), (0.25, 15), (0.5, 12), (0.75, 9), (1, 6)
        ]
        for (strength, radius) in expectations {
            let display = SnapshotDisplay(id: 1, pointWidth: 1000, pointHeight: 800, blurStrength: strength)
            #expect(abs(display.blurRadius / display.scale - radius) < 0.001)
        }
    }

    @Test func blurStrengthClampsExtremeAndInvalidValues() {
        // Out-of-range values clamp to the nearest end; non-finite values fall back to the default.
        for (strength, radius) in [(5.0, 6.0), (-3.0, 18.0), (.nan, 12.0), (.infinity, 12.0)] {
            let display = SnapshotDisplay(id: 1, pointWidth: 1000, pointHeight: 800, blurStrength: strength)
            #expect(abs(display.blurRadius / display.scale - radius) < 0.001)
        }
        // Strength must not change the captured size or aspect ratio.
        let plain = SnapshotDisplay(id: 1, pointWidth: 1000, pointHeight: 800)
        let strong = SnapshotDisplay(id: 1, pointWidth: 1000, pointHeight: 800, blurStrength: 1)
        #expect(plain.width == strong.width && plain.height == strong.height)
    }

    @Test func blurSoftensDetailsWithoutWhiteTintOrTransparentEdges() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try #require(CGContext(data: nil, width: 128, height: 64,
                                           bitsPerComponent: 8, bytesPerRow: 128 * 4,
                                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Two opaque, saturated blocks make blur and unwanted white tint measurable.
        bitmap.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        bitmap.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
        bitmap.fill(CGRect(x: 64, y: 0, width: 64, height: 64))
        let input = try #require(bitmap.makeImage())
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let result = try #require(SnapshotBlur.render(input, radius: 8, context: context))
        #expect(result.width == 128 && result.height == 64)
        // Both slider endpoints must still produce a rendered image, not the opaque fallback.
        #expect(SnapshotBlur.render(input, radius: 6, context: context) != nil)
        #expect(SnapshotBlur.render(input, radius: 18, context: context) != nil)
        bitmap.draw(result, in: CGRect(x: 0, y: 0, width: 128, height: 64))
        let data = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        let middle = (32 * 128 + 64) * 4
        #expect(data[middle] > 40 && data[middle + 2] > 40)
        #expect(data[middle + 1] < 5) // No white/gray wash added to red and blue.
        for pixel in [0, 127, 63 * 128, 64 * 128 - 1] {
            #expect(data[pixel * 4 + 3] == 255) // Edge extension keeps the cover opaque.
        }
    }
}
