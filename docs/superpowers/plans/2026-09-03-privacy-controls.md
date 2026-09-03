# Privacy Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop sensitive contexts (password managers, vault URLs, `.env` and key files, credential fields) from ever being read; redact secret shapes from the text that is captured; let the user delete what is already stored; and make every read path — including the MCP — go through redaction.

**Architecture:** A pure `PrivacyPolicy` (compiled from config) is evaluated *inside* `focusedContext`, between the cheap identity read and the content ladder, so a protected context's text never enters the process — the daemon emits an app-level marker instead. A pure `SecretRedactor` (gitleaks-derived corpus + entropy backstop) runs in `Redaction.apply`, the single chokepoint every captured value already passes, and again at read time in `openrhyme events` so rules added later protect rows captured earlier. The Python MCP stops opening SQLite and reads through the CLI, so the rules exist once, in one language.

**Tech Stack:** Swift 6 (tools 6.0), macOS 14+, ApplicationServices, SQLite, Swift Testing; Python 3.12 + `mcp` SDK for the MCP repo.

**Spec:** `docs/superpowers/specs/2026-09-03-privacy-controls-design.md` — read it; this plan implements §4–§9.

## Global Constraints

- Swift 6 language mode, macOS 14+. No new dependencies. **No network code.** **No bundled model** — detection is regex plus entropy only.
- **`Capture` and `Store` never import each other** (MVP layout rule). Anything needing both lives in `Sources/openrhyme`.
- **No SQLite schema change (stays v1).** `extra` gains additive keys (`protected`, `protectedBy`, `redacted`); no new `EventKind`.
- The `AXSecureTextField` guard is unconditional and **cannot** be disabled by config, ever. `privacy.enabled: false` disables only the new context/secret machinery.
- A protected context performs **zero** content reads — the ladder must not run, not run-and-discard.
- Redaction runs **after** the existing byte cap, so its cost is bounded by `capture.max_value_bytes`.
- Test secrets are **synthetic and non-functional** — never a real key, never a plausible live credential.
- `make format` before every commit; CI runs `swift format lint --strict` (line length 100, 4-space indent) and, in the MCP repo, `make check` (ruff + mypy + pytest).
- Swift Testing only; nothing requires a TCC grant except suites gated behind `OPENRHYME_LIVE_AX=1`.
- Commit messages: short single line, then exactly these two trailer lines:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2`.

---

## File structure

| Path | Responsibility |
|---|---|
| `Sources/Capture/PrivacyPolicy.swift` | **New.** `Protection`, `PrivacyPolicy`, context evaluation, credential-field matching (Task 1). |
| `Sources/Core/Config.swift` | **New** `privacy` block with add/remove list semantics; `capture.retention_days` (Task 1). |
| `Sources/Capture/SecretRedactor.swift` | **New.** Rule corpus + entropy backstop (Task 2). |
| `Sources/Capture/Redaction.swift` | Credential-field guard, secret redaction, `redactedRules` (Task 3). |
| `Sources/Capture/AXTypes.swift` | `FocusedContext.protection`; `AXReading.focusedContext(of:reusing:policy:)` (Task 4). |
| `Sources/Capture/AXClient.swift`, `AXClient+Inspect.swift` | Policy check before the ladder; `inspect` honours the policy (Task 4). |
| `Sources/Capture/HeartbeatDiff.swift` | Protected marker rows; `extra.redacted` (Task 5). |
| `Sources/Capture/Capturer.swift` | Compile the policy on load/reload and pass it to every read (Task 6). |
| `Sources/Core/Paths.swift`, `Sources/Store/EventStore.swift` | `0700` dir, `0600` db; `deleteEvents(ids:)`, `deleteEvents(olderThan:)`, `vacuum()` (Task 7). |
| `Sources/openrhyme/PurgeCommand.swift` | **New.** `openrhyme purge` (Task 8). |
| `Sources/openrhyme/PrivacyCommand.swift` | **New.** `openrhyme privacy` (Task 9). |
| `Sources/openrhyme/InspectCommand.swift` | `--ignore-privacy` (Task 9). |
| `Sources/openrhyme/EventsCommand.swift` | Read-time redaction, `--max-value-chars` (Task 10). |
| `Sources/openrhyme/DaemonCommand.swift` | Retention sweep on start and daily (Task 10). |
| `openrhyme-mcp/src/openrhyme_mcp/{server,store}.py` | `events` reads through the CLI; direct-SQLite query path deleted (Task 11). |
| `README.md`, `SECURITY.md`, `docs/accessibility-api.md`, `CLAUDE.md` | Rules, config, and the stated limits (Task 12). |

**Deliberate refinement of the spec:** spec §7.3 has the *daemon* log "N stored rows match new protect rules" after a config reload. That would force `Capture` to read the store, which the layout rule forbids. Instead `openrhyme privacy` reports that count on demand (Task 9) — same information, no layering violation, and it lives in the command whose job is showing the policy.

---

### Task 1: `PrivacyPolicy` and the `privacy` config block

**Files:**
- Create: `Sources/Capture/PrivacyPolicy.swift`
- Modify: `Sources/Core/Config.swift`
- Test: `Tests/CaptureTests/PrivacyPolicyTests.swift`, `Tests/CoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `public enum Protection: Sendable, Equatable { case open; case protected(rule: String) }`; `public struct PrivacyPolicy: Sendable, Equatable` with `enabled`, `protectedBundleIDs: Set<String>`, `protectedURLPatterns: [String]`, `protectedDocumentPatterns: [String]`, `protectedWindowTitlePatterns: [String]`, `credentialFieldPatterns: [String]`, `entropyRedaction: Bool`, `init(settings: PrivacySettings)`, `static let disabled: PrivacyPolicy`, `func evaluateContext(bundleID:windowTitle:document:url:) -> Protection`, `func isCredentialField(identifier:title:) -> Bool`; `Core.PrivacySettings` with the defaults and add/remove parsing; `CaptureSettings.retentionDays: Int`.

- [ ] **Step 1: Write the failing tests**

`Tests/CaptureTests/PrivacyPolicyTests.swift`:
```swift
import Testing

@testable import Capture
@testable import Core

@Suite struct PrivacyPolicyTests {
    private var policy: PrivacyPolicy { PrivacyPolicy(settings: PrivacySettings()) }

    @Test func protectsPasswordManagerApps() {
        #expect(
            policy.evaluateContext(
                bundleID: "com.1password.1password", windowTitle: "Vault", document: nil, url: nil)
                == .protected(rule: "bundle-id"))
        #expect(
            policy.evaluateContext(
                bundleID: "com.apple.TextEdit", windowTitle: "notes", document: nil, url: nil)
                == .open)
    }

    @Test func protectsVaultAndCredentialURLs() {
        #expect(
            policy.evaluateContext(
                bundleID: "com.google.Chrome", windowTitle: "Vault",
                document: nil, url: "https://bao.example.net/ui/vault/secrets/fleet/list")
                == .protected(rule: "url"))
        #expect(
            policy.evaluateContext(
                bundleID: "com.google.Chrome", windowTitle: "Settings", document: nil,
                url: "https://console.example.com/admin/settings/trust-credentials")
                == .protected(rule: "url"))
        #expect(
            policy.evaluateContext(
                bundleID: "com.google.Chrome", windowTitle: "Docs", document: nil,
                url: "https://example.com/vaulted-goods") == .open)
    }

    @Test func protectsSensitiveDocumentsByNameAndPath() {
        for path in [
            "/Users/me/proj/.env", "/Users/me/proj/.env.local", "/Users/me/certs/server.pem",
            "/Users/me/.ssh/id_rsa", "/Users/me/.aws/credentials", "/Users/me/app/secrets.yaml",
            "/Users/me/.npmrc",
        ] {
            #expect(
                policy.evaluateContext(
                    bundleID: "com.microsoft.VSCode", windowTitle: "editor", document: path,
                    url: nil) == .protected(rule: "document"), "\(path)")
        }
        // Near-misses that must NOT be protected.
        for path in [
            "/Users/me/docs/environment.md", "/Users/me/notes/keynote.txt",
            "/Users/me/src/Secrets.swift.md", "/Users/me/env-setup-guide.txt",
        ] {
            #expect(
                policy.evaluateContext(
                    bundleID: "com.microsoft.VSCode", windowTitle: "editor", document: path,
                    url: nil) == .open, "\(path)")
        }
    }

    @Test func protectsSafariPrivateBrowsingByTitle() {
        #expect(
            policy.evaluateContext(
                bundleID: "com.apple.Safari", windowTitle: "Private Browsing", document: nil,
                url: nil) == .protected(rule: "window-title"))
    }

    @Test func credentialFieldsAreMatchedByNameNotOnlySubrole() {
        #expect(policy.isCredentialField(identifier: "current-password", title: nil))
        #expect(policy.isCredentialField(identifier: nil, title: "API Key"))
        #expect(policy.isCredentialField(identifier: "user_token", title: nil))
        #expect(!policy.isCredentialField(identifier: "username", title: "Search"))
        #expect(!policy.isCredentialField(identifier: nil, title: nil))
    }

    @Test func disabledPolicyProtectsNothing() {
        let off = PrivacyPolicy.disabled
        #expect(
            off.evaluateContext(
                bundleID: "com.1password.1password", windowTitle: "Private Browsing",
                document: "/Users/me/.env", url: "https://x/ui/vault/") == .open)
        #expect(!off.isCredentialField(identifier: "password", title: nil))
    }

    @Test func bundleIDIsCheckedBeforeURLSoTheRuleNameIsStable() {
        #expect(
            policy.evaluateContext(
                bundleID: "com.1password.1password", windowTitle: nil, document: nil,
                url: "https://1password.com/vault") == .protected(rule: "bundle-id"))
    }
}
```

