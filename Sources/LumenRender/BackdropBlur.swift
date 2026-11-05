import Foundation

/// The backdrop blur is only active during actual zooms. This deliberately
/// changes a GPU mip selection, not the screen content texture or screenshot
/// resampler. Fractional mip levels give smooth transitions on zoom in/out.
public enum BackdropBlur {
    public static func mipLevel(enabled: Bool, cameraScale: Float) -> Float {
        guard enabled, cameraScale.isFinite, cameraScale > 1.02 else { return 0 }
        return min(max((cameraScale - 1) * 2.0, 0), 3.5)
    }
}
