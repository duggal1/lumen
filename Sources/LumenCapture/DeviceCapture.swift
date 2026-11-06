import Foundation
import AVFoundation

/// iPhone / iPad over USB.
///
/// Honest limitation (documented, not faked): ScreenCaptureKit cannot see
/// iOS devices, and AVFoundation's Continuity Camera surface exposes an
/// iPhone as a *camera* (its rear camera feed), not its screen. There is
/// no public SDK path to capture an iPhone's screen over USB from a Mac
/// app without the device running a companion app. So this type discovers
/// Continuity Camera devices and fails loudly for anything else instead
/// of silently recording the wrong source.
public enum DeviceCapture {
    public struct Device: Sendable, Hashable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// Continuity Camera / external video devices visible to AVFoundation.
    public static func availableDevices() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .externalUnknown],
            mediaType: .video, position: .unspecified)
        return session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    public enum DeviceError: Error, Sendable {
        /// No such Continuity Camera device is connected.
        case notConnected(String)
        /// The device is connected, but its screen cannot be captured with
        /// public frameworks (see type doc). A companion app would be needed.
        case screenCaptureUnsupported(String)
    }

    /// Resolves a device for capture. Throws loudly; never substitutes a
    /// webcam or the Mac display for a requested iPhone.
    public static func resolve(deviceID: String) throws -> Device {
        guard let found = availableDevices().first(where: { $0.id == deviceID }) else {
            throw DeviceError.notConnected(deviceID)
        }
        throw DeviceError.screenCaptureUnsupported(found.name)
    }
}