Append to `Tests/CoreTests/ConfigTests.swift`:
```swift
    @Test func privacyDefaultsAndAddRemoveSemantics() throws {
        let defaults = PrivacySettings()
        #expect(defaults.enabled)
        #expect(defaults.entropyRedaction)
        #expect(defaults.protectedBundleIDs.contains("com.1password.1password"))
        #expect(defaults.protectedDocumentPatterns.contains(".env"))
        #expect(CaptureSettings().retentionDays == 0)

        let url = tempURL()
        try """
        {"schema":1,"allowlist":[],
         "capture":{"retention_days":30},
         "privacy":{"entropy_redaction":false,
           "protected_bundle_ids":{"add":["com.example.Vault"],"remove":["com.apple.keychainaccess"]},
           "protected_document_patterns":{"add":["*.secret"],"remove":[".npmrc"]}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(config.capture.retentionDays == 30)
        #expect(!config.privacy.entropyRedaction)
        #expect(config.privacy.protectedBundleIDs.contains("com.example.Vault"))
        #expect(config.privacy.protectedBundleIDs.contains("com.1password.1password"))
        #expect(!config.privacy.protectedBundleIDs.contains("com.apple.keychainaccess"))
        #expect(config.privacy.protectedDocumentPatterns.contains("*.secret"))
        #expect(!config.privacy.protectedDocumentPatterns.contains(".npmrc"))

        try config.save(to: url)
        let again = try Config.load(from: url)
        #expect(again.privacy == config.privacy)
        #expect(again.capture.retentionDays == 30)
    }

    @Test func privacyCanBeDisabledWholesale() throws {
        let url = tempURL()
        try #"{"schema":1,"allowlist":[],"privacy":{"enabled":false}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let config = try Config.load(from: url)
        #expect(!config.privacy.enabled)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "PrivacyPolicyTests|ConfigTests"`
Expected: build errors — `PrivacySettings`, `PrivacyPolicy`, `retentionDays` not found.

- [ ] **Step 3: Implement `PrivacySettings` in `Sources/Core/Config.swift`**

Add above `CaptureSettings`:
```swift
/// Spec 2026-09-03 privacy §5.1/§6. Lists are `defaults ∪ add \ remove`, so a user extends or
/// disables individual defaults without restating the whole list.
public struct PrivacySettings: Sendable, Equatable {
    public var enabled: Bool = true
    public var entropyRedaction: Bool = true
    public var protectedBundleIDs: Set<String> = Self.defaultBundleIDs
    public var protectedURLPatterns: [String] = Self.defaultURLPatterns
    public var protectedDocumentPatterns: [String] = Self.defaultDocumentPatterns
    public var protectedWindowTitlePatterns: [String] = Self.defaultWindowTitlePatterns
    public var credentialFieldPatterns: [String] = Self.defaultCredentialFieldPatterns

    public static let defaultBundleIDs: Set<String> = [
        "com.1password.1password", "com.1password.7", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "in.sinew.Enpass-Desktop",
        "com.dashlane.Dashlane", "com.apple.keychainaccess",
    ]
    public static let defaultURLPatterns: [String] = [
        "1password.com", "bitwarden.com", "lastpass.com", "dashlane.com", "/ui/vault/",
        "://vault.", "/settings/credentials", "/trust-credentials", "/admin/credentials",
        "/iam-admin/serviceaccounts", "/apikeys",
    ]
    public static let defaultDocumentPatterns: [String] = [
        ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.keystore", "id_rsa*", "id_ed25519*",
        "id_ecdsa*", "credentials", "credentials.*", "secrets.*", ".npmrc", ".netrc", ".pgpass",
        "*/.aws/*", "*/.ssh/*", "*/.gnupg/*",
    ]
    public static let defaultWindowTitlePatterns: [String] = ["private browsing"]
    public static let defaultCredentialFieldPatterns: [String] = [
        "password", "passwd", "secret", "token", "api key", "api_key", "apikey", "private key",
        "passphrase", "otp", "2fa", "mfa code",
    ]

    public init() {}

    static let keys = (
        enabled: "enabled", entropy: "entropy_redaction", bundles: "protected_bundle_ids",
        urls: "protected_url_patterns", documents: "protected_document_patterns",
        titles: "protected_window_title_patterns", fields: "credential_field_patterns",
        add: "add", remove: "remove"
    )

    init(json: [String: JSONValue]) {
        self.init()
        if let v = json[Self.keys.enabled]?.boolValue { enabled = v }
        if let v = json[Self.keys.entropy]?.boolValue { entropyRedaction = v }
        protectedBundleIDs = Set(
            Self.resolve(Array(Self.defaultBundleIDs), json[Self.keys.bundles]))
        protectedURLPatterns = Self.resolve(Self.defaultURLPatterns, json[Self.keys.urls])
        protectedDocumentPatterns = Self.resolve(
            Self.defaultDocumentPatterns, json[Self.keys.documents])
        protectedWindowTitlePatterns = Self.resolve(
            Self.defaultWindowTitlePatterns, json[Self.keys.titles])
        credentialFieldPatterns = Self.resolve(
            Self.defaultCredentialFieldPatterns, json[Self.keys.fields])
    }

    /// `defaults ∪ add \ remove`, order-stable: defaults first, then additions.
    private static func resolve(_ defaults: [String], _ value: JSONValue?) -> [String] {
        guard let object = value?.objectValue else { return defaults }
        let add = object[keys.add]?.arrayValue?.compactMap(\.stringValue) ?? []
        let remove = Set(object[keys.remove]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var out = defaults.filter { !remove.contains($0) }
        for item in add where !out.contains(item) && !remove.contains(item) { out.append(item) }
        return out
    }

    /// Only the user's deltas are written back, so a future change to a default list reaches
    /// existing installs instead of being frozen into their config.
    func merged(into json: [String: JSONValue]) -> [String: JSONValue] {
        var out = json
        out[Self.keys.enabled] = .bool(enabled)
        out[Self.keys.entropy] = .bool(entropyRedaction)
        out[Self.keys.bundles] = Self.delta(
            Array(Self.defaultBundleIDs), Array(protectedBundleIDs))
        out[Self.keys.urls] = Self.delta(Self.defaultURLPatterns, protectedURLPatterns)
        out[Self.keys.documents] = Self.delta(
            Self.defaultDocumentPatterns, protectedDocumentPatterns)
        out[Self.keys.titles] = Self.delta(
            Self.defaultWindowTitlePatterns, protectedWindowTitlePatterns)
        out[Self.keys.fields] = Self.delta(
            Self.defaultCredentialFieldPatterns, credentialFieldPatterns)
        return out
    }

    private static func delta(_ defaults: [String], _ current: [String]) -> JSONValue {
        let defaultSet = Set(defaults)
        let currentSet = Set(current)
        return .object([
            keys.add: .array(current.filter { !defaultSet.contains($0) }.sorted().map(JSONValue.string)),
            keys.remove: .array(defaults.filter { !currentSet.contains($0) }.sorted().map(JSONValue.string)),
        ])
    }
}
```
In `CaptureSettings`, add `public var retentionDays: Int = 0`, the key `retention: "retention_days"`, parsing (`if let v = json[Self.keys.retention]?.doubleValue, let exact = Int(exactly: v) { retentionDays = exact }`), the `merged` line, and `retentionDays` in the hand-written `==`.
In `Config`, add `public var privacy: PrivacySettings`, an `init` parameter defaulted to `PrivacySettings()`, `let privacy = PrivacySettings(json: raw["privacy"]?.objectValue ?? [:])` in `load`, and `out["privacy"] = .object(privacy.merged(into: raw["privacy"]?.objectValue ?? [:]))` in `save`.

- [ ] **Step 4: Implement `Sources/Capture/PrivacyPolicy.swift`**

```swift
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
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter "PrivacyPolicyTests|ConfigTests"` then the full `swift test`.
Expected: the new tests pass; every pre-existing test unchanged (all new fields are defaulted; `Config` equality still round-trips).

- [ ] **Step 6: Format and commit**

```bash
make format && make lint
git add Sources/Core/Config.swift Sources/Capture/PrivacyPolicy.swift Tests/CaptureTests/PrivacyPolicyTests.swift Tests/CoreTests/ConfigTests.swift
git commit -m "Add the privacy policy and its config block

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 2: `SecretRedactor` (pure)

**Files:**
- Create: `Sources/Capture/SecretRedactor.swift`
- Test: `Tests/CaptureTests/SecretRedactorTests.swift`

**Interfaces:**
- Produces: `public struct RedactionResult: Sendable, Equatable { public var text: String; public var rules: [String] }`; `public enum SecretRedactor { public static func redact(_ text: String, entropyEnabled: Bool) -> RedactionResult }`. `rules` is sorted and de-duplicated. Replacement form is `[redacted:<rule>]`.

- [ ] **Step 1: Write the failing tests**

`Tests/CaptureTests/SecretRedactorTests.swift` (every credential below is synthetic — random characters in the right shape, no live service):
```swift
import Testing

@testable import Capture

@Suite struct SecretRedactorTests {
    private func redact(_ text: String, entropy: Bool = true) -> RedactionResult {
        SecretRedactor.redact(text, entropyEnabled: entropy)
    }

    @Test func redactsStructuralSecretShapes() {
        let cases: [(String, String)] = [
            ("AKIAQQQQWWWWEEEERRRR", "aws-key"),
            ("ghp_aaaabbbbccccddddeeeeffffgggghhhh1111", "github-token"),
            ("sk_live_" + "aaaabbbbccccddddeeeeffff", "stripe-key"),
            ("xoxb-" + "1111111111-2222222222-aaaabbbbccccdddd", "slack-token"),
            ("AIzaSyAAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIII", "google-api-key"),
            ("sk-ant-api03-aaaabbbbccccddddeeeeffffgggghhhh", "anthropic-key"),
        ]
        for (secret, rule) in cases {
            let result = redact("token is \(secret) ok")
            #expect(result.rules == [rule], "\(rule)")
            #expect(!result.text.contains(secret), "\(rule) leaked")
            #expect(result.text.contains("[redacted:\(rule)]"), "\(rule)")
            #expect(result.text.hasPrefix("token is "), "\(rule) mangled context")
        }
    }

