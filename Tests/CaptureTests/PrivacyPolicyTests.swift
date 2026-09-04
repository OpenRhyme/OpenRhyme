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
            "/Users/me/env-setup-guide.txt",
        ] {
            #expect(
                policy.evaluateContext(
                    bundleID: "com.microsoft.VSCode", windowTitle: "editor", document: path,
                    url: nil) == .open, "\(path)")
        }
    }

    @Test func protectsCredentialAndSecretFilesWithAffixes() {
        for path in [
            "/Users/me/app/aws-credentials.json", "/Users/me/db-credentials.json",
            "/Users/me/app/prod-secrets-2024.yaml", "/Users/me/app/secrets.yaml",
            "/Users/me/.aws/credentials", "/Users/me/src/Secrets.swift.md",
        ] {
            #expect(
                policy.evaluateContext(
                    bundleID: "com.microsoft.VSCode", windowTitle: "editor", document: path,
                    url: nil) == .protected(rule: "document"), "\(path)")
        }
    }

    @Test func documentMatchingIsCaseInsensitive() {
        for path in ["/Users/me/proj/.ENV", "/Users/me/app/Secrets.YAML", "/Users/me/K.PEM"] {
            #expect(
                policy.evaluateContext(
                    bundleID: "com.microsoft.VSCode", windowTitle: "editor", document: path,
                    url: nil) == .protected(rule: "document"), "\(path)")
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

    // MARK: - protectionForWindowlessContext (privacy fix round 2, G1)
    //
    // Shared by `AXClient.focusedContext` and `AXClient.focusedElementInspection` so the two can
    // never diverge on this rule again — pinning it once here covers both call sites structurally.

    @Test func windowlessContextIsProtectedWhenEnabledWithNonEmptyRules() {
        #expect(policy.protectionForWindowlessContext() == .protected(rule: "unverifiable-context"))
    }

    @Test func windowlessContextFailsOpenWhenPolicyIsDisabled() {
        #expect(PrivacyPolicy.disabled.protectionForWindowlessContext() == nil)
    }

    @Test func windowlessContextIsOpenWhenNoRulesCouldEverApply() {
        var settings = PrivacySettings()
        settings.protectedURLPatterns = []
        settings.protectedDocumentPatterns = []
        settings.protectedWindowTitlePatterns = []
        // Bundle-id rules don't need a window to evaluate, so they don't factor into this guard.
        #expect(PrivacyPolicy(settings: settings).protectionForWindowlessContext() == nil)
    }

    // MARK: - I6 (whole-branch review): the configured rules and the windowless guard are one
    // verdict, evaluated in one place. `AXClient.focusedContext` and
    // `AXClient.focusedElementInspection` had hand-copied the pair; only the windowless half had
    // been factored out, which is how they diverged in the first place.

    @Test func focusedContextVerdictAppliesTheConfiguredRulesFirst() {
        #expect(
            policy.evaluateFocusedContext(
                bundleID: "com.1password.1password", window: WindowInfo(title: "Vault"))
                == .protected(rule: "bundle-id"))
        #expect(
            policy.evaluateFocusedContext(
                bundleID: "com.google.Chrome",
                window: WindowInfo(url: "https://bao.example.net/ui/vault/secrets/list"))
                == .protected(rule: "url"))
    }

    @Test func focusedContextVerdictFallsBackToTheWindowlessGuard() {
        #expect(
            policy.evaluateFocusedContext(bundleID: "com.apple.TextEdit", window: nil)
                == .protected(rule: "unverifiable-context"))
        #expect(
            PrivacyPolicy.disabled.evaluateFocusedContext(
                bundleID: "com.apple.TextEdit", window: nil) == .open)
    }

    @Test func focusedContextVerdictIsOpenForAnOrdinaryWindow() {
        #expect(
            policy.evaluateFocusedContext(
                bundleID: "com.apple.TextEdit",
                window: WindowInfo(title: "notes", document: "/tmp/notes.md")) == .open)
    }
}
