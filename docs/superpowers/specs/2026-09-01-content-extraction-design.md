# Deep AX content extraction — design

**Status:** approved design, 2026-09-01. First post-MVP slice.
**Scope:** the Swift engine `Capture` module only. **No storage-schema change (stays v1), no change to the MCP repo.**
**Builds on:** `docs/superpowers/specs/2026-09-01-mvp-capture-engine-design.md` (§6.4 text extraction, §6.5 redaction, §6.2 heartbeat) and `docs/accessibility-api.md` (§3–4 the AX request/response model, error table, text-attribute traps).

## 1. Problem

Today a captured event's `value` is read only from the **focused element's own** `kAXValue`. For native text fields/areas that is the text; for a browser web area, a scroll group, or most container elements it is empty. Result: the timeline records *where* you were (app, window title, URL) but not *what was on the screen* — verified in a live capture where every Chrome `context.snapshot` had `value: ""` while the page URL and title came through fine.

**Goal:** capture the readable **on-screen text** of the focused element — the visible page body, document text, message body — for **every allowlisted app**, driven by what the Accessibility tree exposes, not by any per-app special-casing. Maximal-but-bounded: grab the visible content and let a later compaction layer trim it; do not prematurely optimise for a "clean" answer we cannot yet define.

## 2. Non-goals

- **No new content column / schema v2.** The content reuses the existing `value` field, so the store stays schema v1 and the MCP server (which refuses a newer schema than it understands) needs **no** update. Rationale: the engine and MCP are run together by a solo developer; bumping the engine to v2 without simultaneously updating and reinstalling the MCP server would make the MCP refuse to serve. A dedicated `content` column is a viable later slice once that coupling is worth paying.
- **No full-window harvest** (every toolbar/sidebar/button label). We read the *content* element's text, not the entire window tree — that would be thousands of main-thread IPC round-trips per capture and mostly chrome noise. Widening toward it is a later slice if `textSource` telemetry (below) shows we are missing wanted content.
- **No browser extension / AppleScript / DOM read** (that is a later, separate slice, justified only if AX proves insufficient — which this slice measures).
- **No observers, no `record_other_apps`, no breadth change to the allowlist.** Capture remains opt-in per app; "whole machine" means "every app you `apps allow`."

## 3. Success criteria

1. With TextEdit, Notes, Preview, Safari and Chrome allowlisted and a few minutes of use, `openrhyme events --since 10m` shows `context.snapshot` rows whose `value` carries real on-screen text (document body, page body, message body) — not just when the element is a native text field.
2. Every content-bearing event carries `extra.textSource` ∈ {`value`, `range`, `subtree`}, so a query over a day reveals which extraction rung each app exercised (the built-in experiment that tells us whether a browser extension is later needed).
3. A password field's value never appears in any `value` — including when it sits inside a harvested subtree.
4. Daemon CPU stays within the MVP's ~2 % average target on text-heavy pages; no capture stalls a hung app beyond the messaging timeout.
5. `make build && make test && make lint` pass; CI green. New unit tests cover the extraction ladder, bounds, dedup and secure-skip via the fake AX client; one gated live-AX test confirms real extraction and records the `textSource` observed.

## 4. The extraction ladder

`AXClient.readElement(_:)` gains a content step. After reading the identity bundle (role/subrole/identifier/title) and returning early for a secure field (unchanged), it fills `value` from the first rung that yields non-empty text:

1. **Own value** — `kAXValue` (and the numeric-as-string / `kAXStaticText` description fallbacks already present). Native text fields and areas. Unchanged behaviour.
2. **Visible ranged text** — if rung 1 is empty and the element advertises `kAXVisibleCharacterRangeAttribute`: read that range, then read `kAXStringForRangeParameterizedAttribute` with it → the on-screen substring in ~2 IPC calls. Covers text views and WebKit `AXWebArea`.
3. **Bounded subtree harvest** — if rungs 1–2 are empty and the element has children: walk the subtree collecting the text of `AXStaticText` / `AXHeading` / `AXLink` / `AXButton` nodes, concatenated with newlines, in document order. Covers Chromium web areas and any container with a text tree. Reuses the existing `AXClient+Inspect` walk shape.

