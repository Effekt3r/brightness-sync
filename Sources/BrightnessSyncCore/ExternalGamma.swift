import CoreGraphics

/// Dims the external display's picture by scaling its gamma table (public CoreGraphics API). macOS
/// restores the normal table when this process exits, so a crash or uninstall never leaves the picture
/// dimmed (verified on this Mac, 2026-10-31).
public final class ExternalGamma: PictureDimmer {
    public init() {}

    public func setPictureLevel(_ level: Double) -> Bool {
        guard level < 1 else {
            CGDisplayRestoreColorSyncSettings()
            return true
        }
        guard let id = Displays.online().first(where: { CGDisplayIsBuiltin($0) == 0 }) else { return false }
        // A linear ramp up to `level`. The LS24A600U's own table is linear, so nothing else is lost.
        let top = CGGammaValue(level)
        return CGSetDisplayTransferByFormula(id, 0, top, 1, 0, top, 1, 0, top, 1) == .success
    }
}