    @Test func redactsPrivateKeyBlocksAndJWTs() {
        let pem = """
            -----BEGIN RSA PRIVATE KEY-----
            AAAABBBBCCCCDDDDEEEEFFFFGGGG
            -----END RSA PRIVATE KEY-----
            """
        let pemResult = redact("before\n\(pem)\nafter")
        #expect(pemResult.rules == ["private-key-block"])
        #expect(!pemResult.text.contains("AAAABBBBCCCCDDDDEEEEFFFFGGGG"))
        #expect(pemResult.text.contains("before"))
        #expect(pemResult.text.contains("after"))

        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.aaaabbbbccccddddeeeeffff"
        let jwtResult = redact("Authorization: \(jwt)")
        #expect(jwtResult.rules.contains("jwt"))
        #expect(!jwtResult.text.contains(jwt))
    }

    @Test func redactsAssignmentsAndConnectionStrings() {
        let assignment = redact("api_key = s3cretVALUE123456")
        #expect(assignment.rules.contains("assignment-secret"))
        #expect(!assignment.text.contains("s3cretVALUE123456"))

        let conn = redact("postgres://appuser:hunter2hunter2@db.internal:5432/app")
        #expect(conn.rules.contains("connection-string"))
        #expect(!conn.text.contains("hunter2hunter2"))
    }

    @Test func entropyBackstopCatchesUnknownShapes() {
        let token = "Xq7Lm2Rt9Zw4Kp1Bn6Vc3Hs8Ja5Ye0Ud"  // mixed case + digits, 32 chars
        let on = redact("value: \(token)")
        #expect(on.rules == ["high-entropy"])
        #expect(!on.text.contains(token))
        let off = redact("value: \(token)", entropy: false)
        #expect(off.rules.isEmpty)
        #expect(off.text.contains(token))
    }

    @Test func leavesOrdinaryTextAlone() {
        let negatives = [
            "Skip to main content / Machines / Apps / Services / DNS / Users",
            "https://github.com/OpenRhyme/OpenRhyme/tree/docs/gtm-product-spec/gtm",
            "/Users/pragadeesh/Developer/OpenRhyme/OpenRhyme/Sources/Capture/AXClient.swift",
            "The quick brown fox jumps over the lazy dog and keeps running onward",
            "550e8400-e29b-41d4-a716-446655440000",
            "abd7fc7d558062550e87c0af48257ae5bd62ebf5",
            "Password",
        ]
        for text in negatives {
            let result = redact(text)
            #expect(result.rules.isEmpty, "false positive on: \(text)")
            #expect(result.text == text, "mutated: \(text)")
        }
    }

    @Test func handlesSeveralSecretsAndIsIdempotent() {
        let text = "a AKIAQQQQWWWWEEEERRRR b ghp_aaaabbbbccccddddeeeeffffgggghhhh1111 c"
        let once = redact(text)
        #expect(once.rules == ["aws-key", "github-token"])  // sorted, de-duplicated
        let twice = redact(once.text)
        #expect(twice.text == once.text)
        #expect(twice.rules.isEmpty)
    }

