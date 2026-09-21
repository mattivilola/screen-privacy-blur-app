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
            #expect(abs(display.blurRadius / display.scale - 12) < 0.001)
        }
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
        let result = try #require(SnapshotBlur.render(input, radius: 8,
                                                     context: CIContext(options: [.useSoftwareRenderer: true])))
        #expect(result.width == 128 && result.height == 64)
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
