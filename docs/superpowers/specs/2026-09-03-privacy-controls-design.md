# Privacy controls — never-capture rules, secret redaction, purge, and a redacted read path

**Status:** approved design, 2026-09-03. Fourth post-MVP slice (after content extraction, observers, noise reduction).
**Scope:** the Swift engine (`Capture`, `Core`, `Store`, CLI) **and** the Python MCP server (`OpenRhyme/openrhyme-mcp`). **No SQLite schema change (stays v1).** The `openrhyme … --json` envelope gains fields but breaks nothing; the MCP's `events` tool changes its data source, not its output shape.
**Builds on:** MVP spec §6.5 (redaction, the secure-field rule), the content-extraction spec (the two-phase read this hooks into), the noise-reduction spec (`Redaction.apply` as the single content chokepoint).

## 1. Problem

The engine's promise is that it can read almost everything on screen and never sends it anywhere. Local-only is necessary but not sufficient: the store itself is now a high-value target, and today it protects exactly one thing.

Verified on the live store, 2026-09-03:
- **`AXSecureTextField` is genuinely safe** — 9 such rows, 0 with any text. Three independent guards hold.
- **Everything else is not.** A secret that is *text* rather than a password field is captured verbatim. A `.env` open in an allowlisted editor is an `AXTextArea`; a token pasted into a terminal is text; a secrets-manager web UI is a page like any other.
- **This already happened.** A Vault/OpenBao UI (`…/ui/vault/secrets/fleet/list`, 857 chars) and a Tailscale credentials settings page (15 rows, up to 797 chars) were harvested and stored. No secret *values* were present — a scan for AWS/GitHub/Stripe/Slack/PEM/JWT shapes and high-entropy tokens found zero — but the structure of a secrets manager was on disk.
- **The user could not remove it.** There is no purge command; the cleanup required raw `sqlite3` plus a `VACUUM` to clear free-page residue.
- **The store is world-readable** (`0755` dir, `0644` DB) on a multi-user Mac.
- **Agents read raw rows.** The MCP serves stored text verbatim, with `max_value_chars=0` returning everything.

**Goal:** make the sensitive classes never reach the store, redact the secrets that slip through, let the user delete what is already there, and ensure nothing leaves through the MCP unredacted — without weakening any existing SECURITY.md guarantee.

## 2. Non-goals

- **No bundled model.** PII/NER detection (Presidio-style) is out: `Compact`/engine must stay inference-free. Detection is regex plus entropy only.
- **No network.** Nothing verifies a candidate secret by calling an API (truffleHog-style). The engine has no network code, ever.
- **No automatic destructive action.** Editing a config rule never deletes history by itself; the retroactive scrub is an explicit command (§7.3). Silently deleting a user's timeline because they typed a rule is a worse failure than the leak it fixes.
- **No encryption at rest** in this slice. SQLCipher is a later decision; note honestly that it protects a stolen disk, not a same-user process, which is the likelier threat here.
- **No per-category capture toggles** (email/messaging/URL-vs-domain, OpenHistory-style). This slice is about *sensitive* content, not about narrowing normal capture. A later slice can add categories.
- **No schema v2**, no new `EventKind`, no compaction.

## 3. Success criteria