    @Test func emptyAndShortInputsAreSafe() {
        #expect(redact("") == RedactionResult(text: "", rules: []))
        #expect(redact("hi").rules.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SecretRedactorTests`
Expected: build error — `SecretRedactor` not found.

- [ ] **Step 3: Implement `Sources/Capture/SecretRedactor.swift`**

```swift
import Foundation

public struct RedactionResult: Sendable, Equatable {
    public var text: String
    /// Sorted, de-duplicated names of the rules that fired.
    public var rules: [String]

    public init(text: String, rules: [String]) {
        self.text = text
        self.rules = rules
    }
}

/// Spec 2026-09-03 privacy §5.2. Patterns adapted from gitleaks (MIT) — the corpus is vendored,
/// not the dependency, because no Swift secret-scanning library exists worth taking on. Detection
/// is best-effort by nature: it is the second line of defence behind never capturing at all.
public enum SecretRedactor {
    struct Rule {
        let name: String
        let regex: Regex<AnyRegexOutput>
    }

    /// Order matters only for readability; every rule is applied.
    nonisolated(unsafe) static let rules: [Rule] = [
        Rule(name: "private-key-block", regex: try! Regex(
            #"-----BEGIN[ A-Z]*PRIVATE KEY-----[\s\S]*?-----END[ A-Z]*PRIVATE KEY-----"#)),
        Rule(name: "aws-key", regex: try! Regex(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#)),
        Rule(name: "github-token", regex: try! Regex(
            #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,})\b"#)),
        Rule(name: "stripe-key", regex: try! Regex(#"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b"#)),
        Rule(name: "slack-token", regex: try! Regex(#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#)),
        Rule(name: "google-api-key", regex: try! Regex(#"\bAIza[0-9A-Za-z_\-]{35}\b"#)),
        Rule(name: "anthropic-key", regex: try! Regex(#"\bsk-ant-[A-Za-z0-9_\-]{20,}"#)),
        Rule(name: "openai-key", regex: try! Regex(#"\bsk-(?!ant-)[A-Za-z0-9]{32,}\b"#)),
        Rule(name: "jwt", regex: try! Regex(
            #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#)),
        Rule(name: "connection-string", regex: try! Regex(
            #"\b[a-z][a-z0-9+.\-]*://[^\s:@/]+:[^\s:@/]{6,}@"#)),
        Rule(name: "assignment-secret", regex: try! Regex(
            #"(?i)\b(?:api[_\-]?key|secret|token|password|passwd)\b\s*[:=]\s*[^\s'"]{8,}"#)),
    ]

    /// A run long enough and mixed enough to be a credential rather than prose or a path.
    nonisolated(unsafe) private static let entropyCandidate = try! Regex(
        #"[A-Za-z0-9+/=_\-]{20,}"#)
    static let entropyThreshold = 4.0

    public static func redact(_ text: String, entropyEnabled: Bool) -> RedactionResult {
        guard !text.isEmpty else { return RedactionResult(text: text, rules: []) }
        var output = text
        var fired: Set<String> = []

        for rule in rules where output.contains(rule.regex) {
            output = output.replacing(rule.regex, with: "[redacted:\(rule.name)]")
            fired.insert(rule.name)
        }

        if entropyEnabled {
            var rebuilt = ""
            var cursor = output.startIndex
            for match in output.matches(of: entropyCandidate) {
                let token = String(output[match.range])
                guard isHighEntropySecret(token) else { continue }
                rebuilt += output[cursor..<match.range.lowerBound] + "[redacted:high-entropy]"
                cursor = match.range.upperBound
                fired.insert("high-entropy")
            }
            if cursor != output.startIndex {
                rebuilt += output[cursor...]
                output = rebuilt
            }
        }

        return RedactionResult(text: output, rules: fired.sorted())
    }

    /// Mixed character classes plus high Shannon entropy. The mixed-class requirement is what
    /// keeps git SHAs (no uppercase), UUIDs, lowercase slugs and file paths out.
    static func isHighEntropySecret(_ token: String) -> Bool {
        guard token.count >= 20 else { return false }
        var hasUpper = false
        var hasLower = false
        var hasDigit = false
        for character in token {
            if character.isUppercase { hasUpper = true }
            if character.isLowercase { hasLower = true }
            if character.isNumber { hasDigit = true }
        }
        guard hasUpper, hasLower, hasDigit else { return false }
        return shannonEntropy(token) > entropyThreshold
    }

    static func shannonEntropy(_ token: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in token { counts[character, default: 0] += 1 }
        let total = Double(token.count)
        return counts.values.reduce(into: 0.0) { entropy, count in
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
    }
}
```
If the toolchain rejects `output.contains(rule.regex)`, use `output.firstMatch(of: rule.regex) != nil` — the behaviour must stay identical. The `nonisolated(unsafe)` on the immutable static regexes matches the pattern already used in `TitleNormalizer` (documented invariant: created once, never mutated, read-only matching).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SecretRedactorTests` then full `swift test`.
Expected: all 7 tests pass. If `entropyThreshold` proves too eager on a negative case, do **not** weaken a positive test to compensate — raise the threshold and re-run both directions.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/SecretRedactor.swift Tests/CaptureTests/SecretRedactorTests.swift
git commit -m "Add the secret redactor corpus and entropy backstop

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 3: `Redaction.apply` — credential-field guard and secret redaction

**Files:**
- Modify: `Sources/Capture/Redaction.swift`
- Test: `Tests/CaptureTests/RedactionTests.swift`

**Interfaces:**
- Consumes: `PrivacyPolicy.isCredentialField` (Task 1), `SecretRedactor.redact` (Task 2).
- Produces: `RedactedText` gains `public var redactedRules: [String]`; `Redaction.apply(_ element: ElementInfo?, maxValueBytes: Int, policy: PrivacyPolicy) -> RedactedText` (the policy carries `entropyRedaction`). Order: secure guard → credential-field guard → byte cap → secret redaction.

- [ ] **Step 1: Write the failing tests** (append to `RedactionTests`)

```swift
    @Test func credentialFieldByNameIsTreatedLikeASecureField() {
        let policy = PrivacyPolicy(settings: PrivacySettings())
        let element = ElementInfo(
            role: "AXTextField", identifier: "current-password", value: "hunter2",
            selectedText: "hunter2")
        let out = Redaction.apply(element, maxValueBytes: 1000, policy: policy)
        #expect(out.value == nil)
        #expect(out.selectedText == nil)
        #expect(out.redactedRules.isEmpty)
    }

    @Test func secretsInOrdinaryTextAreRedactedAndReported() {
        let policy = PrivacyPolicy(settings: PrivacySettings())
        let element = ElementInfo(
            role: "AXTextArea", value: "deploy with AKIAQQQQWWWWEEEERRRR now")
        let out = Redaction.apply(element, maxValueBytes: 1000, policy: policy)
        #expect(out.value == "deploy with [redacted:aws-key] now")
        #expect(out.redactedRules == ["aws-key"])
        #expect(out.length == "deploy with AKIAQQQQWWWWEEEERRRR now".utf8.count)
    }

    @Test func capIsAppliedBeforeRedactionSoCostIsBounded() {
        let policy = PrivacyPolicy(settings: PrivacySettings())
        let filler = String(repeating: "x", count: 40)
        let element = ElementInfo(role: "AXTextArea", value: filler + "AKIAQQQQWWWWEEEERRRR")
        let out = Redaction.apply(element, maxValueBytes: 40, policy: policy)
        #expect(out.truncated)
        #expect(out.value == filler)  // the secret was past the cap, so nothing to redact
        #expect(out.redactedRules.isEmpty)
    }

    @Test func disabledPolicySkipsRedactionButNotTheSecureGuard() {
        let element = ElementInfo(role: "AXTextArea", value: "AKIAQQQQWWWWEEEERRRR")
        let out = Redaction.apply(element, maxValueBytes: 1000, policy: .disabled)
        #expect(out.value == "AKIAQQQQWWWWEEEERRRR")
        #expect(out.redactedRules.isEmpty)

        let secure = ElementInfo(
            role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2")
        let secureOut = Redaction.apply(secure, maxValueBytes: 1000, policy: .disabled)
        #expect(secureOut.value == nil)  // unconditional, never disabled by config
    }
```
Update every pre-existing `Redaction.apply(...)` call in this file to pass `policy: .disabled`, so those tests keep asserting exactly what they asserted before (cap and secure-guard behaviour, with the new machinery out of the way).

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RedactionTests`
Expected: build error — `apply` has no `policy:` parameter.

- [ ] **Step 3: Implement**

In `RedactedText`, add `public var redactedRules: [String]` and give the memberwise `init` a trailing `redactedRules: [String] = []`. Replace `apply` with:
```swift
    public static func apply(
        _ element: ElementInfo?, maxValueBytes: Int, policy: PrivacyPolicy
    ) -> RedactedText {
        guard let element, !element.isSecure else {
            return RedactedText(value: nil, selectedText: nil, truncated: false, length: 0)
        }
        // Spec privacy §7.2: a field whose name says credential is treated exactly like a secure
        // field, so a web form that skips `type=password` cannot leak.
        guard !policy.isCredentialField(identifier: element.identifier, title: element.title) else {
            return RedactedText(value: nil, selectedText: nil, truncated: false, length: 0)
        }

        let length = element.value?.utf8.count ?? 0
        var truncated = false

        var value = element.value
        if let text = value, text.utf8.count > maxValueBytes {
            value = truncate(text, toBytes: maxValueBytes)
            truncated = true
        }

        var selectedText = element.selectedText
        if let text = selectedText, text.utf8.count > maxValueBytes {
            selectedText = truncate(text, toBytes: maxValueBytes)
            truncated = true
        }

        // Redaction runs after the cap so its cost is bounded by `max_value_bytes`.
        var rules: Set<String> = []
        if policy.enabled {
            if let text = value {
                let result = SecretRedactor.redact(text, entropyEnabled: policy.entropyRedaction)
                value = result.text
                rules.formUnion(result.rules)
            }
            if let text = selectedText {
                let result = SecretRedactor.redact(text, entropyEnabled: policy.entropyRedaction)
                selectedText = result.text
                rules.formUnion(result.rules)
            }
        }

        return RedactedText(
            value: value, selectedText: selectedText, truncated: truncated, length: length,
            redactedRules: rules.sorted())
    }
```
In `HeartbeatDiff.compute`, the one existing call becomes `Redaction.apply(element, maxValueBytes: input.maxValueBytes, policy: input.policy)` — `Input.policy` is added in Task 5; until then pass `.disabled` so this task compiles and every existing test keeps its current behaviour.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter RedactionTests` then full `swift test`.
Expected: the 4 new tests pass; all pre-existing tests unchanged.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/Redaction.swift Sources/Capture/HeartbeatDiff.swift Tests/CaptureTests/RedactionTests.swift
git commit -m "Guard credential fields by name and redact secrets in captured text

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 4: The AX layer — evaluate the policy before the content ladder

**Files:**
- Modify: `Sources/Capture/AXTypes.swift`, `Sources/Capture/AXClient.swift`, `Sources/Capture/AXClient+Inspect.swift`, `Tests/CaptureTests/FakeAXClient.swift`
- Test: `Tests/CaptureTests/ObserverTests.swift` (one new test), plus every call site updated

**Interfaces:**
- Consumes: `PrivacyPolicy`, `Protection` (Task 1).
- Produces: `FocusedContext.protection: Protection` (new stored property, defaulted `.open`, LAST init parameter); `AXReading.focusedContext(of: AppInfo, reusing: ContentCache?, policy: PrivacyPolicy) throws -> FocusedContext`; `AXClient.focusedElementInspection(of:depth:policy:) throws -> ElementInspection` where a protected context returns `ElementInspection(attributeNames: [], tree: nil, protectedBy: rule)`; `ElementInspection.protectedBy: String?`; `FakeAXClient.lastPolicy: PrivacyPolicy?` and `contentReadsForProtected` assertions.

- [ ] **Step 1: Write the failing test** (append to `ObserverTests`)

```swift
    @Test func aProtectedContextIsNeverReadForContent() async throws {
        let fake = FakeAXClient()
        fake.show(
            safari, window: WindowInfo(title: "Vault", url: "https://x.example/ui/vault/secrets"),
            element: ElementInfo(role: "AXWebArea", value: "secret list"))
        let capturer = try makeCapturer(fake: fake)
        capturer.tick()
        // The policy reached the AX layer, and the fake reports the context it returned.
        #expect(fake.lastPolicy?.enabled == true)
        let events = await drain(capturer)
        let snapshot = events.last { $0.kind == .contextSnapshot }
        #expect(snapshot?.extra?["protected"] == true)
        #expect(snapshot?.extra?["protectedBy"] == "url")
        #expect(snapshot?.value == nil)
        #expect(snapshot?.windowTitle == nil)
        #expect(snapshot?.url == nil)
    }
```
(The `HeartbeatDiff` half of this lands in Task 5; the assertion on `extra.protected` is what fails until then. Tasks 4 and 5 therefore compile and commit together — Task 4 ends with the build green and this one test red, Task 5 turns it green. Do not commit Task 4 alone.)

- [ ] **Step 2: Confirm the current call sites**

Run: `grep -rn 'focusedContext(' Sources Tests | grep -v 'func focusedContext'`
Expected: `Capturer.swift` (one call in `refresh`), `FakeAXClient.swift`, `LiveAXClientTests.swift`, `LiveContentTests.swift`, `InspectCommand.swift` (via `focusedElementInspection`). Every one must be updated in this task.

- [ ] **Step 3: Implement**

`Sources/Capture/AXTypes.swift` — extend `FocusedContext`:
```swift
public struct FocusedContext: Sendable, Equatable {
    public var app: AppInfo
    public var window: WindowInfo?
    public var element: ElementInfo?
    /// Spec privacy §5.4: `.protected` means no content was read for this context at all.
    public var protection: Protection

    public init(
        app: AppInfo, window: WindowInfo?, element: ElementInfo?, protection: Protection = .open
    ) {
        self.app = app
        self.window = window
        self.element = element
        self.protection = protection
    }
}
```
and change the protocol requirement to:
```swift
    /// Focused window and element of `app`. `reusing` is the previous heartbeat's cached
    /// cheap-identity + content. `policy` is evaluated after the cheap identity read and before
    /// the content ladder, so a protected context is never read for content (privacy §5.4).
    func focusedContext(
        of app: AppInfo, reusing cache: ContentCache?, policy: PrivacyPolicy
    ) throws -> FocusedContext
```

`Sources/Capture/AXClient.swift` — in `focusedContext`, add **exactly one** check, placed immediately after `window` is read and before the `if let focused = try self.element(...)` block that starts the focused-element read:
```swift
        if case .protected(let rule) = policy.evaluateContext(
            bundleID: app.bundleID, windowTitle: window?.title, document: window?.document,
            url: window?.url)
        {
            // Privacy §4: return before any content read — the text never enters the process.
            return FocusedContext(
                app: app, window: nil, element: nil, protection: .protected(rule: rule))
        }
```
That single placement is sufficient: the window carries the title, document and url every context rule matches on, and returning here means neither `readElement` nor `ContentExtractor` is ever reached. Do not add a second check inside the focused-element block.

`Sources/Capture/AXClient+Inspect.swift` — `ElementInspection` gains `public var protectedBy: String?` (defaulted nil in its memberwise init), and:
```swift
    public func focusedElementInspection(
        of app: AppInfo, depth: Int, policy: PrivacyPolicy
    ) throws -> ElementInspection {
        let application = AXUIElementCreateApplication(app.pid)
        var window: WindowInfo?
        if let focusedWindow = try element(application, kAXFocusedWindowAttribute) {
            window = try readWindow(focusedWindow)
        }
        if case .protected(let rule) = policy.evaluateContext(
            bundleID: app.bundleID, windowTitle: window?.title, document: window?.document,
            url: window?.url)
        {
            // Privacy §5.4: `inspect` is not a bypass. `--ignore-privacy` passes `.disabled`.
            return ElementInspection(attributeNames: [], tree: nil, protectedBy: rule)
        }
        guard let focused = try element(application, kAXFocusedUIElementAttribute) else {
            return ElementInspection(attributeNames: [], tree: nil)
        }
        var budget = 200
        let tree = try node(focused, depth: min(max(depth, 0), 3), budget: &budget)
        return ElementInspection(attributeNames: attributeNames(focused), tree: tree)
    }
```

`Tests/CaptureTests/FakeAXClient.swift` — add `private(set) var lastPolicy: PrivacyPolicy?`, change the signature to `focusedContext(of:reusing:policy:)`, record `lastPolicy = policy`, and make the fake honour the policy so tests exercise the real rule:
```swift
    func focusedContext(
        of app: AppInfo, reusing cache: ContentCache?, policy: PrivacyPolicy
    ) throws -> FocusedContext {
        focusedContextCalls += 1
        lastReusing = cache
        lastPolicy = policy
        if let error = errors[app.pid] { throw error }
        let context = contexts[app.pid] ?? FocusedContext(app: app, window: nil, element: nil)
        if case .protected(let rule) = policy.evaluateContext(
            bundleID: app.bundleID, windowTitle: context.window?.title,
            document: context.window?.document, url: context.window?.url)
        {
            return FocusedContext(
                app: app, window: nil, element: nil, protection: .protected(rule: rule))
        }
        return context
    }
```
Update `Capturer.refresh`'s call to pass `policy: privacyPolicy` (the stored property arrives in Task 6; for this task pass `PrivacyPolicy(settings: config.privacy)` inline), and update `LiveAXClientTests` / `LiveContentTests` to pass `policy: .disabled`, and `InspectCommand` to pass `policy: .disabled` (Task 9 wires the real flag).

- [ ] **Step 4: Build and run**

Run: `swift build` then `swift test`.
Expected: the build is clean and every test passes **except** the new `aProtectedContextIsNeverReadForContent`, which fails on `extra.protected` — Task 5 emits it. Do not commit yet; continue to Task 5.

---

### Task 5: `HeartbeatDiff` — protected marker rows and `extra.redacted`

**Files:**
- Modify: `Sources/Capture/HeartbeatDiff.swift`
- Test: `Tests/CaptureTests/HeartbeatDiffTests.swift`

**Interfaces:**
- Consumes: `FocusedContext.protection` (Task 4), `RedactedText.redactedRules` (Task 3).
- Produces: `HeartbeatDiff.Input.policy: PrivacyPolicy` (new **last** init parameter, default `.disabled`); a protected context emits a `context.snapshot` carrying only `pid`/`bundleID`/`appName` plus `extra.protected`, `extra.protectedBy`, `extra.reason`, `extra.fingerprint`; `ContextSignature.protectedBy: String?`.

- [ ] **Step 1: Write the failing tests** (append to `HeartbeatDiffTests`; give the `input(...)` helper a trailing `policy: PrivacyPolicy = .disabled` and a `protection: Protection = .open` that it puts on the `FocusedContext`)

```swift
    @Test func protectedContextEmitsAnAppLevelMarkerOnly() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                safari, window: WindowInfo(title: "Vault", url: "https://x/ui/vault/"),
                element: ElementInfo(role: "AXWebArea", value: "secrets"),
                protection: .protected(rule: "url")))
        let marker = out.events.last
        #expect(marker?.kind == .contextSnapshot)
        #expect(marker?.bundleID == "com.apple.Safari")
        #expect(marker?.extra?["protected"] == true)
        #expect(marker?.extra?["protectedBy"] == "url")
        #expect(marker?.windowTitle == nil)
        #expect(marker?.url == nil)
        #expect(marker?.document == nil)
        #expect(marker?.role == nil)
        #expect(marker?.value == nil)
        #expect(marker?.selectedText == nil)
        #expect(marker?.extra?["valueHash"] == nil)
    }

    @Test func protectedMarkersDedupToOnePerEntry() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, protection: .protected(rule: "bundle-id")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(safari, protection: .protected(rule: "bundle-id")))
        #expect(first.events.map(\.kind) == [.appActivated, .contextSnapshot])
        #expect(second.events.isEmpty)
    }

    @Test func leavingAProtectedContextResumesNormalCapture() {
        let protectedOut = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, protection: .protected(rule: "bundle-id")))
        let open = HeartbeatDiff.compute(
            previous: protectedOut.state,
            input: input(
                safari, window: WindowInfo(title: "Docs"),
                element: ElementInfo(role: "AXWebArea", value: "hello")))
        #expect(open.events.map(\.kind) == [.contextSnapshot])
        #expect(open.events[0].windowTitle == "Docs")
        #expect(open.events[0].value == "hello")
        #expect(open.events[0].extra?["protected"] == nil)
    }

    @Test func protectedMarkerStillCarriesAFingerprint() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, protection: .protected(rule: "bundle-id")))
        #expect(
            out.events.last?.extra?["fingerprint"]
                == .string(
                    Fingerprint.compute(
                        bundleID: "com.apple.Safari", windowTitle: nil, document: nil, url: nil)))
    }

    @Test func redactedRulesAreReportedOnOrdinaryRows() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                safari, window: WindowInfo(title: "Editor"),
                element: ElementInfo(role: "AXTextArea", value: "key AKIAQQQQWWWWEEEERRRR here"),
                policy: PrivacyPolicy(settings: PrivacySettings())))
        #expect(out.events.last?.value == "key [redacted:aws-key] here")
        #expect(out.events.last?.extra?["redacted"] == .array([.string("aws-key")]))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HeartbeatDiffTests`