`extra.textSource` records which rung produced the value (`"value"` / `"range"` / `"subtree"`); absent when no text was found. When rung 1 fires, behaviour and output are byte-identical to today. A secure focused element returns before rung 1 (unchanged), so it carries neither `value` nor `textSource`.

### 4.1 New AX primitives
Two helpers on `AXClient`, both over the C API already wrapped elsewhere in the file:
- `visibleCharacterRange(_ element) -> TextRange?` — `AXUIElementCopyAttributeValue(kAXVisibleCharacterRangeAttribute)`, unboxed via `AXValueGetValue(.cfRange)` (the existing `range(_:)` helper handles the unbox).
- `stringForRange(_ element, _ range: TextRange) -> String?` — `AXUIElementCopyParameterizedAttributeValue(kAXStringForRangeParameterizedAttribute, AXValue(cfRange))`. This is the one genuinely new call shape (parameterized attribute); it returns `kAXErrorParameterizedAttributeUnsupported` on elements that do not support it, which maps (via the existing `check`) to "fall through to the next rung," not an error.

### 4.2 Subtree harvest bounds
- **Node budget** — a walk-wide counter (default 1500) decremented per visited node; the walk stops when it hits zero. Prevents a giant page from producing an unbounded walk.
- **Depth is unbounded within the budget** (web text can be deep), but the budget caps total work.
- **Byte cap** — the harvester stops accumulating once it reaches `capture.max_value_bytes` (existing 512 KB default) so it never builds an unbounded string; `Redaction.apply` remains the *authoritative* cap on the final `value` and sets `extra.truncated`/`extra.length` exactly as it does today. The harvester's early stop is a performance guard, not a second policy.
- **Messaging timeout** — the global 0.25 s `AXUIElementSetMessagingTimeout` already set at daemon start bounds every read, so a hung app cannot stall the harvest.

## 5. Redaction / privacy

The MVP's secure-field rule extends per node:
- The focused element itself: `isSecure` short-circuit before any content read (unchanged).
- The subtree harvester: **skip any node whose subrole is `AXSecureTextField`** — never read its value or descend for its text. So harvesting a login page's visible text can never include the password. (Ranged reads of a web area do not include password characters, which render as dots.)
- Everything harvested still flows through `Redaction.apply` (secure-skip at the element level, byte cap, truncation flag) before it lands in `value`.

## 6. When the *expensive* extraction runs (the gate that protects §3.4)

Rung 1 (own `value`) is a cheap single read; rungs 2–3 (ranged read, subtree harvest) are the expensive part, and on a browser rung 1 is always empty, so **without a gate rungs 2–3 would fire on every 5 s heartbeat over a full page — pegging a core and draining battery.** The MVP's existing dedup does *not* prevent this: it stops re-*storing* an unchanged event, but the read still happens before the diff. So this slice adds a real gate around the expensive rungs, keyed on the cheap fields that are already read anyway.

