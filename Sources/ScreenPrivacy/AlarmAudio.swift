import AppKit
import CoreAudio
import Darwin

struct AlarmAudioProperty: Codable, Equatable {
    let selector: UInt32
    let element: UInt32
    let bytes: Data
}

@MainActor
protocol AlarmSoundPlaying: AnyObject {
    var volume: Float { get set }
    @discardableResult func stop() -> Bool
}
extension NSSound: AlarmSoundPlaying {}

@MainActor
protocol AlarmAudioBackend {
    func speakerUID() throws -> String
    func snapshot(uid: String) throws -> [AlarmAudioProperty]
    func maximize(uid: String, properties: [AlarmAudioProperty]) throws
    func restore(uid: String, properties: [AlarmAudioProperty], guarded: Bool) -> Bool
    func play(data: Data, uid: String, volume: Double) throws -> any AlarmSoundPlaying
}

@MainActor
protocol AlarmAudioJournal: AnyObject {
    func load() -> Data?
    func save(_ data: Data) throws
    func clear() throws
}
@MainActor
private final class FileAudioJournal: AlarmAudioJournal {
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.iloapps.screenprivacy/alarm-volume.json")
    func load() -> Data? { try? Data(contentsOf: url) }
    func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Generated locally; no download or third-party sound license. The durable
/// journal precedes every mutation and is retained until every restore succeeds.
@MainActor
final class AlarmAudio {
    private struct SavedDevice: Codable {
        let uid: String
        let properties: [AlarmAudioProperty]
    }
    private let backend: any AlarmAudioBackend
    private let journal: any AlarmAudioJournal
    private var sound: (any AlarmSoundPlaying)?
    private var activeUID: String?
    var restorationPending: Bool { journal.load() != nil }

