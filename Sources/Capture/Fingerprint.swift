import Core
import Foundation

/// Spec 2026-09-03 §4: the place-level identity of what is on screen — app + normalized window
/// title + document + URL without fragment — as the first 16 hex characters of SHA-256 over a
/// canonical string. A contract: Compact groups entities and visits by it, so its form is
/// pinned by golden tests. Deliberately never includes element identity.
public enum Fingerprint {
    static let separator = "\u{1F}"

    public static func canonical(
        bundleID: String?, windowTitle: String?, document: String?, url: String?
    ) -> String {
        [
            bundleID ?? "", TitleNormalizer.normalize(windowTitle) ?? "", document ?? "",
            withoutFragment(url) ?? "",
        ].joined(separator: separator)
    }

    public static func compute(
        bundleID: String?, windowTitle: String?, document: String?, url: String?
    ) -> String {
        let digest = Hashing.sha256Hex(
            canonical(bundleID: bundleID, windowTitle: windowTitle, document: document, url: url))
        return String(digest.prefix(16))
    }

    static func withoutFragment(_ url: String?) -> String? {
        guard let url, let hash = url.firstIndex(of: "#") else { return url }
        return String(url[..<hash])
    }
}
