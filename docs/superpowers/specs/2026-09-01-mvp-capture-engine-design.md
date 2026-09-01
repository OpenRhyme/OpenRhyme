# OpenRhyme MVP — capture engine design

**Status:** approved design, 2026-09-01. Supersedes the storage tiers of `docs/computer-history-spec.md` §6 *for the MVP only*; the tiers return in a later spec.
**Scope:** the Swift engine in this repository. The MCP server has its own spec in `openrhyme-mcp/docs/superpowers/specs/2026-09-01-mvp-mcp-server-design.md`.

## 1. Decisions this spec records

| Decision | Choice | Why |
|---|---|---|
| Accessibility layer | Our own thin layer over the C API; [AXorcist](https://github.com/openclaw/AXorcist) used as a reference, not a dependency | Read-only daemon; keep the audit surface small; own the threading model |
| Storage | One SQLite table of raw events. No hot/warm/cold tiers, no compaction | MVP goal is to see what a model does with raw events; that result specifies the compaction layer |
| Capture strategy | Hybrid: per-app `AXObserver`s **plus** a 5 s heartbeat poll-and-diff **plus** permission-free idle detection. The heartbeat path is built first | Precision of push, safety net of poll, one dedup path |
| App scope | Allowlist, empty by default | Trust is the product; nothing is captured until the user names an app |
| Content depth | Full value of the focused element on change | User's choice for the experiment; guarded by debounce, identical-value dedup, secure-field skip, and a size cap |
| Consumers | `openrhyme events --json`, `openrhyme export --jsonl`, MCP `events` tool | Pull-based; live push is out of scope |
| Concurrency | All AX/`NSWorkspace` work on the main thread; store is an actor | Simplest correct model for a headless daemon |
| SQLite access | Thin wrapper over the system `sqlite3` (~150 lines) | One table, four queries; GRDB when FTS5/migrations arrive |
| Electron | Detect Electron bundles and set `AXManualAccessibility` once | VS Code / Slack / Cursor are most people's day |
| Input events | No `CGEventTap` (no Input Monitoring grant). Idle via `CGEventSource.secondsSinceLastEventType`, verified to work with no TCC grant on macOS 26.5 | Second permission and keylogger surface avoided entirely |
| Dependencies | `swift-argument-parser` only; logging via `os.Logger` | Auditability |

## 2. Goals, non-goals, success

**Goal.** Run `openrhyme daemon` in a terminal for a workday against 3–5 allowlisted apps and end up with one SQLite table of raw events that can be read three ways — CLI JSON, JSONL export, and the MCP `events` tool — so an agent can be asked "what was I doing at 2 pm?" from unprocessed data.

**Non-goals (explicitly deferred):** storage tiers, sessionization/compaction, FTS/embeddings, event tap / Input Monitoring, `launchd` packaging, any UI, code signing/notarization, Homebrew, Windows/Linux.

**Definition of done.**
1. A full workday of capture with no crash across app launch, quit, hang, and system sleep/wake.
2. Daemon CPU under ~2 % averaged over the day (Activity Monitor), idle CPU ≈ 0.
3. `openrhyme export --since 8h --jsonl` produces well-formed JSONL; `openrhyme events --since 1h --json` returns the envelope in §9.
4. An agent using the MCP `events` tool answers a "what was I doing between 14:00 and 15:00" question correctly for that day.
5. `make build && make test && make lint` pass; CI green.

## 3. Architecture

```
                        main thread (RunLoop.main)                       cooperative pool
 ┌──────────────────────────────────────────────────────────┐    ┌──────────────────────┐
 │ Capturer (@MainActor)                                    │    │ EventStore (actor)   │
 │   AppLifecycle ── NSWorkspace launch/quit/activate/sleep │    │   SQLite3 connection │
 │   AXObserverHub ─ per-pid observers, run-loop sources    │──▶ │   WAL, single writer │
 │   Heartbeat ───── every 5 s: pull focused ctx, diff      │    │   insert / query /   │
 │   Idle ────────── secondsSinceLastEventType              │    │   export             │
 │   Redaction ───── secure fields, dedup, caps             │    └──────────┬───────────┘
 └──────────────────────────────────────────────────────────┘               │
                     AsyncStream<RawEvent>  ───────────────────────────────┘
                                                                            ▼
                     ~/Library/Application Support/OpenRhyme/events.sqlite  ◀── openrhyme CLI (ro)
                                                                            ◀── openrhyme-mcp (ro)
```

- `AXUIElement`, `AXObserver`, and every `kAX…` constant stay inside `Capture`. Everything that leaves `Capture` is a `RawEvent` (plain `Sendable` struct).
- The daemon is the only writer. The CLI and the MCP server open the database read-only.
- The heartbeat is also where `config.json` is re-read and permissions are re-checked, so `openrhyme apps allow` takes effect without a restart.

## 4. Modules

| Target | Depends on | Responsibility | Files (approx. lines) |
|---|---|---|---|
| `Core` | — | `RawEvent`, `EventKind`, `Config`, `Paths`, time parsing | `RawEvent.swift` (100), `JSONValue.swift` (60), `Config.swift` (120), `Paths.swift` (40), `TimeSpec.swift` (60) |
| `Capture` | `Core`, ApplicationServices, AppKit | everything in §6 | `AXClient.swift` (220), `AXObserverHub.swift` (260), `AppLifecycle.swift` (120), `Capturer.swift` (350), `LastKnownState.swift` (80), `Redaction.swift` (70), `ElectronSupport.swift` (60), `IdleMonitor.swift` (50) |
| `Store` | `Core`, SQLite3 | §7 | `Database.swift` (160), `Schema.swift` (80), `EventStore.swift` (180), `JSONLExport.swift` (60) |
| `Compact` | `Core` | empty stub; not part of the MVP | — |
| `openrhyme` | all of the above, swift-argument-parser | §9 commands, §10 daemon runtime | one file per command |

Rules: `Capture` and `Store` never import each other. `Capture` exposes a protocol `AXReading` (attribute reads, observer registration, trust check) with the real implementation `AXClient` and a `FakeAXClient` in tests, so `Capturer` logic is testable without a TCC grant.

## 5. Event model

```swift
public struct RawEvent: Codable, Sendable, Equatable {
    public var id: Int64?            // assigned by the store
    public var ts: Double            // unix seconds, fractional
    public var kind: EventKind
    public var pid: Int32?
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var document: String?     // kAXDocumentAttribute: file URL / path
    public var url: String?          // kAXURLAttribute (browsers)
    public var role: String?
    public var subrole: String?
    public var identifier: String?   // kAXIdentifierAttribute
    public var elementTitle: String?
    public var value: String?        // full text (see §6.5)
    public var selectedText: String?
    public var extra: [String: JSONValue]?  // kind-specific, see table
}
```

`EventKind` is a `String`-backed enum. Which fields are populated per kind:

| Kind | When | Fields beyond `ts`/`kind` | `extra` |
|---|---|---|---|
| `daemon.started` / `daemon.stopped` | process start/stop | — | `version`, `schema`, `allowlist` |
| `permission.changed` | trust state transition | — | `trusted: Bool`, `state: "needsPermission"\|"active"\|"stale"` |
| `app.launched` / `app.terminated` | `NSWorkspace` for allowlisted apps | `pid`, `bundleID`, `appName` | — |
| `app.activated` / `app.deactivated` | frontmost app changes, for **allowlisted apps only**. Leaving to a non-allowlisted app is visible only as `app.deactivated` of the allowlisted one. With `capture.record_other_apps = true` (default `false`) other apps also emit `app.activated` with `bundleID`/`appName` and nothing else | `pid`, `bundleID`, `appName` | `allowlisted: Bool` |
| `app.ax_enabled` | Electron enabling attempted | `pid`, `bundleID` | `method: "AXManualAccessibility"\|"AXEnhancedUserInterface"`, `result: "ok"\|"unsupported"\|"failed"` |
| `app.opaque` | app marked opaque after N failures | `pid`, `bundleID` | `failures`, `lastError` |
| `window.focused` | focused window changed | app fields, `windowTitle`, `document`, `url` | `windowID` if available |
| `window.title_changed` | title of focused window changed | app fields, `windowTitle`, `document`, `url` | `previousTitle` |
| `window.created` / `window.destroyed` | observer | app fields, `windowTitle` | — |
| `element.focused` | focused element changed | app fields, `windowTitle`, `role`, `subrole`, `identifier`, `elementTitle`, `value` (subject to §6.5), `selectedText` | — |
| `element.value_changed` | debounced value change of the focused element | same as above | `valueHash`, `truncated: Bool`, `length` |
| `element.selection_changed` | selected text changed | app fields, `role`, `selectedText` | `range: {location, length}` |
| `menu.item_selected` | observer | app fields, `elementTitle` (menu item title) | `menuPath` if resolvable |
| `context.snapshot` | heartbeat found a change no notification reported | full focused context | `reason: "heartbeat"` |
| `idle.started` / `idle.ended` | idle threshold crossed | — | `idleSeconds` |
| `system.sleep` / `system.wake` | `NSWorkspace` will-sleep / did-wake | — | — |

`JSONValue` is a small `Codable` enum (string/number/bool/null/array/object) in `Core`; `extra` is stored as JSON text.

## 6. Capture

### 6.1 App discovery and allowlist
- The allowlist is a set of bundle identifiers in `config.json`. Matching is exact and case-sensitive.
- On start and on each heartbeat, `NSWorkspace.shared.runningApplications` is filtered by the allowlist; new pids get observers, gone pids get cleaned up.
- `NSWorkspace.shared.notificationCenter` subscriptions: `didLaunchApplication`, `didTerminateApplication`, `didActivateApplication`, `willSleep`, `didWake`.
- Non-allowlisted apps are never read and never get an observer. By default they do not appear in the timeline at all — leaving an allowlisted app shows up as its `app.deactivated`, nothing more. `capture.record_other_apps: true` opts into recording `app.activated` with bundle id and name only, for users who want "I was elsewhere for 20 minutes" to be attributable.

### 6.2 Heartbeat path (built first)
Every `capture.heartbeat_seconds` (default 5):
1. Re-read `config.json` if its mtime changed.
2. Re-check trust (§6.8).
3. If the frontmost app is allowlisted: pull the **focused context** — `AXUIElementCreateSystemWide` → `kAXFocusedApplicationAttribute` → `kAXFocusedWindowAttribute` (+ `kAXTitleAttribute`, `kAXDocumentAttribute`, `kAXURLAttribute`) → `kAXFocusedUIElementAttribute` (+ the bundle in §6.4).
4. Diff against `LastKnownState` (per pid: window title, document, url, focused element identity, value hash, selection). Emit `context.snapshot` carrying the changed context if anything differs and no observer event already recorded that change since the last heartbeat.
5. Idle check (§6.6).

Everything the observer path emits also updates `LastKnownState`, which is what makes the two paths dedup against each other.

### 6.3 Observer path
- One `AXObserver` per allowlisted pid, created via `AXObserverCreate`, source added to `RunLoop.main`. Registered on the **application element**: `kAXApplicationActivated/Deactivated`, `kAXFocusedWindowChanged`, `kAXMainWindowChanged`, `kAXFocusedUIElementChanged`, `kAXTitleChanged`, `kAXWindowCreated`, `kAXUIElementDestroyed`, `kAXMenuItemSelected`.
- `kAXFocusedWindowChanged` and `kAXMainWindowChanged` both map to `window.focused`, emitted only when the window differs from `LastKnownState`.
- On `kAXFocusedUIElementChanged`: read the focused element bundle, emit `element.focused`, then register `kAXValueChanged` and `kAXSelectedTextChanged` **on that element** (remove them from the previous focused element).
- `kAXValueChanged` is **debounced** per element with `capture.value_debounce_ms` (default 500): the value is read once when the quiet period ends, and flushed early on focus change, app deactivation, or daemon stop. This is what keeps "full text" from producing one event per keystroke.
- Lifecycle: on `didLaunchApplication` for an allowlisted app, attempt observer creation; if it fails with `cannotComplete` / `invalidUIElement` (app not ready), retry at 1 s, 3 s, 10 s, then give up until the next heartbeat notices the app. On `didTerminateApplication`, remove the observer and forget the pid's state. `kAXErrorNotificationUnsupported` on a registration is logged once and skipped.
- The observer callback is `@convention(c)`; the hub passes itself through `refcon` via `Unmanaged`. Callbacks do the minimum (identify pid + notification, read the bundle) and hand off.

### 6.4 The attribute bundle
Read with one `AXUIElementCopyMultipleAttributeValues` call: `kAXRole`, `kAXSubrole`, `kAXIdentifier`, `kAXTitle`, `kAXDescription`, `kAXValue`, `kAXSelectedText`, `kAXSelectedTextRange`, `kAXNumberOfCharacters`, `kAXDocument`, `kAXURL`. Window bundle: `kAXTitle`, `kAXDocument`, `kAXURL`. App bundle: `kAXTitle` plus `NSRunningApplication.localizedName` / `bundleIdentifier`.

Text extraction order for `value`: `kAXValue` → `kAXSelectedText` → `kAXDescription`/`kAXTitle` for static text → per-app literal fallbacks (`"AXValueAttribute"`, `"AXText"`) kept in a small table in `AXClient`.

### 6.5 Redaction and caps (apply on every path)
- `subrole == kAXSecureTextFieldSubrole`: never read `value` or `selectedText`; `element.focused` is still emitted with `role`/`subrole` so the timeline shows a password field was used.
- Identical-value dedup: `extra.valueHash` (SHA-256 of the value) compared to the last stored hash for that element; identical → no event. Element identity is `CFEqual`/`CFHash` on the `AXUIElement`, tracked only inside `LastKnownState` within `Capture`; it is not persisted.
- Size cap: `capture.max_value_bytes` (default 524288). Larger values are truncated at a UTF-8 boundary, `extra.truncated = true`, `extra.length` carries the original length.
- Non-allowlisted apps: never read at all (§6.1).

### 6.6 Idle
`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)` checked on each heartbeat. Crossing `capture.idle_seconds` (default 120) upward emits `idle.started`; the first heartbeat with a smaller value emits `idle.ended` with `extra.idleSeconds` = the idle span. No TCC grant is needed for this call (verified 2026-09-01, macOS 26.5, process with neither Accessibility nor Input Monitoring).

### 6.7 Electron enabling
An allowlisted app is treated as Electron if its bundle contains `Contents/Frameworks/Electron Framework.framework`. On first observer creation for such an app, set `AXManualAccessibility = true` on the application element; if that returns `attributeUnsupported`, set `AXEnhancedUserInterface = true`. Emit `app.ax_enabled` with the outcome. This is the only write the daemon ever performs into another process; it is logged and visible in `status`.

### 6.8 Permissions and recovery
States: `needsPermission` → `active` → `stale`.
- Start: `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`. Not trusted → print the System Settings path to stderr, state `needsPermission`, heartbeat keeps checking; on grant emit `permission.changed` and proceed.
- Any AX call returning `kAXErrorAPIDisabled` while `active` → state `stale`, emit `permission.changed`, back off 5 s → 10 s → 20 s (cap 60 s) between re-checks, log once that a relaunch may be needed after a macOS update.
- `AXUIElementSetMessagingTimeout(systemWide, 0.25)` at start.
- Per-pid failure counter: 5 consecutive `cannotComplete`/`notImplemented` on heartbeat reads → emit `app.opaque`, stop reading content for that pid (app/window events continue), retry once per 5 minutes.

### 6.9 Performance budget
Heartbeat: ≤ 4 IPC round-trips when nothing changed. Observer callbacks: ≤ 1 `CopyMultipleAttributeValues`. No tree walks anywhere in the daemon (`inspect` is the exception and is a CLI command, not the daemon). Target ≤ 2 % average CPU.

## 7. Store

### 7.1 Schema v1
```sql
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO meta VALUES ('schema_version', '1');

CREATE TABLE IF NOT EXISTS events (
  id            INTEGER PRIMARY KEY,
  ts            REAL    NOT NULL,
  kind          TEXT    NOT NULL,
  pid           INTEGER,
  bundle_id     TEXT,
  app_name      TEXT,
  window_title  TEXT,
  document      TEXT,
  url           TEXT,
  role          TEXT,
  subrole       TEXT,
  identifier    TEXT,
  element_title TEXT,
  value         TEXT,
  selected_text TEXT,
  extra         TEXT              -- JSON object or NULL
);
CREATE INDEX IF NOT EXISTS events_ts        ON events (ts);
CREATE INDEX IF NOT EXISTS events_kind_ts   ON events (kind, ts);
CREATE INDEX IF NOT EXISTS events_app_ts    ON events (bundle_id, ts);
```
Column names are the JSON field names in exports and in the MCP server. `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=2000`.

### 7.2 Access
- `Database`: open (create dir, set pragmas), `exec`, prepared-statement bind/step/column helpers, error type wrapping `sqlite3_errmsg`. `Schema.migrate(db)` applies v1 and records the version; a database with a **newer** version than the binary understands is refused with a clear error.
- `EventStore` (actor): `append(_ event: RawEvent) async throws -> Int64`, `query(since:until:kinds:bundleID:limit:) -> [RawEvent]` (ordered by `ts, id`, `limit` capped at 10 000), `count()`, `lastEventTS()`, `export(...) -> AsyncStream<String>` of JSONL lines.
- Writes: one `INSERT` per event inside an implicit transaction; WAL makes this cheap at MVP volumes (tens of events per minute).
- Readers use `SQLITE_OPEN_READONLY`.

### 7.3 JSONL export
One JSON object per line, keys = column names, `null` fields omitted, `extra` inlined as an object, `ts` as a number. Deterministic key order (column order) so diffs are readable.

## 8. Config and paths

`$OPENRHYME_DATA_DIR` or `~/Library/Application Support/OpenRhyme/`:
```
events.sqlite  (+ -wal, -shm)
config.json
daemon.pid
```
`config.json` (all keys optional; defaults shown):
```json
{
  "schema": 1,
  "allowlist": [],
  "capture": {
    "heartbeat_seconds": 5,
    "idle_seconds": 120,
    "value_debounce_ms": 500,
    "max_value_bytes": 524288,
    "record_other_apps": false
  }
}
```
Unknown keys are preserved on rewrite. The CLI is the only writer of `config.json`; the daemon reloads it on mtime change.

## 9. CLI

Built with swift-argument-parser. Every command accepts `--json`; `--json` output is exactly one object on stdout, diagnostics go to stderr.

| Command | Behaviour |
|---|---|
| `openrhyme daemon` | §10 |
| `openrhyme status --json` | `{trusted, state, daemonRunning, pid, dataDir, dbPath, eventCount, lastEventTS, allowlist, opaqueApps}` |
| `openrhyme apps list --json` | allowlist |
| `openrhyme apps running --json` | running apps: `bundleID`, `name`, `pid`, `allowlisted`, `isElectron` — to help pick |
| `openrhyme apps allow <bundle-id>` / `deny <bundle-id>` | edits `config.json`; idempotent |
| `openrhyme inspect --json` | focused app/window/element: the §6.4 bundle **plus** `AXUIElementCopyAttributeNames` and, with `--depth N`, a bounded child subtree. Developer tool; requires trust |
| `openrhyme events --since <time> [--until <time>] [--kind k]... [--app bundle] [--limit n] --json` | `{ok, data: {events: [...], count}}` |
| `openrhyme export --since <time> [--until <time>] [--out path]` | JSONL to stdout or file |
| `openrhyme version --json` | `{engine: "0.1.0", schema: 1}` |

`<time>` accepts ISO-8601 (`2026-09-01T14:00:00Z`, local time without zone), unix seconds, or a relative duration `30m` / `2h` / `1d` meaning "that long ago".

Envelope: `{"ok": true, "data": …}` or `{"ok": false, "error": {"code": "<stable_snake_case>", "message": "…", "hint": "…"}}`. Exit codes: `0` ok · `1` failure · `2` usage · `3` not trusted · `4` daemon not running (only where it matters) · `5` schema too new.

## 10. Daemon runtime
1. Resolve paths, load config, open store, `Schema.migrate`.
2. Write `daemon.pid`; refuse to start if the pidfile names a live process.
3. Trust check (§6.8); emit `daemon.started`.
4. Start `AppLifecycle`, create observers for running allowlisted apps, start heartbeat timer and idle monitor, run `RunLoop.main`.
5. `SIGINT`/`SIGTERM`: flush debounced values, emit `daemon.stopped`, close the store, remove the pidfile, exit 0.
6. Logging: `os.Logger(subsystem: "org.openrhyme.engine")` plus a compact stderr line per lifecycle event; `--verbose` adds per-event lines.

## 11. Testing
- `Core`: `RawEvent` JSON round-trip; `TimeSpec` parsing table; `Config` defaults, unknown-key preservation.
- `Store`: temp-dir database — migrate is idempotent; refuse newer schema; append/query ordering and filters; export format; WAL pragma set.
- `Capture`: `FakeAXClient` scripted with focused contexts and notification sequences → assert emitted `RawEvent`s: heartbeat diff, observer/heartbeat dedup, debounce/flush, secure-field skip, size cap and `truncated`, identical-hash dedup, opaque marking, Electron detection from a fixture bundle layout.
- CLI: command logic invoked directly with a temp data dir; envelope and exit codes.
- Live: `OPENRHYME_LIVE_AX=1 swift test --filter Live` exercises real AX against TextEdit; never run in CI.

## 12. Milestones (ordering for the implementation plan)
1. **Core + Store + CLI without capture** — `events`, `export`, `version`, `status` (static parts) against synthetic events. First green CI.
2. **Heartbeat capture** — `AXClient`, focused-context pull, `LastKnownState` diff, permissions, `inspect`, `apps`, `daemon` runtime. First real data.
3. **Observers** — `AXObserverHub`, notification set, focused-element re-registration, debounce, lifecycle retries, dedup with heartbeat.
4. **Idle, sleep/wake, Electron, opaque detection, `status` completeness.**
5. **MCP server** — separate repo, own spec.
6. **Workday soak** against the definition of done; write up what the model does with the raw stream → input to the compaction spec.

## 13. Deferred, on purpose
Tiers and compaction (next spec, informed by milestone 6), event tap, `launchd`, signing/notarization, Homebrew, per-app content rules beyond allowlist, embeddings/FTS.

## 14. References
`docs/computer-history-spec.md` (product reasoning) · `docs/accessibility-api.md` (API facts, error table, traps) · `docs/engine-interface.md` (CLI/JSON contract, process topology) · AXorcist `Sources/AXorcist/Core/{AXObserverCenter,ObserverNativeWork,AXTimeoutPolicy}.swift` as reference for observer lifecycle hardening.