    init(backend: (any AlarmAudioBackend)? = nil, journal: (any AlarmAudioJournal)? = nil) {
        self.backend = backend ?? CoreAudioAlarmBackend()
        self.journal = journal ?? FileAudioJournal()
    }
    func recoverPreviousVolume() { restore(guarded: true) }
    func start(volume: Double) throws {
        if let sound {
            guard (try? backend.speakerUID()) == activeUID else {
                restore(); throw failure("Speaker output changed; alarm audio stopped.")
            }
            sound.volume = Float(volume); return
        }
        restore(guarded: true)
        guard journal.load() == nil else { throw failure("Previous speaker volume could not be restored.") }
        let uid = try backend.speakerUID()
        let snapshot = SavedDevice(uid: uid, properties: try backend.snapshot(uid: uid))
        try journal.save(JSONEncoder().encode(snapshot))
        do {
            try backend.maximize(uid: uid, properties: snapshot.properties)
            activeUID = uid
            sound = try backend.play(data: Self.sirenData(), uid: uid, volume: volume)
        } catch { restore(); throw error }
    }
    func restore(guarded: Bool = false) {
        sound?.stop(); sound = nil; activeUID = nil
        guard let data = journal.load(),
              let snapshot = try? JSONDecoder().decode(SavedDevice.self, from: data) else { return }
        if backend.restore(uid: snapshot.uid, properties: snapshot.properties, guarded: guarded) { try? journal.clear() }
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "ScreenPrivacy.AlarmAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func sirenData() -> Data {
        let rate = 22_050, count = rate * 2
        var pcm = Data(capacity: count * 2)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let frequency = 850 + 350 * sin(2 * .pi * t)
            phase += 2 * .pi * frequency / Double(rate)
            let edge = min(1, min(t * 100, (2 - t) * 100))
            var sample = Int16(sin(phase) * 24_000 * edge).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}


@MainActor
private final class CoreAudioAlarmBackend: AlarmAudioBackend {
    func speakerUID() throws -> String {
        let device = try builtInOutput()
        var a = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &uid) == noErr else { throw failure("Speaker identity unavailable.") }
        return uid as String
    }
    func snapshot(uid: String) throws -> [AlarmAudioProperty] {
        guard let device = device(withUID: uid) else { throw failure("Built-in speakers are unavailable.") }
        var properties: [AlarmAudioProperty] = []
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for element: UInt32 in [0, 1, 2] {
                var a = address(selector, element: element)
                var settable: DarwinBoolean = false
                guard AudioObjectHasProperty(device, &a),
                      AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { continue }
                var value: UInt32 = 0; var size: UInt32 = 4
                guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr, size == 4 else {
                    throw failure("Cannot save the current speaker settings.")
                }
                properties.append(AlarmAudioProperty(selector: selector, element: element,
                                                     bytes: withUnsafeBytes(of: value) { Data($0) }))
            }
        }
        guard properties.contains(where: { $0.selector == kAudioDevicePropertyVolumeScalar }),
              properties.contains(where: { $0.selector == kAudioDevicePropertyMute }) else {
            throw failure("Built-in speaker volume or mute cannot be controlled.")
        }
        return properties
    }
    func maximize(uid: String, properties: [AlarmAudioProperty]) throws {
        guard let device = device(withUID: uid) else { throw failure("Built-in speakers disconnected.") }
        for property in properties {
            var a = address(property.selector, element: property.element)
            var value: UInt32 = property.selector == kAudioDevicePropertyMute ? 0 : Float(1).bitPattern
            guard AudioObjectSetPropertyData(device, &a, 0, nil, 4, &value) == noErr else {
                throw failure("Could not set speaker volume.")
            }
        }
    }
    func restore(uid: String, properties: [AlarmAudioProperty], guarded: Bool) -> Bool {
        // A shared Intel output UID may now select headphones. Re-verify the
        // same internal-speaker source before restoring its saved gain/mute.
        guard (try? speakerUID()) == uid, let device = device(withUID: uid) else { return false }
        var restored = true
        for property in properties {
            guard property.bytes.count == 4 else { return false }
            var a = address(property.selector, element: property.element)
            if guarded {
                var current: UInt32 = 0; var size: UInt32 = 4
                guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &current) == noErr else {
                    restored = false; continue
                }
                let applied: UInt32 = property.selector == kAudioDevicePropertyMute ? 0 : Float(1).bitPattern
                // A user changed this setting after a crash; that newer value owns the device.
                if current != applied { continue }
            }
            let result = property.bytes.withUnsafeBytes {
                AudioObjectSetPropertyData(device, &a, 0, nil, UInt32($0.count), $0.baseAddress!)
            }
            restored = restored && result == noErr
        }
        return restored
    }
    func play(data: Data, uid: String, volume: Double) throws -> any AlarmSoundPlaying {
        guard let sound = NSSound(data: data) else { throw failure("Could not create the siren.") }
        sound.playbackDeviceIdentifier = uid
        sound.volume = Float(min(max(volume, 0.1), 1))
        sound.loops = true
        guard sound.play() else { throw failure("The alarm sound could not start.") }
        return sound
    }
    private func address(_ selector: UInt32, scope: UInt32 = kAudioDevicePropertyScopeOutput,
                         element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    private func devices() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var values = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
        guard !values.isEmpty else { return [] }
        let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!) }
        return result == noErr ? values : []
    }
    private func device(withUID uid: String) -> AudioDeviceID? {
        devices().first { device in
            var a = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
            var size = UInt32(MemoryLayout<CFString>.size)
            var value: CFString = "" as CFString
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr && value as String == uid
        }
    }
    private func builtInOutput() throws -> AudioDeviceID {
        for device in devices() {
            var a = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
            var transport: UInt32 = 0; var size: UInt32 = 4
            guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            a = address(kAudioDevicePropertyStreams)
            guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { continue }
            // Some Intel Macs expose headphones and speakers through one device.
            // Accept only an explicit internal-speaker data source, or the separate
            // built-in speaker device UID used on Apple Silicon.
            a = address(kAudioDevicePropertyDataSource)
            var source: UInt32 = 0; size = 4
            if AudioObjectHasProperty(device, &a) {
                guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &source) == noErr,
                      source == 0x6973706b else { continue } // 'ispk'
            } else {
                a = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
                var uid: CFString = "" as CFString; size = UInt32(MemoryLayout<CFString>.size)
                guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &uid) == noErr,
                      (uid as String).contains("BuiltInSpeaker") else { continue }
            }
            return device
        }
        throw failure("No controllable built-in speakers found. Alarm sound is unavailable.")
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "ScreenPrivacy.AlarmAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

}