**Two-phase read, inside `focusedContext` (where the `AXUIElement` lives, so nothing non-`Sendable` crosses the boundary):**
1. Read the cheap identity: window title/document/url and the focused element's role/subrole/identifier/title (attributes already read today).
2. Compare those cheap fields to a small `Sendable` cache passed in by the `Capturer` (the previous heartbeat's cheap identity plus its resulting `value`/`textSource`). If they are **unchanged**, reuse the cached `value`/`textSource` and skip rungs 2–3 entirely. If **changed**, run the ladder (rung 1, then 2/3 as needed) and return the fresh content.

So on a static page the expensive harvest runs **once per focus/navigation**, and every subsequent heartbeat is just the cheap identity read + a cache hit — which keeps the daemon within the ~2 % CPU budget on text-heavy pages. `HeartbeatDiff`'s hashing/dedup is unchanged and still collapses the unchanged snapshots downstream; this gate is the *upstream* protection the dedup cannot provide.

No change to the observer path (there is none yet) or to `record_other_apps`.

## 7. Modules touched

| File | Change |
|---|---|
| `Sources/Capture/AXClient.swift` | `readElement` content ladder; `visibleCharacterRange`, `stringForRange`, and a `harvestText(element, budget, maxBytes)` helper (subtree, secure-skip). |
| `Sources/Capture/AXTypes.swift` | `ElementInfo` gains `textSource: String?` (nil when no text). New `Sendable` struct `ContentCache { windowTitle, document, url, role, subrole, identifier: String?; value: String?; textSource: String? }`. `AXReading.focusedContext(of:)` gains a parameter → `focusedContext(of:reusing: ContentCache?)`, so the caller supplies the previous cheap-identity + content and the read skips rungs 2–3 on a cache hit (§6). The fake implements the same signature. |
| `Sources/Capture/Redaction.swift` | No change to the cap logic; it already caps `value`. Confirm `textSource` is carried through unchanged. |
| `Sources/Capture/Capturer.swift` | Hold the last `ContentCache` (per focused pid) and pass it into `focusedContext(of:reusing:)` each heartbeat; update it from the returned context. |
| `Sources/Capture/HeartbeatDiff.swift` | Put `textSource` into the emitted event's `extra` when present. Signature/hash logic unchanged (still hashes the redacted `value`). |
| `Tests/CaptureTests/FakeAXClient.swift` | Scriptable subtree + ranged-text responses so the ladder is testable without a grant. |
| `Tests/CaptureTests/*` | New tests (§8). |
| `Sources/Capture/AXClient+Inspect.swift` | Optionally reuse the harvest helper; `inspect` may surface `textSource` too (nice-to-have, not required). |

The `Store`, CLI, and MCP repo are untouched: `value` and `extra` are existing columns/fields; `textSource` rides inside `extra` (JSON), which the store, JSONL export and MCP already pass through verbatim.

## 8. Testing

- **Ladder (fake AX):** focused element with own value → `textSource == "value"`, output unchanged from today. Empty value + supported ranged read → `"range"`, value is the ranged string. Empty value + no ranged support + text subtree → `"subtree"`, value is the concatenated node text. Empty everywhere → `value == nil`, no `textSource`.
- **Bounds:** a subtree exceeding the node budget stops at the budget and sets no crash; harvested text exceeding `max_value_bytes` is truncated with `extra.truncated == true` and `length` = full byte count.
- **Secure-skip:** a subtree containing an `AXSecureTextField` node (with a value) → that value never appears in the harvested `value`; a focused secure field itself → `value == nil` (unchanged).
- **Gate:** two heartbeats with an unchanged cheap identity → the expensive harvest (ranged/subtree read) runs **once**; the second heartbeat is a cache hit (assert the fake's harvest/subtree call count does not increase, and the reused `value`/`textSource` match).
- **Dedup:** two heartbeats over the same harvested page → one event (unchanged hash).
- **Live (gated `OPENRHYME_LIVE_AX=1`, never CI):** read a real TextEdit document (expect `textSource == "value"`, the doc text) and a real Chrome page (expect `"range"` or `"subtree"` and non-empty text), and print the observed `textSource` per app — the manual evidence for the browser-extension decision.

## 9. What this measures (the built-in experiment)

Because every content event records `extra.textSource`, a day of capture answers the open question directly:
- Mostly `range`/`subtree` with good text for Chrome → **AX is sufficient; no browser extension needed.**
- Chrome yields `textSource` absent or thin `subtree` text → **the Tier-2 browser extension (a later slice) is justified**, and we have the evidence rather than a guess.

This is why the slice ships before any extension work: it is the cheapest way to learn whether the extension is needed at all.

## 10. Deferred, on purpose

Dedicated `content` column (schema v2), full-window harvest (all chrome text), browser extension / AppleScript readers, observers, `record_other_apps` breadth, window-title normalisation — each a later, separately-specced slice.
