import CoreAudio
import Foundation

/// A microphone or other audio input the user can pick in the menu.
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public enum Transport: Sendable, Hashable {
        case builtIn, bluetooth, usb, virtual, aggregate, other
    }

    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: Transport

    public var symbolName: String {
        switch transport {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "mic"
        case .virtual, .aggregate: "waveform"
        case .other: "mic"
        }
    }
}

/// Enumerates Core Audio input devices and reports hot-plug changes.
public enum AudioInputDevices {
    public static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap(device(for:))
            .filter { !$0.uid.hasPrefix("CADefaultDeviceAggregate") }
            .sorted { lhs, rhs in
                if (lhs.transport == .builtIn) != (rhs.transport == .builtIn) { return lhs.transport == .builtIn }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public static func defaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }
        return device(for: deviceID)
    }

    /// The current Core Audio id for a persisted device UID, if that device is connected and has inputs.
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        all().first { $0.uid == uid }?.id
    }

    /// Emits whenever devices are added/removed or the system default input changes.
    public static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let listener = DeviceListener(continuation: continuation)
            continuation.onTermination = { _ in listener.remove() }
        }
    }

    // MARK: - Core Audio plumbing

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func device(for id: AudioObjectID) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0,
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transport(id))
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioObjectID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return .other }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return .other
        }
    }
}

/// Registers Core Audio property listeners; built outside any actor so the callback is nonisolated.
private final class DeviceListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.milescs.apen.audio-devices")
    private let block: AudioObjectPropertyListenerBlock
    private var addresses: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
    ]
    private let lock = NSLock()
    private var removed = false

    init(continuation: AsyncStream<Void>.Continuation) {
        block = { _, _ in continuation.yield() }
        for index in addresses.indices {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], queue, block)
        }
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        for index in addresses.indices {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], queue, block)
        }
    }
}
