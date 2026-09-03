import Foundation

/// Spec §6.7. Detection only; enabling the AX tree is added in Part 2.
public enum ElectronSupport {
    public static func isElectronBundle(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// Spec §5.7. Tried in order; the first accepted attribute wins.
    public static let enableAttributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]
}
