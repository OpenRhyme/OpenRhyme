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

    /// With no focused window, the URL/document/window-title rules cannot be evaluated at all —
    /// a protected page reachable only through the focused element would otherwise be harvested.
    /// `nil` means "no windowless guard applies" (open, or a disabled policy, which still fails
    /// open). Shared by every AX entry point that can be called with a nil window
    /// (`AXClient.focusedContext`, `AXClient.focusedElementInspection`) so they can never diverge
    /// on this again — that divergence (fixed in privacy fix round 2) is exactly how one of them
    /// kept reading content while the other correctly refused.
    public func protectionForWindowlessContext() -> Protection? {
        guard enabled,
            !protectedURLPatterns.isEmpty || !protectedDocumentPatterns.isEmpty
                || !protectedWindowTitlePatterns.isEmpty
        else { return nil }
        return .protected(rule: "unverifiable-context")
    }

    /// The complete window-level verdict for a focused context: the configured rules, plus the
    /// windowless fail-closed guard when there is no focused window to evaluate them against.
    ///
    /// Whole-branch review I6: every AX entry point that reads a focused context has to apply
    /// *both* halves in the same order, and hand-copying that pair into each one is exactly how
    /// `focusedContext` and `focusedElementInspection` diverged in privacy fix round 2 — one kept
    /// reading content the other had already refused. `protectionForWindowlessContext` was
    /// factored out then; this is the rest of it, so there is one source of truth for "may this
    /// context be read at all".
    public func evaluateFocusedContext(bundleID: String?, window: WindowInfo?) -> Protection {
        let verdict = evaluateContext(
            bundleID: bundleID, windowTitle: window?.title, document: window?.document,
            url: window?.url)
        if case .protected = verdict { return verdict }
        guard window == nil, let windowless = protectionForWindowlessContext() else { return .open }
        return windowless
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

    /// A pattern matches when it matches the full path or the last component, case-insensitively,
    /// so `.env` catches `/Users/me/proj/.env` and `/Users/me/proj/.ENV` alike, while
    /// `environment.md` matches neither.
    func matchesDocumentPattern(_ document: String) -> Bool {
        let path = (document as NSString).expandingTildeInPath
        let name = (path as NSString).lastPathComponent
        return protectedDocumentPatterns.contains { pattern in
            fnmatch(pattern, name, FNM_CASEFOLD) == 0 || fnmatch(pattern, path, FNM_CASEFOLD) == 0
        }
    }
}
