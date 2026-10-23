import Foundation
import IOKit

/// Read-only power-domain status; unknown hardware never counts as a closed lid.
enum LidState {
    static var isClosed: Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(entry) }
        return (IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString,
                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }
}
