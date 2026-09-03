import Core
import Darwin
import Foundation

/// Whether a focused context may be read at all (spec 2026-09-03 privacy §5.1).
public enum Protection: Sendable, Equatable {
    case open
    case protected(rule: String)
}

/// The compiled protect rules. Matching is deliberately simple and auditable — substring for
/// URLs, titles and field names, `fnmatch` globs for document paths, set membership for bundle
/// ids. A mis-written regex that silently matches nothing is a privacy failure; a substring
/// cannot fail that way.
public struct PrivacyPolicy: Sendable, Equatable {
    public var enabled: Bool
    public var protectedBundleIDs: Set<String>
    public var protectedURLPatterns: [String]
    public var protectedDocumentPatterns: [String]
    public var protectedWindowTitlePatterns: [String]
    public var credentialFieldPatterns: [String]
    public var entropyRedaction: Bool

    public init(settings: PrivacySettings) {
        enabled = settings.enabled
        protectedBundleIDs = settings.protectedBundleIDs
        protectedURLPatterns = settings.protectedURLPatterns.map { $0.lowercased() }
        protectedDocumentPatterns = settings.protectedDocumentPatterns
        protectedWindowTitlePatterns = settings.protectedWindowTitlePatterns.map { $0.lowercased() }
        credentialFieldPatterns = settings.credentialFieldPatterns.map { $0.lowercased() }
        entropyRedaction = settings.entropyRedaction
    }

    /// Everything open — `privacy.enabled: false`, and the policy `inspect` uses with
    /// `--ignore-privacy`. Never affects the `AXSecureTextField` guard, which is unconditional.
    public static let disabled: PrivacyPolicy = {
        var settings = PrivacySettings()
        settings.enabled = false
        return PrivacyPolicy(settings: settings)
    }()

    /// Checked in a fixed order so `protectedBy` is stable for a context matching several rules.
    public func evaluateContext(
        bundleID: String?, windowTitle: String?, document: String?, url: String?
    ) -> Protection {
        guard enabled else { return .open }
        if let bundleID, protectedBundleIDs.contains(bundleID) {
            return .protected(rule: "bundle-id")
        }
        for candidate in [url, document] {
            guard let text = candidate?.lowercased() else { continue }
            if protectedURLPatterns.contains(where: text.contains) {
                return .protected(rule: "url")
            }
        }
        if let document, matchesDocumentPattern(document) {
            return .protected(rule: "document")
        }
        if let title = windowTitle?.lowercased(),
            protectedWindowTitlePatterns.contains(where: title.contains)
        {
            return .protected(rule: "window-title")
        }
        return .open
    }

    /// A field whose name says credential, even when the app never marked it secure.
    public func isCredentialField(identifier: String?, title: String?) -> Bool {
        guard enabled else { return false }
        for candidate in [identifier, title] {
            guard let text = candidate?.lowercased(), !text.isEmpty else { continue }
            if credentialFieldPatterns.contains(where: text.contains) { return true }
        }
        return false
    }

    /// A pattern matches when it matches the full path or the last component, so `.env` catches
    /// `/Users/me/proj/.env` while `environment.md` matches neither.
    func matchesDocumentPattern(_ document: String) -> Bool {
        let path = (document as NSString).expandingTildeInPath
        let name = (path as NSString).lastPathComponent
        return protectedDocumentPatterns.contains { pattern in
            fnmatch(pattern, name, 0) == 0 || fnmatch(pattern, path, 0) == 0
        }
    }
}
