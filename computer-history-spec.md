# Open-Source Computer History Layer — Research & Design Notes

Working title: TBD (candidates at the end). Status: pre-implementation research.

---

## 1. What prompted this

OpenAI shipped a feature called **Computer History** in the ChatGPT macOS desktop app (August 2026). Verified details:

- Opt-in, macOS desktop app only, available to Pro / Business / Enterprise tiers.
- Captures an activity stream: clicks, typing, and text/context exposed through **macOS accessibility APIs**.
- Explicitly does **not** capture screenshots, microphone input, or system audio.
- Builds a searchable timeline plus "memories," so ChatGPT/Codex can resume prior work, find recent output, or turn repeated actions into automations.
- Widely described as OpenAI's answer to Windows Recall.

**Goal of this project:** an open-source, local-first equivalent that is *not* tied to a single vendor's assistant — any AI agent (Claude, local models, whatever) can consume the timeline.

---

## 2. Is this actually MDM? (settled)

No — different mechanism, and worth being precise since it shapes the trust story.

| | MDM | Accessibility grant |
|---|---|---|
| Who initiates | Employer, on a managed device | User, per-app |
| Revocable by user | Generally no | Yes, seconds |
| Device control (wipe, config, inventory) | Yes | No |
| **Live content** (what you typed, what's on screen) | **No** — needs a separate DLP/monitoring agent | **Yes** |

Conclusion reached: **on the data-access axis specifically, an accessibility grant is broader than MDM.** MDM is the delivery truck, not the camera. The remaining differences are coercion and reversibility.

macOS's model here is **consent-plus-friction, not capability limits**. Accessibility is all-or-nothing — no OS-level scoping to particular apps, no "menus but not text fields." Once granted, the app sees the whole UI tree. The only protection is that the dialog is alarming, the toggle is buried, and it requires authentication.

**Implication for the product:** trust is not a feature, it is the product. Everything below follows from that.

---

## 3. How the capture actually works

macOS accessibility (built for VoiceOver) exposes far more than most people assume:

- **Full UI element tree per running app** — windows, buttons, text fields, and *their contents*. By design it must be able to read out on-screen text.
- **Live notifications** — an AX client can register for `focus changed`, `window changed`, `value changed`. So you get an event stream, not just polled snapshots.
- **CGEvent taps** — keystrokes and clicks, layered on top.

Together these reconstruct *what you were doing*, not merely which app was frontmost.

Caveat: coverage is **app-dependent**. Native AppKit apps expose rich structure. Canvas-based apps, games, and custom-rendered UIs expose close to nothing.

---

## 4. Prior art

| Project | Approach | Gap |
|---|---|---|
| **OpenHistory** (`github.com/ztratar/openhistory`) | Closest direct competitor — private searchable macOS work timeline explicitly for local AI agents | Same pitch as ours; read their issue tracker first |
| **ActivityWatch** | Mature, cross-platform, local-first | App/window titles only — no content, no semantics |
| **Dayflow** | MIT, Mac only, screenshot every 10s, AI narrates the day, local storage | Vision-based, not accessibility-based; heavier |

Star counts are low across the board. Two readings: the space is genuinely early, **or** people have tried and demand isn't there yet. The Recall backlash suggests appetite is real but the trust bar is brutal. Assume the latter is a live risk.

**The pain point one of these projects names directly, and the actual hard problem:** automatic tracking captures *what happened*, not *why*. "VS Code frontmost 40 min, 6 keystroke bursts, 2 file switches" is an identical trace for (a) deep work, (b) idle scrolling, (c) waiting on a build. Any agent consuming the timeline has to disambiguate, and wrong guesses produce confidently useless summaries. **This semantic gap is where the product value sits — not in the capture.**

---

## 5. Technical obstacles (researched — expect these)

### 5.1 Electron apps ship with the AX tree disabled
Slack, VS Code, Discord, Notion, etc. build no accessibility tree by default. You must set the **undocumented `AXManualAccessibility`** attribute on the target process to force it.

- Documented only in Electron's own docs, not Apple's.
- Open Electron bug (#37465) where setting it returns `kAXErrorAttributeUnsupported`.
- Electron is most people's actual workday → this is not a corner case, it's the main case.

### 5.2 Uneven coverage and silent failure
- Qt apps, Python GUIs, OpenGL-backed apps → `kAXErrorCannotComplete`.
- There is an `apiDisabled` state to detect and handle.
- **Stale TCC permission cache after macOS updates**: the grant silently stops working until restart. Needs active detection + a retry-then-restart recovery loop, not a happy path.

### 5.3 Threading and performance
- `AXUIElement` is **not `Send + Sync`**. To query from an async runtime (tokio task, MCP server) you must wrap it manually — e.g. `struct ThreadSafeAXUIElement(Arc<AXUIElement>)` with `unsafe impl` blocks.
- Deep tree walks are slow. Aggressive polling burns CPU and battery — the classic killer for always-on trackers. Prefer AX notifications over polling wherever possible.

### 5.4 Text extraction is inconsistent
No single attribute works everywhere. Try in sequence, first non-zero return wins:

1. `AXValue` — native AppKit
2. `AXValueAttribute` — legacy WebKit
3. `AXText` — some Electron / CEF builds

Also noted (write-path, less relevant to read-only capture but worth knowing): `AXPress` on a Chrome web view returns `kAXErrorSuccess` while doing nothing — the browser's AX shim acknowledges without forwarding to Blink. Fix is a per-app bypass list + synthetic CGEvents.

---

## 6. Architecture (agreed)

Three-tier, same shape as observability tooling (Loki/Tempo pattern):

```
HOT    raw events, ~1 day, SQLite
  ↓    rollup job
WARM   session-level summaries / semantic memory
  ↓    archive
COLD   raw logs on disk, drilled into on demand, auto-cleanup
```

Agents read the warm tier by default and drill into cold only when they need specifics.

### 6.1 Rollup boundary matters more than storage
Do **not** summarize by fixed time window — it shreds a task that spans lunch. Segment by **activity coherence** (bursts of related app/file/window switches). Harder, materially better output.

### 6.2 Who does the rollup — decided
Not a bundled background LLM. Follow the **Hermes-style approach**: whatever agent the user already uses performs the rollup as a side effect of being invoked. Keeps the daemon lean, no shipped model, no background inference.

**Known failure mode:** rollup becomes usage-dependent. Two weeks away → a fortnight of unsummarized raw events, and the agent meant to compress it must first swallow all of it.

**Mitigation (this is the key design decision):** put the heavy lifting in a **deterministic, inference-free layer**:
- sessionization
- deduplication
- dropping idle stretches
- collapsing repeated events

This alone should cut volume by roughly an order of magnitude. The semantic summary then becomes a thin *optional* layer on top. If it's stale, the compacted events are still small enough to hand an agent directly.

→ **The fallback is not a bundled model. The fallback is just less prose.**

### 6.3 Retrieval
**Hybrid: full-text search over the archive + embeddings.** Not pure vector. Exact-term matching matters enormously here — filenames, error strings, function names, ticket IDs.

### 6.4 Interface
Expose over MCP so any agent can query the timeline. Open question below on whether this lands in slice one.

---

## 7. Business model (settled)

A hosted/cloud tier was considered and **rejected**.

Reasoning: the entire differentiation is privacy and vendor-independence. The moment a hosted tier ships the accessibility stream to someone's servers, it *is* the thing we positioned against. Additionally, summarization is the commodity part — the real moat is the capture layer, which is exactly the part being open-sourced.

**Decision: pure open source.** Primary return is learning (AX internals, local-first data design, sessionization) plus reputational positioning — being the open capture standard that agents plug into. Monetization can be revisited later from a stronger position if traction appears.

Honest note for future-us: individual users largely won't pay for a signed build when source is public. If revenue ever matters, the realistic path is teams/enterprise (shared timelines, retention policy, compliance), not individuals. Donations/sponsorship is not a plan — ActivityWatch has run on volunteers for years.

---

## 8. Naming

Rejected:
- **OpenThread** — Thread Group / Google's smart-home mesh networking protocol. Established, owns the org and domain. Not a legal problem (different trademark category) but a fatal *discoverability* problem.
- **OpenTrail** — crowded with hiking/GIS: `github.com/opentrail` (taken by an individual), Code for America's OpenTrails spec, OpenTrailMap, `opentraildata` org, an OSM Android hiking app. Same search-invisibility issue.
- **OpenTrailActivity** — long, and both words are hiking-tracker vocabulary.

Still open: **Cairn** (stones stacked to mark a path already walked — best metaphor fit), Retrace, Weft, Trailhead, Breadcrumb, Threadline, ContextD.

Check GitHub org + npm before committing to any of them.

---

## 9. Open questions for the build

1. **First slice** — capture daemon alone, or capture + MCP interface so an agent can query it on day one?
2. Language for the daemon — Swift (native AX, no FFI pain) vs Rust (the `accessibility` crate, cross-platform later, but the `Send + Sync` wrapping described in 5.3)?
3. Sessionization heuristics: what signals define an activity boundary? App switch? Idle threshold? File/project change? Some combination scored?
4. Per-app allowlist UX — since macOS grants all-or-nothing, the *app itself* must implement scoping, and make it legible. This is a trust surface, treat it as a first-class feature not a settings page.
5. Retention defaults and cleanup policy — what's the default cold-tier TTL?
6. How to prove local-only to a skeptical user (no network entitlement at all? auditable build?).

---

## 10. First thing to do

Read the **OpenHistory** issue tracker (`github.com/ztratar/openhistory`) before writing any code. They have already hit some subset of section 5 in production, and their open issues are the cheapest available map of this terrain.