Expected: build error on the helper's new parameters, then the new assertions fail.

- [ ] **Step 3: Implement**

In `ContextSignature`, add `public var protectedBy: String?` (after `pid`). In `Input`, add `public var policy: PrivacyPolicy` and the **last** init parameter `policy: PrivacyPolicy = .disabled`.

In `compute`, immediately after the `guard let app, allowed, let context = input.context else { … }` line, insert the protected branch:
```swift
        // Privacy §5.5: a protected context yields an app-level marker and nothing else. The
        // signature is (pid, protectedBy), so consecutive protected reads dedup to one row.
        if case .protected(let rule) = context.protection {
            let signature = ContextSignature(pid: app.pid, protectedBy: rule)
            if appChanged || signature != state.signature {
                events.append(
                    RawEvent(
                        ts: input.now, kind: .contextSnapshot, pid: app.pid,
                        bundleID: app.bundleID, appName: app.name,
                        extra: [
                            "reason": .string(input.trigger.reason),
                            "protected": .bool(true),
                            "protectedBy": .string(rule),
                            "fingerprint": .string(
                                Fingerprint.compute(
                                    bundleID: app.bundleID, windowTitle: nil, document: nil,
                                    url: nil)),
                        ]))
            }
            state.signature = signature
            state.lastWindowTitle = nil
            return Output(events: events, state: state)
        }
```
Change the redaction call to `Redaction.apply(element, maxValueBytes: input.maxValueBytes, policy: input.policy)`, and after the `textSource` block in the extra dictionary add:
```swift
            if !redacted.redactedRules.isEmpty {
                extra["redacted"] = .array(redacted.redactedRules.map(JSONValue.string))
            }
```
`ContextSignature`'s `protectedBy` is nil for every open context, so an open row can never dedup against a protected one.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "HeartbeatDiffTests|ObserverTests"` then full `swift test`.
Expected: the 5 new `HeartbeatDiff` tests and Task 4's `aProtectedContextIsNeverReadForContent` all pass; every pre-existing test unchanged (`Input.policy` defaults to `.disabled`).

- [ ] **Step 5: Format and commit Tasks 4 + 5 together**