1. With the default rules, focusing a password-manager app, a vault URL, or an editor whose document matches a sensitive filename produces **no window title, no URL, no text** — only a marker row naming the app and the rule.
2. For a protected context, the daemon performs **no content read at all**: the AX content ladder never runs, so the text never enters the process (assert via the fake's read counters and the live gated test).
3. A focused element whose identifier or title looks like a credential field (`password`, `token`, `api_key`, `private key`, …) is treated exactly like `AXSecureTextField`: role-only row, no value — even when the app does not mark it secure.
4. Text containing a recognised secret shape (AWS key, GitHub/Stripe/Slack token, Google API key, PEM private-key block, JWT, `key=value` secret, connection-string password) is stored with the match replaced by `[redacted:<rule>]`; `extra.redacted` lists the rule names that fired.
5. A high-entropy token (≥20 chars, Shannon entropy > 4.0, mixed classes) with no matching rule is redacted as `[redacted:high-entropy]`.
6. `openrhyme purge` deletes by time range, app, URL substring, or all; `--dry-run` reports counts without deleting; deletion requires explicit confirmation, runs `VACUUM`, and reports rows removed. `openrhyme purge --apply-rules` deletes historical rows that the *current* protect rules would have blocked.
7. `retention_days` (default `0` = keep forever) sweeps older events on daemon start and once a day.
8. The data directory is `0700` and the database `0600`, corrected on every daemon start.
9. The MCP's `events` tool returns rows that went through the engine's read-time redaction, and the MCP no longer opens SQLite directly. Its output shape (`{events, count}`) is unchanged.
10. `openrhyme privacy` prints the rules in force and what they would do to the current frontmost context, so the user can see the policy rather than trust it.
11. `openrhyme inspect` against a protected context prints the protecting rule and no content; `--ignore-privacy` is required to override and warns first.
12. Every existing SECURITY.md guarantee still holds; secure fields still yield their role-only row. `make build && make test && make lint` green in both repos; CI green.

## 4. Architecture

Two enforcement points, deliberately asymmetric in strength.

```
  ┌── context policy (never capture) ─ evaluated INSIDE focusedContext,
  │   after the cheap identity read, BEFORE the content ladder
  │        ↓ protected?  yes → no content read at all → marker row
  │                      no  ↓
  │   content ladder (value → range → subtree harvest)
  │        ↓
  └── content redaction ─ Redaction.apply, the single chokepoint every
      captured value already passes → secret shapes replaced

  store (0600, in a 0700 dir)
        ↓  openrhyme events --json  ← read-time redaction re-applied
  MCP events tool (no direct SQLite)  → agent
```

**Why the context check lives inside `focusedContext`.** The content-extraction slice already made that read two-phase: a cheap identity read, then the expensive rungs. Slotting the policy between them means a protected context's text is never read into the daemon's memory — not read-then-discarded. That is the only guarantee worth the name; everything downstream is defence in depth.

**Why redaction is re-applied at read time.** Rules improve. Rows captured before a rule existed would otherwise leak forever. Applying the same redactor in `openrhyme events` costs microseconds per row and means a rule added today protects data captured last week. It also makes the MCP's projection automatic (§8).

## 5. Components

### 5.1 `PrivacyPolicy` (new, `Sources/Capture/PrivacyPolicy.swift`, pure)
A `Sendable` value compiled from config once per reload.

```swift
public enum Protection: Sendable, Equatable {
    case open
    case protected(rule: String)   // e.g. "password-manager-app", "sensitive-document"
}

public struct PrivacyPolicy: Sendable, Equatable {
    public var protectedBundleIDs: Set<String>
    public var protectedURLPatterns: [String]        // substring, case-insensitive
    public var protectedDocumentPatterns: [String]   // glob-ish, matched on the last path component and the full path
    public var protectedWindowTitlePatterns: [String]
    public var credentialFieldPatterns: [String]     // matched against element identifier/title

    public func evaluateContext(
        bundleID: String?, windowTitle: String?, document: String?, url: String?
    ) -> Protection

    public func isCredentialField(identifier: String?, title: String?) -> Bool
}
```
Matching is deliberately dumb and auditable: lowercase substring for URLs and titles, `fnmatch`-style globs for documents, exact set membership for bundle ids, and case-insensitive substring for field names. No regex in the *context* rules — a mis-written regex that silently matches nothing is a privacy failure; a substring cannot.

**Defaults (protective, per the approved posture)** — every list is user-extensible and user-removable:
- `protectedBundleIDs`: `com.1password.1password`, `com.1password.7`, `com.agilebits.onepassword7`, `com.bitwarden.desktop`, `com.lastpass.LastPass`, `in.sinew.Enpass-Desktop`, `com.dashlane.Dashlane`, `com.apple.keychainaccess`.
- `protectedURLPatterns`: `1password.com`, `bitwarden.com`, `lastpass.com`, `dashlane.com`, `/ui/vault/`, `vault.`, `/settings/credentials`, `/trust-credentials`, `/admin/credentials`, `console.cloud.google.com/iam-admin/serviceaccounts`, `/apikeys`.
- `protectedDocumentPatterns`: `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.keystore`, `id_rsa*`, `id_ed25519*`, `id_ecdsa*`, `credentials`, `credentials.*`, `secrets.*`, `.npmrc`, `.netrc`, `.pgpass`, `*/.aws/*`, `*/.ssh/*`, `*/.gnupg/*`.
- `protectedWindowTitlePatterns`: `private browsing` (Safari's private windows carry it).
- `credentialFieldPatterns`: `password`, `passwd`, `current-password`, `new-password`, `secret`, `token`, `api key`, `api_key`, `apikey`, `private key`, `passphrase`, `otp`, `2fa`, `mfa code`.

**Honest limit, documented in the spec and the README:** **Chrome Incognito is not reliably detectable through the Accessibility API** — incognito windows expose no distinguishing title or attribute we can depend on. Safari private windows are caught by the title rule. Users who need Chrome-incognito exclusion should rely on allowlist discipline instead. Claiming otherwise would be the kind of promise that erodes trust when it fails.

### 5.2 `SecretRedactor` (new, `Sources/Capture/SecretRedactor.swift`, pure)
```swift
public struct RedactionResult: Sendable, Equatable {
    public var text: String
    public var rules: [String]   // sorted, de-duplicated names of rules that fired
}

public enum SecretRedactor {
    public static func redact(_ text: String, entropyEnabled: Bool) -> RedactionResult
}
```
Rule corpus adapted from **gitleaks** (MIT) — we vendor the *patterns*, not a dependency, since no Swift secret-scanning library exists worth taking on. Each rule is `(name, Regex, replacement)`; a match becomes `[redacted:<name>]`.

Structural rules: `aws-key` (`AKIA`/`ASIA` + 16), `github-token` (`gh[pousr]_` + 36, `github_pat_`), `stripe-key` (`sk_live_`/`sk_test_`), `slack-token` (`xox[baprs]-`), `google-api-key` (`AIza` + 35), `openai-key` (`sk-` + 32+), `anthropic-key` (`sk-ant-`), `private-key-block` (`-----BEGIN … PRIVATE KEY-----` through `-----END`), `jwt` (three base64url segments), `connection-string` (`scheme://user:pass@host`), `assignment-secret` (`(api[_-]?key|secret|token|password)\s*[:=]\s*` + 8+ non-space).

Entropy backstop (`entropyEnabled`, default true): a candidate token of ≥20 characters from `[A-Za-z0-9+/=_-]`, containing at least one uppercase, one lowercase and one digit, whose Shannon entropy exceeds 4.0 bits/char, becomes `[redacted:high-entropy]`. Words from a small denylist of common long identifiers (base64-looking UUIDs are *not* excluded; ordinary English words never reach 4.0) are unaffected in practice; the tests pin real-world negatives (long URLs, file paths, sentences, base64 images are truncated by the byte cap before reaching here).

Redaction runs **after** the existing byte cap so cost is bounded by `max_value_bytes`.

### 5.3 `Redaction.apply` (extended, `Sources/Capture/Redaction.swift`)
Signature becomes `apply(_ element: ElementInfo?, maxValueBytes: Int, policy: PrivacyPolicy, entropyEnabled: Bool) -> RedactedText`, and `RedactedText` gains `redactedRules: [String]`. Order: secure-field guard (unchanged) → **credential-field guard** (§5.1, same outcome as secure) → byte cap → secret redaction. The single existing call site in `HeartbeatDiff` is the only caller.

### 5.4 AX layer (`AXReading`, `AXClient`)
`focusedContext(of:reusing:policy:)` gains the policy. After the cheap identity read and before the content ladder:
```
if case .protected(let rule) = policy.evaluateContext(bundleID:windowTitle:document:url:) {
    return FocusedContext(app: app, window: nil, element: nil, protection: .protected(rule: rule))
}
```
`FocusedContext` gains `protection: Protection` (default `.open`). Nothing else in the AX layer changes; `inspect` respects the policy by default: run against a protected context it prints the rule that protected it and nothing else. `openrhyme inspect --ignore-privacy` overrides this for debugging, prints a warning to stderr first, and never writes to the store. An unconditional exemption would have made `inspect` a bypass of the guarantee this slice exists to make.

### 5.5 `HeartbeatDiff`
When `context.protection` is `.protected(rule)`, emit a marker: kind `context.snapshot`, carrying `pid`/`bundleID`/`appName` only, with `extra.protected = true`, `extra.protectedBy = rule`, and `extra.reason` as usual. No `windowTitle`, `document`, `url`, `role`, `subrole`, `identifier`, `elementTitle`, `value`, `selectedText`, or `valueHash`. It does carry `extra.fingerprint`, computed over `bundleID ␟ "" ␟ "" ␟ ""` — preserving the noise-reduction spec's invariant that every focused-context event is fingerprinted, leaking nothing beyond the bundle id already in the row, and giving Compact a single stable key for all protected time in that app. The signature for a protected context is `(pid, protected, rule)`, so consecutive protected snapshots dedup to one marker per entry. When a non-protected event carries redactions, `extra.redacted` lists the rule names.

### 5.6 Store and paths
`Paths.ensureDataDir()` creates the directory `0700` and chmods an existing one; `EventStore` chmods the database (and its `-wal`/`-shm`) to `0600` on open. `EventStore` gains `deleteEvents(matching:) -> Int` and `vacuum()`.

### 5.7 CLI
- **`openrhyme purge`** — `--since`/`--until` (the existing time grammar), `--app <bundle-id>`, `--url-contains <substring>`, `--apply-rules`, `--all`, `--dry-run`, `--yes`, `--json`. Without `--dry-run` or `--yes` it prints what would be deleted and refuses, exit 2 — destructive by explicit consent only. After deleting it runs `VACUUM` and reports `{deleted, vacuumed: true}`. `--apply-rules` deletes rows whose stored `bundle_id`/`window_title`/`document`/`url` the *current* policy would protect.
- **`openrhyme privacy`** — prints the rules in force (counts per list, plus the full lists with `--json`) and evaluates the current frontmost context, showing `open` or the rule that would protect it. The "see the policy, don't trust it" surface.
- **`openrhyme events`** — re-applies `SecretRedactor` to `value`/`selected_text` at read time and adds `--max-value-chars` (moved from the MCP, default 2000, `0` = full). Rows already stored redacted are unaffected (idempotent).

### 5.8 Daemon
Loads the policy from config on start and on every reload; sweeps `retention_days` on start and every 24h; fixes permissions on start; emits `daemon.started` with `extra.privacy = {protectedRules: <n>, retentionDays: <n>}` so the log records the posture in force.

### 5.9 MCP (`openrhyme-mcp`)
`events` stops opening SQLite and calls `run_cli(["events", …])`, mapping its arguments onto the CLI flags and returning `{events, count}` exactly as today. `store.py`'s `query_events`/`shape_row`/`open_readonly` and their tests are deleted; the schema handshake moves to the engine (which already refuses a too-new store). `status` and `apps` are unchanged. The tool docstring gains one line: values are redacted by the engine.

## 6. Config

New `privacy` block, all optional; defaults are the protective lists in §5.1. Every list supports `add`/`remove` semantics via two keys so a user can extend the defaults without restating them, and can also disable a default:
```json
"privacy": {
  "enabled": true,
  "entropy_redaction": true,
  "protected_bundle_ids": { "add": ["com.example.Vault"], "remove": [] },
  "protected_url_patterns": { "add": ["internal-vault.corp"], "remove": [] },
  "protected_document_patterns": { "add": ["*.secret"], "remove": [] },
  "protected_window_title_patterns": { "add": [], "remove": [] },
  "credential_field_patterns": { "add": [], "remove": [] }
},
"capture": { "retention_days": 0 }
```
`enabled: false` disables context protection and redaction wholesale (the escape hatch for a user who wants today's behaviour); the secure-field guard is **not** affected by it and can never be disabled. `retention_days: 0` means keep forever.

## 7. Behaviour

### 7.1 Protected context
Frontmost app is allowlisted and its context matches a protect rule → no content read, one marker row on entry, subsequent heartbeats dedup to nothing, and leaving the context produces the usual `app.deactivated`. The user sees "you were in 1Password for 4 minutes" and nothing else.

### 7.2 Credential field
A focused element whose identifier/title matches `credentialFieldPatterns` → same treatment as `AXSecureTextField`: the row is emitted with role/subrole (so the timeline shows a credential field was used) and no value or selected text.

### 7.3 Retroactive scrub
`openrhyme purge --apply-rules --dry-run` reports how many stored rows the current rules would protect, grouped by rule. Adding `--yes` deletes them and vacuums. Never automatic, never triggered by a config edit — the daemon logs "N stored rows match new protect rules; run `openrhyme purge --apply-rules`" once after a reload that adds rules, and does nothing else.

### 7.4 Failure modes
An unparseable pattern is dropped at load with a warning naming it (never silently); a policy that ends up empty because everything was removed logs a warning at daemon start; `purge` on a locked database retries briefly then exits non-zero with a clear message rather than partially deleting.

## 8. Privacy properties this slice establishes

- Sensitive contexts are **never read**, not read-and-dropped (§4).
- Secrets that reach the store are redacted at write time **and** re-redacted at read time, so a rule added later protects data captured earlier.
- The store is unreadable by other users on the machine (§5.6).
- No agent path bypasses redaction: the MCP has no independent database access after this slice (§5.9).
- The user can inspect the policy (`openrhyme privacy`) and delete anything (`openrhyme purge`) without a shell or SQL.
- **Stated limits, in the README and SECURITY.md:** pattern-based detection is best-effort and will miss custom secret formats; Chrome Incognito is not detectable; a backup file the user creates is their responsibility; and any process running as the user can read the store regardless of file permissions.

## 9. Testing

- `PrivacyPolicyTests`: each default list matches its intended cases and, importantly, its intended *non*-cases (`environment.md` is not `.env`; `mykey.pem` matches, `keynote.app` does not; `vault.` matches `vault.corp.com` but not `evault.com` — anchored appropriately); `add`/`remove` config semantics; empty policy protects nothing.
- `SecretRedactorTests`: one positive and one negative per structural rule using **synthetic, non-functional** keys; entropy positives (a real-shaped random token) and negatives (long URLs, file paths, an English sentence, a hex colour list, a UUID); multiple rules in one string; `rules` de-duplicated and sorted; idempotence (redacting twice changes nothing).
- `RedactionTests`: secure guard unchanged; credential-field guard; order (cap then redact); `redactedRules` surfaced.
- `HeartbeatDiffTests`: protected marker carries only app fields plus `protected`/`protectedBy`; consecutive protected snapshots dedup to one; leaving a protected context resumes normal capture; `extra.redacted` present when a rule fired.
- `CapturerTests`/fake: a protected context performs **zero** `focusedContext` content reads (the fake asserts the policy was passed and no content requested).
- `StoreTests`: `deleteEvents(matching:)` by each criterion, `vacuum()`, permissions on create.
- `CLITests`: `purge --dry-run` deletes nothing and reports counts; without `--yes` refuses (exit 2); `--apply-rules` selects exactly the rows the policy protects; `privacy --json` shape; `events` redacts at read time.
- MCP: `events` returns the CLI's rows (fake CLI in tests), same `{events, count}` shape; the direct-SQLite tests are deleted with their code.
- Live (gated `OPENRHYME_LIVE_AX=1`): open a `.env` in an allowlisted editor and confirm a marker row with no text; confirm `openrhyme privacy` reports the rule for the current context.

## 10. Modules touched

| File | Change |
|---|---|
| `Sources/Capture/PrivacyPolicy.swift` | **New.** §5.1. |
| `Sources/Capture/SecretRedactor.swift` | **New.** §5.2. |
| `Sources/Capture/Redaction.swift` | Credential guard, secret redaction, `redactedRules`. |
| `Sources/Capture/AXTypes.swift` | `Protection`; `FocusedContext.protection`; `AXReading.focusedContext(of:reusing:policy:)`. |
| `Sources/Capture/AXClient.swift`, `AXClient+Inspect.swift` | Policy check before the ladder; `inspect` honours it unless `--ignore-privacy`. |
| `Sources/Capture/HeartbeatDiff.swift` | Protected marker; `extra.redacted`. |
| `Sources/Capture/Capturer.swift` | Compile the policy on load/reload; retention sweep; the "rows match new rules" notice. |
| `Sources/Core/Config.swift`, `Paths.swift` | §6 keys; `0700` data dir. |
| `Sources/Store/EventStore.swift` | `deleteEvents(matching:)`, `vacuum()`, `0600`. |
| `Sources/openrhyme/PurgeCommand.swift`, `PrivacyCommand.swift` | **New.** §5.7. |
| `Sources/openrhyme/EventsCommand.swift` | Read-time redaction, `--max-value-chars`. |
| `Tests/**` | §9. |
| `openrhyme-mcp/src/openrhyme_mcp/{server,store}.py`, its tests | §5.9. |
| `README.md`, `SECURITY.md`, `docs/accessibility-api.md`, `CLAUDE.md` | The rules, the config, and the stated limits. |

## 11. Deferred, on purpose

Encryption at rest (SQLCipher); per-category capture toggles (email/messaging/URL-vs-domain); a `status` field for the privacy posture; automatic scrub on rule change; Chrome-incognito detection (blocked on AX, revisit if Chromium exposes a signal); Compact and the summary tool, which must consume the redacted projection when they land.
