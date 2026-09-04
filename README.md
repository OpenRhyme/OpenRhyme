# OpenRhyme

An open-source, local-first **computer history layer for macOS** — a daemon that turns what you do on your Mac into a private, searchable timeline that *any* AI agent can read.

> **Status:** Part 1 of the MVP is implemented on this branch — the capture daemon and the `openrhyme` CLI, against the settled design ([spec](docs/computer-history-spec.md)). The MCP server and the WARM/COLD storage tiers are still ahead.

## Why

OpenAI shipped *Computer History* in the ChatGPT macOS app (August 2026): an opt-in activity stream built on the macOS accessibility API that lets ChatGPT/Codex resume prior work, find recent output, and turn repeated actions into automations. It feeds one vendor's assistant and lives inside their app.

OpenRhyme is the same capability with the ownership flipped:

- **Local-first.** Everything stays on disk, in SQLite, under your home directory. No hosted tier, ever — that decision is settled in the spec (§7).
- **Vendor-independent.** The timeline is exposed over MCP so Claude, local models, or your own scripts can consume it.
- **Accessibility-based, not screenshots.** Window/document context, on-screen text from the AX tree, and aggregated input activity. No screenshots, no microphone, no system audio, no raw key logging.
- **Trust is the product.** macOS grants Accessibility all-or-nothing, so the per-app allowlist and the local-only guarantee are first-class features, not a settings page.

## How it fits together

```
 ┌───────────────────────── this repo (Swift engine) ─────────────────────────┐
 │                                                                            │
 │  Capture ──raw events──▶ Store (HOT) ──▶ Compact ──▶ Store (WARM / COLD)   │
 │  AX observers,           ~1 day raw      deterministic:                    │
 │  listen-only event tap   SQLite          sessionize · dedup · drop idle    │
 │                                          · collapse repeats (no LLM)       │
 └───────────────────────────────────┬────────────────────────────────────────┘
                                     │  SQLite read-only  +  `openrhyme … --json`
                                     ▼
                    openrhyme-mcp  (Python, github.com/OpenRhyme/openrhyme-mcp)
                    thin MCP server over stdio, usable by any agent
```

Key design choices (reasoning in the spec):

- Three tiers, Loki/Tempo-style: HOT raw → WARM session summaries → COLD archive. Agents read WARM by default and drill into COLD on demand.
- Rollup boundaries follow **activity coherence**, not fixed time windows — a task that spans lunch stays one task.
- **No bundled LLM.** A deterministic layer (`Compact`) does the ~10× volume reduction; whatever agent you already use adds prose on top. If the prose is stale, the fallback is *less prose*, not a background model.
- Retrieval is hybrid: full-text search over the archive plus embeddings. Filenames, error strings and ticket IDs need exact matching.

## Repository layout

| Path | What |
|---|---|
| `Sources/Capture` | Accessibility + input-activity capture (macOS only) |
| `Sources/Store` | SQLite tiers; the schema is the contract other processes read |
| `Sources/Compact` | Inference-free sessionization / dedup / idle dropping |
| `Sources/openrhyme` | The executable: `daemon`, `status`, `apps`, `inspect`, `events`, `export`, `purge`, `privacy`, `version` |
| `Tests/*` | One test target per module |
| `docs/computer-history-spec.md` | The research & design spec — read this first |
| `docs/accessibility-api.md` | The macOS Accessibility API from a capture daemon's point of view |
| `docs/engine-interface.md` | Process topology and how the Python MCP server drives the engine |

## Building

Requires macOS 14+ to run, Xcode 26 / Swift 6.x to build.

```sh
make build     # swift build
make test      # swift test
make lint      # swift format lint --strict
make format    # swift format --in-place
```

## Running the MVP

```sh
make build
.build/debug/openrhyme apps running          # find bundle identifiers
.build/debug/openrhyme apps allow com.apple.TextEdit
make run                                     # starts the daemon in the foreground
# in another terminal, after a while:
.build/debug/openrhyme status
.build/debug/openrhyme events --since 10m
.build/debug/openrhyme export --since 1d --out today.jsonl
```

`events` now carries the visible on-screen text in `value` for every captured app, and `extra.textSource` says which extraction path produced it.

Capture is event-driven: app, window, element and title changes, typing (debounced), menu selections and sleep/wake are recorded the moment they happen; the 5 s heartbeat is only the safety net.

