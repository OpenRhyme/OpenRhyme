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
