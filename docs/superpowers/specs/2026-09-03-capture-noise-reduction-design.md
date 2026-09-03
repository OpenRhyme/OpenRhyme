# Capture noise reduction — hashing, input gating, and the six fixes

**Status:** approved design, 2026-09-03. Third post-MVP slice (after content extraction and observers).
**Scope:** the Swift engine `Capture` module + two config keys in `Core`. **No storage-schema change (stays v1), no `--json` contract change, no MCP change** — only additive keys inside the existing `extra` JSON.
**Builds on:** `docs/superpowers/specs/2026-09-02-observers-design.md` (§4 one pipeline, §6.3–6.4 debounce/drop), `docs/superpowers/specs/2026-09-01-content-extraction-design.md` (§6 the content-cache gate), MVP spec §6.5 (redaction), product spec §6.2 (the deterministic layer cuts volume before any agent sees the data).

## 1. Problem

Observers gave us a complete timeline and, as the price, every notification an app feels like sending. Measured on the first dogfood after observers (2h / 20-min samples via the MCP):
- **61 % of all rows were `window.title_changed`** — cmux repainting a spinner glyph every second (◐→◑, 132 rows in 20 min), Chrome re-announcing a tab whose only change was an `Audio playing` / `High memory usage - 807 MB` badge, and per-second player ticks. In most of them the title string was *identical* before and after; the row was emitted because a focused slider's value or a badge had dirtied the change signature.
- **36 % of stored text bytes were re-stores of a page body already in the store** (the OpenRhyme repo page stored 4× at 10 KB as tabs were flipped).
- **46 % of `element.focused` rows were anonymous** — no title, no identifier, no text (cmux's empty terminal area, unnamed buttons/groups).
- The first snapshot after each Chrome activation paired one tab's title with another tab's text (26 switches, 26 wrong rows).

None of this is *new information*; almost all of it is the screen changing by itself while the user did nothing. The product spec's rule is that the deterministic layer cuts volume by an order of magnitude before any agent sees the data — this slice does that at the source, so the rows never exist.

## 2. Non-goals

- **No near-duplicate similarity.** Every distinct content hash is a distinct version and is stored (a 5 % change can matter). Only *identical* content is deduplicated.
- **No event tap, no keystroke or click counts** (Input Monitoring grant) — the input signal used here is the grant-free "seconds since last input" already in the protocol.
- **No compaction, entities, or episodes** — that is the next slice; it will key on the `fingerprint` this slice stores.
- **No per-app content depth or privacy categories** — the privacy slice.
- No `status` output change; no schema v2.
- **Accepted losses found during review:**
  - A user-driven title or value change killed by an app switch inside the debounce window is lost outright, with no heartbeat backstop (new for titles; already true for values).
  - A title change subsumed by a value refresh in the same window is emitted as `element.value_changed`, losing its `window.title_changed` kind and `extra.previousTitle` (the title itself still rides in `windowTitle`).
  - An app visit shorter than `activation_settle_ms` produces no `app.activated`/`app.deactivated` pair at all, not merely one refresh instead of two.

## 3. Success criteria

1. Badge, spinner, and counter flicker in a title produces **no event and no AX read** (unit tests over the rule table; live: cmux spinner rows → 0).
2. **Ambient** title/value notifications (no user input within the window) produce no rows; **user-driven** ones are recorded exactly as today (title within one debounce, typing within one debounce).
3. A value whose hash was stored within the memory window is emitted with `valueHash` + `valueUnchanged: true` and **no body**.
4. Anonymous focused elements produce no rows and are transparent to change detection; a **secure** field still produces its role-only `element.focused` row (MVP §6.5).
5. Readout controls (`AXSlider`, `AXProgressIndicator`, `AXValueIndicator`, `AXScrollBar`) never yield `value`.
6. An app activation produces one snapshot whose window and element agree.
7. Every focused-context event carries `extra.fingerprint`; every observer-driven one carries `extra.input` (`"user"` / `"ambient"`).
8. The notification set is configurable globally and per app; a config change re-registers the affected observers without a restart; `value ⇒ focus` is enforced.
9. Measured on a comparable dogfood window through the MCP: **rows −60 % or better, stored text bytes −35 % or better** (targets that prove the mechanism; the hard gate is the tests above, which assert nothing real is lost).
10. `make build && make test && make lint`; CI green. Raw titles and values stored unchanged — normalization only affects what is *compared and hashed*, never what is *stored*.

## 4. The two hashes (the foundation)

Everything in this slice compares identities, not raw strings. Two hashes define identity:

**Content hash — `extra.valueHash`** (exists, unchanged): SHA-256 hex of the *redacted* value. "Is this the same text?" Keys the recent-content memory (§6.3) and, later, Compact's content versions.

**Place fingerprint — `extra.fingerprint`** (new): "Is this the same thing on screen?" — the first 16 hex characters of SHA-256 over the canonical string

```
bundleID ␟ normalize(windowTitle) ␟ document ␟ urlWithoutFragment
```
(`␟` = U+001F, absent fields = empty; `urlWithoutFragment` strips `#…`; 16 hex = 64 bits, ample for one user's timeline and a third of the row bytes of a full digest). It is deliberately **place-level** — the page, document, or window — not element-level: focusing a different button on the same page must not change it. Element identity (role, subrole, identifier, element title) already lives in the dedup signature and does not belong in the grouping key. Stored on every focused-context event (`context.snapshot`, `element.focused`, `window.focused`, `window.title_changed`, `element.value_changed`). It is the grouping key Compact will use for entities and visits, so its canonical form is a **contract**: documented here, fixed by golden-hash tests, reproducible from Python if ever needed.

**Normalized comparison.** `ContextSignature.windowTitle` and `.elementTitle` hold the *normalized* titles, and `ContentCache.matches` compares normalized titles — so a flicker in a volatile part is not a change: no event, and no expensive re-read. The `RawEvent` still carries the raw title.

## 5. Title normalization (`TitleNormalizer`, pure, `Sources/Capture`)

Ordered rules, each backed by a test case from the dogfood data. The rule table is the single place volatile patterns live; adding one is a one-line change + a test.

| # | Rule | Pattern | Example |
|---|---|---|---|
| 1 | Strip a leading notification counter | `^\(\d+\)\s+` | `(86) Indiana State …` → `Indiana State …` |
| 2 | Strip status glyphs anywhere | any of `◐ ◑ ◒ ◓ ◌ ✳ ✶ ✷ ✸ ⏳ ⌛ ● ○ ◉` | `◑ Set up DGX Sparks hardware` → `Set up DGX Sparks hardware` |
| 3 | Strip Chrome tab badges | ` - Audio playing`, ` - Muted`, ` - High memory usage - [\d.,]+ [KMG]B` | `… - YouTube - Audio playing - High memory usage - 807 MB - Google Chrome - Pragan` → `… - YouTube - Google Chrome - Pragan` |
| 4 | Collapse whitespace, trim | `\s+` → ` ` | |

Deliberately *not* stripped: the app suffix (` - Google Chrome - Pragan`) — constant per window, so it never causes churn and it disambiguates profiles; ` — Edited` (a real state change); timecodes (they live in values, not titles, and §6.4 handles those elements).

## 6. The mechanism and the fixes

### 6.1 Input-gated classification
Every observer notification is classified in `Capturer.handle(change:)` by one grant-free call already on the protocol, `ax.secondsSinceLastInput()`:
- **user-driven** — input within `capture.user_input_window_seconds` (default **2.0**);
- **ambient** — otherwise: the screen changed by itself.

| kind | user-driven | ambient |
|---|---|---|
| `focusedWindowChanged`, `focusedElementChanged` | refresh now (as today) | refresh now — an app can move focus without input and that is a real state change |
| `titleChanged` | debounced refresh (the per-pid pending refresh, `value_debounce_ms`) — a navigation is several title notifications in a burst; one pending refresh per pid, and a pending **value** refresh (fresh read) subsumes a title one | **dropped** — the 5 s heartbeat samples the state and dedup collapses non-changes; a real ambient navigation (a redirect) is caught by the heartbeat as `context.snapshot`, ≤ 5 s late |
| `valueChanged` | debounced refresh with cache bypass (as today) | **dropped** — a ticking slider or timer; the heartbeat samples |
| `menuItemSelected` | emit | (inherently user-driven) |
| activation (lifecycle) | settle then refresh (§6.5) | same |

Ambient is *not* "ignore": it means "sample at heartbeat rate, not notification rate." "Watched this video 23:08–23:24" survives through the heartbeat and the app/window events; the 900 ticks in between do not. Observer-driven context events carry `extra.input: "user" | "ambient"` so the effect is measurable and consumers can tell an action from a passive state.

### 6.2 Normalized signatures and the gate
`HeartbeatDiff` builds `ContextSignature` from normalized titles (§5) and adds `fingerprint` to `extra`. `ContentCache.matches` compares normalized titles. Net effect: badge/spinner/counter flicker cannot dirty the signature or bust the cache.

### 6.3 Recent-content memory
`LastKnownState` gains a per-pid `RecentValueHashes` — a bounded list of (hash, ts): at most **32** entries per pid, entries older than `capture.content_memory_seconds` (default **1800**) pruned on insert, pids not seen within that window pruned. In `compute`:
`valueUnchanged = hash != nil && (hash == previous.signature?.valueHash || recent(pid).contains(hash, now))`.
When `valueUnchanged`, the event is emitted with `valueHash` and **no `value`** — exactly the existing `valueUnchanged` semantics, widened from "the previous state" to "recently stored". When a value *is* emitted, its hash enters the pid's memory. The text is always retrievable: it is in the store under an earlier row with the same `valueHash` (a small MCP helper to resolve hash → text is a later addition; nothing is lost).

### 6.4 Anonymous elements are transparent
An element is **anonymous** when it has no title, no identifier, no redacted value, no selected text, **and is not secure**. In `compute`, an anonymous focused element does not replace the element fields of the signature: they are carried forward from `previous.signature` when it is the same pid (else nil). So clicking an unnamed button inside a page and returning to the page produces zero rows; a click that navigates still produces its window/title row. Secure fields are excluded from the definition so the MVP §6.5 promise holds: a password field still yields its role-only `element.focused` row.

### 6.5 Readout roles
`ElementInfo.readoutRoles = {AXSlider, AXProgressIndicator, AXValueIndicator, AXScrollBar}`. `ContentExtractor.extract` and `resolveHit` return no text for these (identity still recorded). Their values are numeric readouts, not content, and they were the per-second payload of the title storm.

### 6.6 Activation settle
`handle(lifecycle: .activated)` drops pending value refreshes immediately (as today) but schedules the refresh on a single per-Capturer pending task after `capture.activation_settle_ms` (default **200**); another activation inside the window restarts it. Chrome's focused window and focused element agree by then; the mis-paired first row disappears. (Test: two activations 50 ms apart → one refresh, for the last app.)

### 6.7 Per-app notification set (the escape hatch)
```json
"capture": {
  "notifications": ["window", "focus", "title", "value", "menu"],
  "apps": { "com.cmuxterm.app": { "notifications": ["window", "focus", "menu"] } }
}
```
`window` → focused/main window changed; `focus` → focused UI element changed; `title`; `value` (on the focused element; **implies `focus`**); `menu`. The effective set for a pid = the per-app override if present, else the global default. `AXReading.startObserving` gains a `kinds:` parameter; the hub registers only those; `Capturer.handle(change:)` also ignores kinds outside the set. Reconcile compares each observed pid's registered set to its effective set and re-registers (unobserve → observe) on a difference, so a config edit applies within one heartbeat. Default is the full set — §6.1 makes hand-tuning unnecessary for the cases seen so far; this is for apps whose notifications carry no signal at all.

## 7. Config

New keys under `capture` (all optional; defaults shown; unknown keys still pass through `raw`):
`user_input_window_seconds: 2.0`, `content_memory_seconds: 1800`, `activation_settle_ms: 200`, `notifications: ["window","focus","title","value","menu"]`, `apps: { "<bundle-id>": { "notifications": [...] } }`. Constant (not config): 32 hashes per pid.

## 8. Privacy

Nothing in this slice reads anything new. Normalization and hashing operate on already-redacted values and on titles; secure fields keep their existing guard and their role-only row; readout suppression only removes reads. `secondsSinceLastInput` is a system-wide scalar — it reveals *that* input happened, never what.

## 9. Testing

- `TitleNormalizerTests`: one case per rule from §5, the "not stripped" cases (` — Edited`, app suffix), idempotence (`normalize(normalize(x)) == normalize(x)`).
- `FingerprintTests`: golden hashes for a fixed canonical string; fragment stripped; badge flicker ⇒ same fingerprint; different tab ⇒ different.
- `HeartbeatDiffTests`: badge-only title change ⇒ no event; normalized `previousTitle` semantics unchanged (raw titles stored); recent-hash ⇒ `valueUnchanged` + no body, and expiry after TTL / eviction at 32; anonymous element transparent (button click + return ⇒ 0 rows; click that navigates ⇒ 1 row); secure field still emits role-only; readout role ⇒ no value; `fingerprint` present on every context event.
- `ObserverTests` (`FakeAXClient.idleSeconds` drives `secondsSinceLastInput`): ambient title/value ⇒ no read, no row; user-driven title ⇒ one debounced row with `input: "user"`; focus always refreshes with `input` set; activation settle collapses two activations into one refresh; per-app kinds registered (`FakeAXClient` records kinds per pid), `value ⇒ focus`, config change re-registers; heartbeat still samples an ambient change as `context.snapshot`.
- `ConfigTests`: the new keys parse with defaults, round-trip, unknown keys preserved.
- Dogfood measurement (user, via the MCP): rows and bytes per hour before vs after over a comparable window; the spinner/tick rows should be gone and `input: "ambient"` rows near zero.

## 10. Modules touched

| File | Change |
|---|---|
| `Sources/Capture/TitleNormalizer.swift` | **New.** §5 rule table. |
| `Sources/Capture/Fingerprint.swift` | **New.** §4 canonical string + 16-hex SHA-256 (uses `Core.Hashing`). |
| `Sources/Capture/HeartbeatDiff.swift` | normalized signature; `fingerprint` and `input` in `extra`; recent-content memory (`RecentValueHashes`); anonymous transparency. |
| `Sources/Capture/AXTypes.swift` | `ContentCache.matches` on normalized titles; `ElementInfo.readoutRoles` / `isAnonymous`; `AXReading.startObserving(_:kinds:handler:)`. |
| `Sources/Capture/ContentExtractor.swift` | readout-role short-circuit in `extract` / `resolveHit`. |
| `Sources/Capture/Capturer.swift` | input classification; title debounce path; activation settle; effective-kinds resolution and re-registration. |
| `Sources/Capture/AXObserverHub.swift`, `AXClient.swift` | register only the requested kinds. |
| `Sources/Core/Config.swift` | §7 keys. |
| `Tests/CaptureTests/*`, `Tests/CoreTests/ConfigTests.swift` | §9. |
| `docs/accessibility-api.md`, `README.md`, `CLAUDE.md` | rule table and config documented. |

Untouched: `Store`, schema (v1), CLI output, the MCP repo.

## 11. Deferred, on purpose

Compact (entities keyed on `fingerprint`, visits, episodes, the `summary` MCP tool); an MCP hash→text resolver; per-app content depth and privacy categories; keystroke/click counts via an event tap; near-duplicate similarity (rejected).