The daemon needs the **Accessibility** grant. When launched from a terminal, macOS attributes the request to the terminal app, so grant it to Terminal/iTerm (System Settings → Privacy & Security → Accessibility). `openrhyme inspect` shows exactly what the daemon can see for the frontmost app. Ad-hoc-signed `swift build` binaries lose the grant on every rebuild — read `docs/accessibility-api.md` §2 before trying.

## Configuration

`config.json` (in the data dir — `$OPENRHYME_DATA_DIR` or `~/Library/Application Support/OpenRhyme/`) carries the allowlist and, under `capture`, the noise-reduction keys added by this slice — all optional, defaults shown:

| Key | Default | What |
|---|---|---|
| `user_input_window_seconds` | `2` | input within this many seconds of a notification marks it user-driven; older marks it ambient (`extra.input`) |
| `content_memory_seconds` | `1800` | how long a stored value's hash suppresses re-storing the same body |
| `activation_settle_ms` | `200` | how long to wait after an app activation before reading the focused context |
| `notifications` | `["window","focus","title","value","menu"]` | the global set of AX notification families to observe |
| `apps` | `{}` | per-bundle-id overrides |

```json
"capture": {
  "notifications": ["window", "focus", "title", "value", "menu"],
  "apps": { "com.cmuxterm.app": { "notifications": ["window", "focus", "menu"] } }
}
```

`value` implies `focus` — a value notification is registered on the focused element and must follow it. `activation_settle_ms` should stay ≤ `value_debounce_ms` (defaults 200 ms ≤ 500 ms) so a debounced refresh never lands before the just-activated app's AX tree has settled. A config edit re-registers the affected observers within one heartbeat, no daemon restart needed.

## Privacy

Worried this recorded your password manager, a `.env` file, or a key you pasted somewhere? Start here.

**Quick answers**
- **Is my password manager captured?** No. 1Password, Bitwarden, LastPass, Enpass, Dashlane and Keychain Access are protected by app id by default — the daemon never reads their content at all.
- **Is a `.env`, `.pem`, SSH key, or credentials file captured?** No, by default — protected by filename/path pattern, checked against whatever document the focused editor has open.
- **What about a secret pasted into an ordinary window** (terminal, editor, browser form)? Recognised secret shapes (AWS/GitHub/Stripe/Slack/Google/OpenAI/Anthropic keys, private-key blocks, JWTs, `key=value` secrets, connection-string passwords, plus a high-entropy-token backstop) are redacted to `[redacted:<rule>]` before the row is written — in all six text columns (`value`, `selected_text`, `window_title`, `url`, `document`, `element_title`) plus `extra.previousTitle`, so a key in a URL query string is redacted on disk too, not just on the way out. The same pass runs again every time a row is read back, so a rule added today also cleans up what was captured last week (see Limits: that read-time pass is the *only* thing protecting rows captured before the rule existed — those still hold the plaintext on disk). This is best-effort pattern matching, not a guarantee (see Limits).
- **A password field?** Any focused field whose identifier or label looks like a credential (`password`, `token`, `api_key`, `secret`, `otp`, …) is treated exactly like a real secure text field: no value is ever read, even if the app never marked it secure.
- **I found something sensitive was already captured — how do I stop it happening again?** Add a rule under `privacy` in `config.json` (below). **A rule only changes what gets captured from now on — it never touches anything already stored.** That's the next question.
- **How do I remove what's already there?** `openrhyme purge --apply-rules --dry-run` shows exactly what the *current* rules would remove from history; add `--yes` to actually delete it. You can also purge by time range, app, or a URL/document substring.
- **How do I verify what's actually happening?** `openrhyme privacy` — prints the policy in force, evaluates the frontmost app/window live, and counts how many stored rows the current *protect rules* match. That count is a rule-match count, not a "nothing sensitive is stored" verdict.
- **How do I see what's really in there — did it capture my key or not?** `openrhyme events --since 7d --ignore-privacy` (also `openrhyme export --ignore-privacy`) returns stored text unredacted, so you can search your own history and confirm a purge actually worked. It warns on stderr and is never the default: the MCP server reads through `events`, so an agent only ever sees the redacted view unless you ask for the raw one yourself.

### The `privacy` config block

All optional; `config.json` lives in the data dir (`$OPENRHYME_DATA_DIR` or `~/Library/Application Support/OpenRhyme/`). Defaults shown:

```json
"privacy": {
  "enabled": true,
  "entropy_redaction": true,
  "protected_bundle_ids": { "add": [], "remove": [] },
  "protected_url_patterns": { "add": [], "remove": [] },
  "protected_document_patterns": { "add": [], "remove": [] },
  "protected_window_title_patterns": { "add": [], "remove": [] },
  "credential_field_patterns": { "add": [], "remove": [] }
},
"capture": { "retention_days": 0 }
```

| Key | Default | What |
|---|---|---|
| `privacy.enabled` | `true` | master switch for context protection *and* redaction. `false` restores pre-slice behaviour (today's full capture); the `AXSecureTextField` guard is unconditional and is never affected by this switch. |
| `privacy.entropy_redaction` | `true` | the Shannon-entropy backstop that catches high-entropy tokens with no matching structural rule. |
| `privacy.protected_bundle_ids` | 8 password managers | apps whose content is never read at all (1Password, Bitwarden, LastPass, Enpass, Dashlane, Keychain Access, …). |
| `privacy.protected_url_patterns` | vault/credential URL substrings | e.g. `1password.com`, `://vault.`, `/settings/credentials`, `/iam-admin/serviceaccounts`. |
| `privacy.protected_document_patterns` | sensitive filename globs | e.g. `.env`, `*.pem`, `id_rsa*`, `*credentials*`, `*/.ssh/*` — matched case-insensitively against the document's full path and its last path component. |
| `privacy.protected_window_title_patterns` | `private browsing` | Safari's private windows carry this in the title; Chrome Incognito is not detectable this way (see Limits). |
| `privacy.credential_field_patterns` | `password`, `token`, `api_key`, `secret`, `otp`, … | matched against a focused element's identifier/title; a match is treated exactly like a secure field. |
| `capture.retention_days` | `0` (keep forever) | automatically deletes events older than this many days, swept on daemon start and every 24h. See "Retention deletes on a timer" under Limits before turning this on. |

Every list is **`defaults ∪ add \ remove`** — a two-key object, not a plain array, so you extend or turn off individual defaults without restating the whole list:

```json
"privacy": {
  "protected_bundle_ids": { "add": ["com.example.Vault"], "remove": [] },
  "protected_url_patterns": { "add": ["internal-vault.corp"], "remove": [] }
}
```

Putting a default value in `remove` turns off just that one protection (e.g. `"protected_window_title_patterns": {"add": [], "remove": ["private browsing"]}` stops treating Safari private windows specially) without touching anything else.

### Commands

- **`openrhyme privacy [--json]`** — read-only report. Shows whether privacy is enabled, every rule list with its count, what the frontmost app/window evaluates to right now (`open` or the rule protecting it), the retention setting, and how many *already-stored* rows a protect rule matches. That last number (`stored_rows_matching_rules`) is a rule-match count and nothing more — a stored row that merely contains a secret matches no rule, so it is not counted and `purge --apply-rules` would not remove it; the human output says so on the same line. Never creates, migrates, or writes to the store.
- **`openrhyme purge`** — deletes stored events. Nothing is deleted without either `--dry-run` (report only, changes nothing) or `--yes` (confirm); without one of those it prints what would be removed and refuses, exit 2. Select what to purge with `--since`/`--until`, `--app <bundle-id>`, `--url-contains <substring>`, `--apply-rules` (rows the *current* protect rules would block — the retroactive scrub), or `--all`. A real deletion runs `VACUUM` and a WAL checkpoint so the freed space actually leaves the file, then reports `{matched, deleted, vacuumed}`. A running daemon only earns a warning, never a refusal — deleting sensitive data on demand must never be gated behind stopping the daemon first.
  ```sh
  openrhyme purge --apply-rules --dry-run       # preview: what would today's rules remove?
  openrhyme purge --apply-rules --yes           # actually remove it
  openrhyme purge --since 30d --until 7d --yes  # remove a time window
  openrhyme purge --app com.example.SomeApp --yes
  ```
- **`openrhyme inspect --ignore-privacy`** — the dev tool that shows exactly what the daemon can see for the frontmost app. By default it honours the same policy as capture: pointed at a protected context it prints only the rule name, and on an open context it still applies the credential-field guard and secret redaction to the element, its subtree and the window's title/document/URL. `--ignore-privacy` overrides all of that for debugging, prints a warning to stderr first, and never writes to the store. (The `AXSecureTextField` guard is unconditional and `--ignore-privacy` does not lift it.)
- **`openrhyme events --ignore-privacy`, `openrhyme export --ignore-privacy`** — the same flag on the read commands: returns stored text exactly as it sits in the database, with no read-time redaction. This is how you audit your own history — find out whether something sensitive was captured, and confirm a purge removed it. Warns on stderr (never on stdout, so `--json` stays parseable) and is opt-in only; without it every read stays redacted, including the MCP server's.
  ```sh
  openrhyme events --since 7d --ignore-privacy --json | grep -i 'AKIA'   # is my key in there?
  openrhyme purge --apply-rules --yes
  openrhyme events --since 7d --ignore-privacy --json | grep -i 'AKIA'   # …and is it gone?
  ```

### What a protected marker row looks like

When the frontmost context matches a protect rule, the only thing stored is an app-level marker — no window title, document, URL, element, value, or selected text:

```json
{
  "kind": "context.snapshot",
  "pid": 1234, "bundle_id": "com.1password.1password", "app_name": "1Password",
  "extra": {
    "reason": "activated",
    "protected": true,
    "protectedBy": "bundle-id",
    "fingerprint": "…"
  }
}
```

Consecutive heartbeats in the same protected context dedup to that one row; leaving the app produces the usual deactivation event. The timeline shows "you were in 1Password for 4 minutes" and nothing about what you did there.

### JSON key convention

Two tiers, deliberately different: top-level `--json` output uses **snake_case** (`bundle_id`, `data_dir`, `stored_rows_matching_rules`, `dry_run`, `protected_by`, …), matching every other CLI command. The `extra` blob attached to individual events uses **camelCase** (`protectedBy`, `redacted`, `valueHash`, `fingerprint`, `previousTitle`, …) — that convention predates this slice and stays as-is so existing consumers, including the MCP, don't break.

### The `daemon.started` posture record

Every daemon start appends a `daemon.started` row recording the privacy posture in force at that moment, so you (or an auditor) can later tell whether redaction was even on during a given stretch of history:

```json
"extra": {
  "version": "…", "schema": 1, "allowlist": ["…"],
  "privacy": { "enabled": true, "protectedRules": 49, "retentionDays": 0 }
}
```

`protectedRules` counts configured rule entries across all five categories and reports `0` whenever `enabled` is `false` — it describes what was actually being *enforced*, not what's merely configured on disk (a fully-enabled policy with every rule removed and a fully-disabled policy both show `0` protected rules, but redaction is live in one and dead in the other; `enabled` is what tells them apart).

### Limits — read this before trusting any of the above

Fifteen of them, stated plainly. If a claim above sounds stronger than a limit here, the limit is the accurate one.

- **A rule protects only future captures.** This is the single most important thing to understand: editing `privacy` in `config.json` changes nothing about rows already stored. Run `openrhyme purge --apply-rules` (above) to remove matches retroactively.
- **`purge` is not forensic erasure.** It deletes rows, vacuums, and checkpoints so matching text leaves the database file — but the filesystem extents that vacuum frees are returned un-zeroed, so someone with raw disk access (a forensic image, an unencrypted backup, a stolen unencrypted drive) may still recover fragments. If that's your threat model, full-disk encryption (FileVault) is the real mitigation, not `purge`.
- **`purge --apply-rules` removes only rows a *protect rule* matches — not every row holding something sensitive.** It selects on bundle id, URL, document and window title, exactly like capture does. A row that merely *contained* a secret (an ordinary editor window, a terminal) matches no rule, is not selected, and stays. This is why `openrhyme privacy`'s `stored_rows_matching_rules` is a rule-match count and never a clean bill of health: `0` means "no rule matches", not "nothing sensitive is stored". To answer the second question, read the store unredacted (`openrhyme events --since 7d --ignore-privacy`) and purge by time range, app or `--url-contains`.
- **Auditing your own history needs an explicit flag.** Every read path redacts by default — that is what keeps the MCP server (and any agent behind it) from seeing raw secrets. The consequence is that plain `events`/`export` cannot show you what the database actually holds, so a search that comes back empty proves nothing. `--ignore-privacy` on `events`/`export` is the supported way to see the stored bytes; it prints a warning to stderr and is never implied by anything else.
- **The directory's `0700` is applied only when the daemon starts; the database's `0600` is applied on every read-write open.** So an install from before this slice keeps a looser *directory* mode until the daemon is restarted once (`openrhyme daemon`, or however your launchd/service manager runs it), while `events.sqlite` is re-tightened by any command that opens it for writing. A read-only command tightens neither.
- **A protected app is still observed — protection means "the content is not read", not "the daemon ignores this app".** An allowlisted app gets AX observers, activation/deactivation rows and protected-marker rows regardless of the protect rules (menu notifications are the one exception: a bundle-id-protected app is never registered for them). Your timeline still shows that you spent four minutes in 1Password; only what you did there is missing.
- **Capture-time and read-time redaction now cover the same columns, but only read-time protects old rows.** The secret rules live in the binary and the config, so a row captured by an older build, or while `privacy.enabled` was `false`, still holds the plaintext on disk — the read-time pass is the only thing hiding it, and `--ignore-privacy`, `sqlite3`, a backup or the planned Compact layer all see through that. Purge such rows if it matters. Related: `extra.valueHash` is computed at capture over the value *as stored* (already redacted), so read-time redaction that alters a row makes the returned text no longer hash to it — a useful signal that a later rule caught something capture missed.
- **`export` output is only as protected as wherever you put it.** The file is created `0600`, but from there it is an ordinary file: nothing in this tool redacts it again, `purge` never reaches it, and a copy in a synced folder, a repo, an attachment or a backup is a plaintext extract of your history. With `--ignore-privacy` it is a fully unredacted one.
- **Read-time redaction invalidates `extra.valueHash`** for any row it alters — the returned text no longer hashes to the stored value. See the capture/read bullet above for why.
- **A corrupt `config.json` now stops the daemon from starting**, where it previously fell back to defaults. Deliberate fail-closed behaviour for a privacy tool — a config the daemon can't parse should not silently mean "no privacy settings" — but it means a single stray comma now looks like a crash loop under a supervisor rather than a config error. Fix: repair the JSON; `openrhyme daemon` (and `events`/`export`) reports `config_invalid` with the parse reason.
- **The retention sweep's clock guard has a residual hole.** It refuses to sweep when the computed cutoff is newer than the newest real event it has observed (ignoring its own bookkeeping rows) — the honest response to "the clock might be wrong, not time actually passing." But a clock that is fast *and stays fast* while capture keeps happening writes genuine rows stamped at that bad time, indistinguishable from time genuinely having passed. The guard catches a jump; it can't catch a clock that's been wrong the whole time.
- **Audit rows accumulate and are never swept automatically.** `daemon.started`/`daemon.stopped`/`permission.changed` are exempt from the automatic retention sweep specifically so the posture record survives a retention window — they're the evidence that answers "was redaction even on then?" They're small (roughly 350–400 bytes per daemon restart cycle) but unbounded; `openrhyme purge` (the explicit command, not the automatic sweep) can remove them if that ever matters.
- **Retention deletes on a timer, unattended.** `capture.retention_days` (default `0`, off) sweeps events older than that many days on daemon start and every 24 hours after. The **first** sweep after turning it on from off is skipped, with a notice naming how many rows would go, so you get one full run to review before anything is actually removed — preview any time with `openrhyme purge --until <N>d --dry-run`. A quoted string value like `"30"` is treated as **off**, with a warning at daemon start — only a bare integer turns it on.
- **Pattern-based secret detection is best-effort** and will miss custom or unusual formats. It is the second line of defence behind never capturing at all, not a guarantee.
- **File permissions stop other accounts, not other processes running as you.** `0700`/`0600` keeps other user accounts out; anything running under your own account can read the store.

## Roadmap and open questions

From spec §9:

1. First slice — capture daemon alone, or capture + MCP so an agent can query it on day one?
2. ~~Daemon language~~ → **Swift** (decided 2026-09-01). MCP server → **Python**, [OpenRhyme/openrhyme-mcp](https://github.com/OpenRhyme/openrhyme-mcp).
3. Sessionization signals — app switch? idle threshold? file/project change? a scored combination?
4. Per-app allowlist UX.
5. Retention defaults and cold-tier TTL.
6. Proving local-only to a skeptical user (no network entitlement, auditable build).

Next concrete step (spec §10): read [OpenHistory](https://github.com/ztratar/openhistory)'s issue tracker before writing capture code.

## Prior art

| Project | Approach | Gap |
|---|---|---|
| [OpenHistory](https://github.com/ztratar/openhistory) | Swift collector + Electron UI, hourly/daily summaries for local agents | Closest competitor; single-app shape |
| [ActivityWatch](https://activitywatch.net) | Cross-platform, local-first | App/window titles only, no content |
| Dayflow | Screenshot every 10 s, AI narrates the day | Vision-based, heavier |

## License

MIT — see [LICENSE](LICENSE).