```bash
make format && make lint
git add Sources/Capture Tests/CaptureTests
git commit -m "Evaluate the privacy policy before the content ladder and mark protected contexts

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 6: `Capturer` — compile the policy on load and reload

**Files:**
- Modify: `Sources/Capture/Capturer.swift`
- Test: `Tests/CaptureTests/ObserverTests.swift`

**Interfaces:**
- Consumes: `PrivacyPolicy(settings:)` (Task 1), `Input.policy` (Task 5), `focusedContext(of:reusing:policy:)` (Task 4).
- Produces: `Capturer.privacyPolicy: PrivacyPolicy` (public private(set)), recompiled in `init` and after every successful config reload, passed to both `ax.focusedContext` and `HeartbeatDiff.Input`.

- [ ] **Step 1: Write the failing test** (append to `ObserverTests`)

```swift
    @Test func policyIsRecompiledOnConfigReload() async throws {
        let fake = FakeAXClient()
        fake.show(safari, window: WindowInfo(title: "Docs"))
        let capturer = try makeCapturer(fake: fake) { $0.privacy.protectedBundleIDs = [] }
        capturer.tick()
        #expect(capturer.privacyPolicy.protectedBundleIDs.isEmpty)
        #expect(fake.lastPolicy?.protectedBundleIDs.isEmpty == true)

        var edited = capturer.config
        edited.privacy.protectedBundleIDs = ["com.apple.Safari"]
        try edited.save(to: capturer.paths.configURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: capturer.paths.configURL.path)
        capturer.tick()
        #expect(capturer.privacyPolicy.protectedBundleIDs == ["com.apple.Safari"])
        let events = await drain(capturer)
        #expect(events.last?.extra?["protectedBy"] == "bundle-id")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObserverTests`
Expected: build error — `privacyPolicy` not found.

- [ ] **Step 3: Implement**

Add the stored property after `config`:
```swift
    /// Spec privacy §5.8: compiled once per config load and handed to every read.
    public private(set) var privacyPolicy: PrivacyPolicy
```
In `init`, after `self.config = config`, add `self.privacyPolicy = PrivacyPolicy(settings: config.privacy)`. In `reloadConfigIfChanged`, after the successful `config = try Config.load(...)`, add `privacyPolicy = PrivacyPolicy(settings: config.privacy)` (before `warnAboutConfig()`). In `refresh`, pass `policy: privacyPolicy` to `ax.focusedContext` and `policy: privacyPolicy` to `HeartbeatDiff.Input`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ObserverTests` then full `swift test`.
Expected: green.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Capture/Capturer.swift Tests/CaptureTests/ObserverTests.swift
git commit -m "Compile the privacy policy on config load and pass it to every read

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 7: Store deletion, vacuum, and file permissions

**Files:**
- Modify: `Sources/Core/Paths.swift`, `Sources/Store/EventStore.swift`
- Test: `Tests/StoreTests/EventStoreTests.swift`, `Tests/CoreTests/PathsTests.swift`

**Interfaces:**
- Produces: `Paths.ensureDataDir()` creates the directory with POSIX permissions `0o700` and chmods an existing one; `EventStore.deleteEvents(ids: [Int64]) throws -> Int`, `EventStore.deleteEvents(olderThan ts: Double) throws -> Int`, `EventStore.vacuum() throws`; the database file (and any `-wal`/`-shm`) chmodded to `0o600` when opened read-write.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/StoreTests/EventStoreTests.swift`:
```swift
    @Test func deletesByIDAndByAge() async throws {
        let url = tempDBURL()
        let store = try EventStore(url: url)
        var ids: [Int64] = []
        for (index, ts) in [100.0, 200.0, 300.0].enumerated() {
            ids.append(
                try await store.append(
                    RawEvent(ts: ts, kind: .contextSnapshot, bundleID: "app\(index)")))
        }
        #expect(try await store.count() == 3)

        #expect(try await store.deleteEvents(ids: [ids[1]]) == 1)
        #expect(try await store.count() == 2)
        #expect(try await store.deleteEvents(ids: [ids[1]]) == 0)  // idempotent

        #expect(try await store.deleteEvents(olderThan: 250) == 1)  // removes ts=100
        #expect(try await store.count() == 1)
        let remaining = try await store.query(EventQuery(since: 0))
        #expect(remaining.map(\.ts) == [300])
        try await store.vacuum()
        #expect(try await store.count() == 1)
        await store.close()
    }

    @Test func databaseFileIsOwnerOnly() async throws {
        let url = tempDBURL()
        let store = try EventStore(url: url)
        _ = try await store.append(RawEvent(ts: 1, kind: .daemonStarted))
        await store.close()
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }
```
Create `Tests/CoreTests/PathsTests.swift` (or append if it exists):
```swift
import Foundation
import Testing

@testable import Core

@Suite struct PathsPermissionTests {
    @Test func dataDirIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-perm-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(dataDir: dir)
        try paths.ensureDataDir()
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.int16Value == 0o700)
    }

    @Test func anExistingLooseDirIsTightened() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orh-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        try Paths(dataDir: dir).ensureDataDir()
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
            as? NSNumber
        #expect(mode?.int16Value == 0o700)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "EventStoreTests|PathsPermissionTests"`
Expected: build errors — `deleteEvents`, `vacuum` not found; permission assertions fail.

- [ ] **Step 3: Implement**

`Sources/Core/Paths.swift`:
```swift
    /// Spec privacy §5.6: the store holds everything the user has read on screen, so the
    /// directory is owner-only. An existing looser directory is tightened on every daemon start.
    public func ensureDataDir() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: dataDir.path) {
            try manager.createDirectory(
                at: dataDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            return
        }
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: dataDir.path)
    }
```
`Sources/Store/EventStore.swift` — in the read-write branch of `init`, after `try Schema.migrate(db)`, add `Self.tighten(url)`, and add:
```swift
    /// Owner-only, including the WAL sidecars SQLite may have created.
    private static func tighten(_ url: URL) {
        let manager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"]
        where manager.fileExists(atPath: path) {
            try? manager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: path)
        }
    }

    /// Spec privacy §5.6/§5.7. Returns the number of rows removed.
    public func deleteEvents(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var removed = 0
        // Chunked so a large purge cannot exceed SQLite's variable limit.
        for chunk in stride(from: 0, to: ids.count, by: 500).map({
            Array(ids[$0..<min($0 + 500, ids.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let statement = try db.prepare("DELETE FROM events WHERE id IN (\(placeholders))")
                .bind(chunk.map { SQLValue.int($0) })
            while try statement.step() {}
            removed += db.changes()
        }
        return removed
    }

    public func deleteEvents(olderThan ts: Double) throws -> Int {
        let statement = try db.prepare("DELETE FROM events WHERE ts < ?").bind([.real(ts)])
        while try statement.step() {}
        return db.changes()
    }

    /// Reclaims free pages so deleted text does not linger in the file.
    public func vacuum() throws {
        try db.exec("VACUUM")
    }
```
`Sources/Store/Database.swift` — add `public func changes() -> Int { Int(sqlite3_changes(handle)) }` (use the existing handle property's name).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "EventStoreTests|PathsPermissionTests"` then full `swift test`.
Expected: green. If an existing test asserted the old default directory permissions, update it to `0o700` — the tightening is the point.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/Core/Paths.swift Sources/Store Tests/StoreTests Tests/CoreTests
git commit -m "Make the store owner-only and support deletion and vacuum

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 8: `openrhyme purge`

**Files:**
- Create: `Sources/openrhyme/PurgeCommand.swift`
- Modify: `Sources/openrhyme/OpenRhyme.swift`
- Test: `Tests/CLITests/PurgeCommandTests.swift`

**Interfaces:**
- Consumes: `EventStore.query/deleteEvents/vacuum` (Task 7), `PrivacyPolicy` (Task 1).
- Produces: `openrhyme purge [--since] [--until] [--app] [--url-contains] [--apply-rules] [--all] [--dry-run] [--yes] [--json]`; JSON result `{matched: Int, deleted: Int, vacuumed: Bool, dryRun: Bool}`; `PurgeCommand.select(events:app:urlContains:applyRules:policy:) -> [RawEvent]` (pure, testable without a store).

- [ ] **Step 1: Write the failing tests**

`Tests/CLITests/PurgeCommandTests.swift`:
```swift
import Core
import Testing

@testable import Capture
@testable import openrhyme

@Suite struct PurgeSelectionTests {
    private let policy = PrivacyPolicy(settings: PrivacySettings())

    private func event(
        _ id: Int64, bundle: String? = nil, url: String? = nil, document: String? = nil,
        title: String? = nil
    ) -> RawEvent {
        RawEvent(
            id: id, ts: Double(id), kind: .contextSnapshot, bundleID: bundle, windowTitle: title,
            document: document, url: url)
    }

    @Test func selectsByAppAndURLSubstring() {
        let rows = [
            event(1, bundle: "com.apple.Safari", url: "https://example.com/docs"),
            event(2, bundle: "com.google.Chrome", url: "https://vault.internal/ui/vault/list"),
            event(3, bundle: "com.google.Chrome", document: "https://vault.internal/other"),
        ]
        #expect(
            PurgeCommand.select(
                events: rows, app: "com.apple.Safari", urlContains: nil, applyRules: false,
                policy: policy
            ).map(\.id) == [1])
        // --url-contains matches the url OR the document column.
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: "vault.internal", applyRules: false,
                policy: policy
            ).map(\.id) == [2, 3])
    }

    @Test func applyRulesUsesTheRealPolicy() {
        let rows = [
            event(1, bundle: "com.apple.Safari", url: "https://example.com/docs"),
            event(2, bundle: "com.1password.1password"),
            event(3, bundle: "com.google.Chrome", url: "https://x.example/ui/vault/secrets"),
            event(4, bundle: "com.microsoft.VSCode", document: "/Users/me/app/.env"),
            event(5, bundle: "com.apple.Safari", title: "Private Browsing"),
        ]
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: nil, applyRules: true, policy: policy
            ).map(\.id) == [2, 3, 4, 5])
    }

    @Test func filtersCombineWithAnd() {
        let rows = [
            event(1, bundle: "com.google.Chrome", url: "https://vault.x/ui/vault/"),
            event(2, bundle: "com.apple.Safari", url: "https://vault.x/ui/vault/"),
        ]
        #expect(
            PurgeCommand.select(
                events: rows, app: "com.google.Chrome", urlContains: "vault.x", applyRules: false,
                policy: policy
            ).map(\.id) == [1])
    }

    @Test func noFiltersSelectsEverythingInRange() {
        let rows = [event(1, bundle: "a"), event(2, bundle: "b")]
        #expect(
            PurgeCommand.select(
                events: rows, app: nil, urlContains: nil, applyRules: false, policy: policy
            ).map(\.id) == [1, 2])
    }
}
```
Add an end-to-end CLI test in the same file using the existing `CLIRunner` harness (see `Tests/CLITests` for its shape): run `purge --since 0 --app com.apple.Safari --dry-run --json` against a temp store seeded with two rows and assert `matched == 1`, `deleted == 0`, and the store still has both rows; then run the same without `--dry-run` and without `--yes` and assert exit code 2 and no deletion; then with `--yes` and assert `deleted == 1` and the row is gone.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Purge`
Expected: build error — no `PurgeCommand`.

- [ ] **Step 3: Implement `Sources/openrhyme/PurgeCommand.swift`**

```swift
import ArgumentParser
import Capture
import Core
import Foundation
import Store

/// Spec privacy §5.7. Destructive by explicit consent only: without `--dry-run` or `--yes` it
/// reports what it would delete and exits 2.
struct PurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Delete stored events by time, app, URL, or the current privacy rules.")

    @Option(name: .long, help: "Start time: 2h, 30m, unix seconds, or ISO-8601 (default: all).")
    var since: String?
    @Option(name: .long, help: "End time (same grammar).") var until: String?
    @Option(name: .long, help: "Bundle identifier filter.") var app: String?
    @Option(name: .long, help: "Delete rows whose URL or document contains this substring.")
    var urlContains: String?
    @Flag(name: .long, help: "Delete rows the current privacy rules would protect.")
    var applyRules = false
    @Flag(name: .long, help: "Delete every stored event.") var all = false
    @Flag(name: .long, help: "Report what would be deleted and change nothing.") var dryRun = false
    @Flag(name: .long, help: "Confirm deletion (required for a real purge).") var yes = false
    @Flag(name: .long, help: "Emit a JSON envelope.") var json = false

    struct Result: Encodable {
        let matched: Int
        let deleted: Int
        let vacuumed: Bool
        let dryRun: Bool
    }

    /// Pure selection so the matching rules are testable without a store. `--apply-rules`
    /// evaluates the real `PrivacyPolicy`, so there is never a second matcher to drift.
    static func select(
        events: [RawEvent], app: String?, urlContains: String?, applyRules: Bool,
        policy: PrivacyPolicy
    ) -> [RawEvent] {
        events.filter { event in
            if let app, event.bundleID != app { return false }
            if let needle = urlContains?.lowercased() {
                let haystack = [event.url, event.document].compactMap { $0?.lowercased() }
                guard haystack.contains(where: { $0.contains(needle) }) else { return false }
            }
            if applyRules {
                guard
                    case .protected = policy.evaluateContext(
                        bundleID: event.bundleID, windowTitle: event.windowTitle,
                        document: event.document, url: event.url)
                else { return false }
            }
            return true
        }
    }

    func run() async throws {
        guard all || since != nil || app != nil || urlContains != nil || applyRules else {
            throw CLIError.usage(
                "Specify what to purge: --since/--until, --app, --url-contains, --apply-rules, or --all")
        }
        try await runJSON(json: json, human: Self.humanLines) {
            let paths = Paths.resolve()
            let config = try Config.load(from: paths.configURL)
            let policy = PrivacyPolicy(settings: config.privacy)
            let store = try EventStore(url: paths.databaseURL, readOnly: false)
            defer { Task { await store.close() } }

            let query = EventQuery(
                since: try since.map { try TimeSpec.parse($0) } ?? 0,
                until: try until.map { try TimeSpec.parse($0) },
                limit: EventQuery.maxLimit)
            let candidates = try await store.query(query)
            let selected = Self.select(
                events: candidates, app: app, urlContains: urlContains, applyRules: applyRules,
                policy: policy)

            guard !dryRun else {
                return Result(
                    matched: selected.count, deleted: 0, vacuumed: false, dryRun: true)
            }
            guard yes else {
                throw CLIError(
                    code: "confirmation_required",
                    message: "\(selected.count) rows match; deletion is permanent",
                    hint: "Re-run with --yes to delete, or --dry-run to see the selection",
                    exitCode: 2)
            }
            let deleted = try await store.deleteEvents(ids: selected.compactMap(\.id))
            try await store.vacuum()
            return Result(
                matched: selected.count, deleted: deleted, vacuumed: true, dryRun: false)
        }
    }

    static func humanLines(_ result: Result) -> String {
        result.dryRun
            ? "\(result.matched) rows would be deleted (dry run; nothing changed)"
            : "deleted \(result.deleted) of \(result.matched) matching rows; database vacuumed"
    }
}
```
Register `PurgeCommand.self` in `OpenRhyme.swift`'s `subcommands`.

**Note on `--since` and `EventQuery.maxLimit`:** a purge over a store larger than 10 000 rows in range must not silently miss rows. Page with `afterID`: loop `EventQuery(since:until:limit:.maxLimit, afterID: lastSeen)` until a page returns fewer than `maxLimit` rows, accumulating candidates. Implement that loop rather than a single query.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter Purge` then full `swift test`.
Expected: green, including the paging behaviour (seed 10 001 rows in one CLI test if practical; otherwise assert the loop with a smaller injected limit).

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme/PurgeCommand.swift Sources/openrhyme/OpenRhyme.swift Tests/CLITests/PurgeCommandTests.swift
git commit -m "Add openrhyme purge with dry-run, confirmation, and rule-based selection

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 9: `openrhyme privacy` and `inspect --ignore-privacy`

**Files:**
- Create: `Sources/openrhyme/PrivacyCommand.swift`
- Modify: `Sources/openrhyme/InspectCommand.swift`, `Sources/openrhyme/OpenRhyme.swift`
- Test: `Tests/CLITests/PrivacyCommandTests.swift`

**Interfaces:**
- Consumes: `PrivacyPolicy` (Task 1), `AXClient.focusedElementInspection(of:depth:policy:)` and `ElementInspection.protectedBy` (Task 4), `PurgeCommand.select` (Task 8).
- Produces: `openrhyme privacy [--json]` printing the policy in force, the frontmost context's verdict, and how many stored rows the current rules would protect; `openrhyme inspect --ignore-privacy`.

- [ ] **Step 1: Write the failing test**

`Tests/CLITests/PrivacyCommandTests.swift` — using the existing `CLIRunner` harness and a temp data dir with a seeded store containing one 1Password row and one ordinary row, plus a `config.json`:
```swift
    @Test func privacyJSONReportsTheRulesAndTheStoredMatchCount() async throws {
        // Seed: 1 protected-by-rule row, 1 ordinary row.
        let result = try await runCLI(["privacy", "--json"], dataDir: dir)
        #expect(result.exitCode == 0)
        let data = try #require(result.jsonData)
        #expect(data["enabled"] as? Bool == true)
        #expect((data["protectedBundleIDs"] as? [String])?.contains("com.1password.1password") == true)
        #expect(data["storedRowsMatchingRules"] as? Int == 1)
    }
```
Match the shape of the existing CLI tests in `Tests/CLITests` for the runner and JSON decoding; do not invent a new harness.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Privacy`
Expected: build error — no `PrivacyCommand`.

- [ ] **Step 3: Implement**

`Sources/openrhyme/PrivacyCommand.swift` — loads config, builds the policy, opens the store read-only, pages through every row and counts those `PurgeCommand.select(..., applyRules: true, policy:)` returns, and evaluates the frontmost app's context via `AXClient` when trusted (reporting `nil` when not). JSON result:
```swift
    struct Result: Encodable {
        let enabled: Bool
        let entropyRedaction: Bool
        let protectedBundleIDs: [String]
        let protectedURLPatterns: [String]
        let protectedDocumentPatterns: [String]
        let protectedWindowTitlePatterns: [String]
        let credentialFieldPatterns: [String]
        let frontmostApp: String?
        let frontmostVerdict: String        // "open" or the rule name
        let storedRowsMatchingRules: Int
    }
```
Human output: one line per list with its count, the frontmost verdict, and — when `storedRowsMatchingRules > 0` — the sentence `N stored rows match the current rules; remove them with: openrhyme purge --apply-rules --yes`. This is where the spec's §7.3 notice lives (see the plan header's noted refinement).

`Sources/openrhyme/InspectCommand.swift` — add `@Flag(name: .long, help: "Read even a protected context (prints a warning; never writes to the store).") var ignorePrivacy = false`, pass `policy: ignorePrivacy ? .disabled : PrivacyPolicy(settings: config.privacy)` to `focusedElementInspection`, and when `ignorePrivacy` is set write `Output.stderr("warning: --ignore-privacy bypasses the protect rules for this read")` before running. When the result has a non-nil `protectedBy`, the human output is `protected by rule '<rule>' — nothing read` and the JSON carries `protectedBy`.

Register `PrivacyCommand.self` in `OpenRhyme.swift`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "Privacy|Inspect"` then full `swift test`.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests
git commit -m "Add openrhyme privacy and make inspect honour the protect rules

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 10: Read-time redaction in `events`, and the retention sweep

**Files:**
- Modify: `Sources/openrhyme/EventsCommand.swift`, `Sources/openrhyme/DaemonCommand.swift`
- Test: `Tests/CLITests/EventsCommandTests.swift`

**Interfaces:**
- Consumes: `SecretRedactor.redact` (Task 2), `EventStore.deleteEvents(olderThan:)` (Task 7), `CaptureSettings.retentionDays` (Task 1).
- Produces: `openrhyme events --max-value-chars <n>` (default 2000, `0` = full); every returned `value`/`selected_text` passes through `SecretRedactor` when `privacy.enabled`; the daemon deletes events older than `retention_days` on start and every 24 h when `retention_days > 0`.

- [ ] **Step 1: Write the failing tests** (append to the existing CLI events tests)

```swift
    @Test func eventsRedactsSecretsAtReadTime() async throws {
        // Seed a row written before any rule existed, with a raw secret in `value`.
        try await seed(RawEvent(
            ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
            value: "token AKIAQQQQWWWWEEEERRRR end"))
        let result = try await runCLI(["events", "--since", "0", "--json"], dataDir: dir)
        let rows = try #require(result.jsonRows)
        #expect(rows[0]["value"] as? String == "token [redacted:aws-key] end")
    }

    @Test func maxValueCharsTruncatesAndZeroMeansFull() async throws {
        try await seed(RawEvent(
            ts: 100, kind: .contextSnapshot, bundleID: "com.apple.TextEdit",
            value: String(repeating: "x", count: 5000)))
        let capped = try await runCLI(
            ["events", "--since", "0", "--max-value-chars", "10", "--json"], dataDir: dir)
        #expect((try #require(capped.jsonRows)[0]["value"] as? String)?.count == 10)
        let full = try await runCLI(
            ["events", "--since", "0", "--max-value-chars", "0", "--json"], dataDir: dir)
        #expect((try #require(full.jsonRows)[0]["value"] as? String)?.count == 5000)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter EventsCommand`
Expected: unknown option `--max-value-chars`; the secret is returned verbatim.

- [ ] **Step 3: Implement**

`EventsCommand`: add `@Option(name: .long, help: "Truncate value/selected_text to this many characters (0 = full).") var maxValueChars: Int = 2000`. After fetching rows, map them through:
```swift
    /// Spec privacy §4: redaction is re-applied on the way out, so a rule added today also
    /// protects rows captured before it existed. Idempotent — an already-redacted row is
    /// unchanged.
    static func project(_ events: [RawEvent], policy: PrivacyPolicy, maxValueChars: Int)
        -> [RawEvent]
    {
        events.map { event in
            var copy = event
            if policy.enabled {
                if let value = copy.value {
                    copy.value = SecretRedactor.redact(
                        value, entropyEnabled: policy.entropyRedaction
                    ).text
                }
                if let selected = copy.selectedText {
                    copy.selectedText = SecretRedactor.redact(
                        selected, entropyEnabled: policy.entropyRedaction
                    ).text
                }
            }
            if maxValueChars > 0 {
                copy.value = copy.value.map { String($0.prefix(maxValueChars)) }
                copy.selectedText = copy.selectedText.map { String($0.prefix(maxValueChars)) }
            }
            return copy
        }
    }
```
Load the config in `run()` to build the policy (`PrivacyPolicy(settings: config.privacy)`), and apply `project` before building `Result`. `ExportCommand` gets the same projection — an export is a read path too; add one test asserting a seeded secret is redacted in the JSONL output.

`DaemonCommand`: after the store is opened and before capture starts, add
```swift
        if config.capture.retentionDays > 0 {
            let cutoff = Date().timeIntervalSince1970
                - Double(config.capture.retentionDays) * 86_400
            let removed = try await store.deleteEvents(olderThan: cutoff)
            if removed > 0 {
                logger.info("retention: removed \(removed) events older than \(config.capture.retentionDays) days")
                try await store.vacuum()
            }
        }
```
and schedule the same block every 24 h inside the existing daemon task structure (a detached `Task` that sleeps 86 400 s in a loop, cancelled in the shutdown path alongside the capturer).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter "EventsCommand|ExportCommand"` then full `swift test`.

- [ ] **Step 5: Format and commit**

```bash
make format && make lint
git add Sources/openrhyme Tests/CLITests
git commit -m "Redact on every read path and sweep events past the retention window

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 11: MCP — read events through the CLI

**Files (repo `../openrhyme-mcp`):**
- Modify: `src/openrhyme_mcp/server.py`, `src/openrhyme_mcp/store.py`
- Test: `tests/test_server.py`, delete `tests/test_store.py`'s query-path tests

**Interfaces:**
- Consumes: `openrhyme events --json` with `--since/--until/--kind/--app/--limit/--max-value-chars` (Task 10).
- Produces: the `events` tool returns `{"events": [...], "count": N}` exactly as before, sourced from `run_cli`; `store.py` keeps only what `status` still needs (delete `query_events`, `shape_row`, `COLUMNS`, and `open_readonly` if nothing else uses it).

- [ ] **Step 1: Write the failing test**

In `tests/test_server.py`, following the file's existing fake-CLI pattern:
```python
def test_events_reads_through_the_cli(monkeypatch, tmp_path):
    calls: list[list[str]] = []

    def fake_run_cli(args, *, settings, timeout=10.0):
        calls.append(list(args))
        return {"events": [{"id": 1, "kind": "context.snapshot", "value": "hi"}], "count": 1}

    monkeypatch.setattr(server, "run_cli", fake_run_cli)
    result = server.events(since="1h", app="com.apple.Safari", limit=50, max_value_chars=100)

    assert result == {"events": [{"id": 1, "kind": "context.snapshot", "value": "hi"}], "count": 1}
    assert calls[0][0] == "events"
    assert "--since" in calls[0] and "1h" in calls[0]
    assert "--app" in calls[0] and "com.apple.Safari" in calls[0]
    assert "--limit" in calls[0] and "50" in calls[0]
    assert "--max-value-chars" in calls[0] and "100" in calls[0]


def test_events_passes_each_kind_as_its_own_flag(monkeypatch):
    calls: list[list[str]] = []
    monkeypatch.setattr(
        server, "run_cli",
        lambda args, *, settings, timeout=10.0: (calls.append(list(args)), {"events": [], "count": 0})[1],
    )
    server.events(since="1h", kinds=["window.focused", "app.activated"])
    assert calls[0].count("--kind") == 2
    assert "window.focused" in calls[0] and "app.activated" in calls[0]


def test_events_no_longer_opens_the_database(monkeypatch):
    def explode(*args, **kwargs):
        raise AssertionError("events must not open SQLite directly")

    monkeypatch.setattr(server, "open_readonly", explode, raising=False)
    monkeypatch.setattr(
        server, "run_cli", lambda args, *, settings, timeout=10.0: {"events": [], "count": 0})
    assert server.events(since="1h") == {"events": [], "count": 0}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ../openrhyme-mcp && uv run pytest -q`
Expected: the new tests fail — `events` still opens SQLite.

- [ ] **Step 3: Implement**

Rewrite the body of `events` to build the argument list and delegate:
```python
    settings = resolve()
    args: list[str] = ["events", "--since", since]
    if until is not None:
        args += ["--until", until]
    for kind in kinds or []:
        args += ["--kind", kind]
    if app is not None:
        args += ["--app", app]
    args += ["--limit", str(limit), "--max-value-chars", str(max_value_chars)]
    data = run_cli(args, settings=settings)
    return {"events": data.get("events", []), "count": data.get("count", 0)}
```
Keep `_parse_time` validation of `since`/`until` **before** shelling out so a bad time still fails fast with the same `ToolError` as today. Update the docstring's last line to: `value`/`selected_text` are redacted by the engine and cut to `max_value_chars` (0 = full text). Delete `query_events`, `shape_row`, `COLUMNS` and `_truncate` from `store.py` plus their tests; keep `open_readonly`/`schema_version` only if `status` still uses them — if not, delete those too and drop the now-unused import.

- [ ] **Step 4: Run to verify it passes**

Run: `cd ../openrhyme-mcp && make check` (ruff + mypy + pytest).
Expected: green, with the deleted code's tests removed rather than skipped.

- [ ] **Step 5: Commit (in the MCP repo)**

```bash
cd ../openrhyme-mcp
git add -A
git commit -m "Read events through the engine CLI so redaction is never bypassed

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

---

### Task 12: Docs and final verification

**Files:**
- Modify: `README.md`, `SECURITY.md`, `docs/accessibility-api.md`, `CLAUDE.md`

- [ ] **Step 1: Update the docs**

- `SECURITY.md`, under "Guarantees this project intends to keep", add: sensitive contexts (password-manager apps, vault and credential URLs, `.env` and key files, credential-named fields) are never read — not read and discarded; recognised secret shapes are redacted from what is captured and again on every read; the data directory is `0700` and the database `0600`; the MCP has no independent database access. Then add a **Limits** subsection stating plainly: pattern detection is best-effort and will miss custom secret formats; **Chrome Incognito is not detectable through the Accessibility API** (Safari private windows are); file permissions do not stop another process running as you; and a backup the user makes is their responsibility.
- `README.md`: a **Privacy** section with the `privacy` config block (add/remove semantics), the `capture.retention_days` key, `openrhyme privacy`, `openrhyme purge` (including `--dry-run` and that `--yes` is required), and the same limits in two sentences.
- `docs/accessibility-api.md` §6.2: a short "Privacy (as shipped)" paragraph — the policy is evaluated inside `focusedContext` between the identity read and the content ladder so a protected context is never read; protected rows carry `extra.protected`/`protectedBy` and app fields only; `Redaction.apply` runs the secret corpus after the byte cap and reports `extra.redacted`; `events`/`export` re-apply it at read time.
- `CLAUDE.md` State line: append "Privacy controls (never-capture rules, secret redaction, purge/retention, owner-only store, MCP reads through the CLI) landed on top."

- [ ] **Step 2: Full verification, both repos**

```bash
make build && make test && make lint
cd ../openrhyme-mcp && make check
```
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add README.md SECURITY.md docs/accessibility-api.md CLAUDE.md
git commit -m "Document the privacy controls and their limits

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016CZ7A8EbQLY5eqaMWnXRq2"
```

- [ ] **Step 4: Dogfood (the user, after merge)**

Rebuild release, restart the daemon, then: open a `.env` in an allowlisted editor and confirm `openrhyme events --since 2m` shows a row with `extra.protected` and no text; visit a vault URL and confirm the same; run `openrhyme privacy` to see the policy and the stored-match count; run `openrhyme purge --apply-rules --dry-run` to see what the rules would remove from history.

---

## Self-review (against the spec)

| Spec section | Task |
|---|---|
| §4 two enforcement points; read-time re-redaction | 4 (policy before the ladder), 3 (chokepoint), 10 (read path) |
| §5.1 `PrivacyPolicy`, defaults, matching semantics | 1 |
| §5.2 `SecretRedactor` corpus + entropy | 2 |
| §5.3 `Redaction.apply` order and `redactedRules` | 3 |
| §5.4 AX layer, `inspect` honours the policy | 4, 9 |
| §5.5 protected marker rows | 5 |
| §5.6 `0700`/`0600`, delete, vacuum | 7 |
| §5.7 `purge`, `privacy`, `events --max-value-chars` | 8, 9, 10 |
| §5.8 policy on load/reload; retention sweep | 6 (policy), 10 (sweep — in the daemon, not `Capturer`) |
| §5.9 MCP reads through the CLI | 11 |
| §6 config block | 1 |
| §7.1–7.2 protected context, credential field | 4/5, 3 |
| §7.3 retroactive scrub, explicit only | 8 (`--apply-rules`), 9 (the on-demand notice) |
| §8 privacy properties and stated limits | 12 |
| §9 tests | 1–11 |

**Placeholder scan:** none. **Type consistency:** `Protection` / `PrivacyPolicy(settings:)` / `.disabled` (Task 1) are used with those exact names in Tasks 3–10; `RedactedText.redactedRules` (Task 3) is read in Task 5; `FocusedContext.protection` and `focusedContext(of:reusing:policy:)` (Task 4) match every call site listed in Task 4 Step 2 and the fake; `HeartbeatDiff.Input.policy` is the **last** init parameter, after `contentMemorySeconds`; `EventStore.deleteEvents(ids:)` / `deleteEvents(olderThan:)` / `vacuum()` (Task 7) are called in Tasks 8 and 10; `PurgeCommand.select(events:app:urlContains:applyRules:policy:)` (Task 8) is reused by Task 9's stored-match count; the MCP's `events` output shape is byte-identical to today's.

**Deviations from the spec, both deliberate and noted in the plan header:** the retention sweep and the "stored rows match new rules" notice live in the daemon and in `openrhyme privacy` rather than in `Capturer`, because `Capture` must never import `Store`. **Tasks 4 and 5 commit together** — Task 4 leaves one test intentionally red, exactly as the observers slice's AX-glue pair did.
