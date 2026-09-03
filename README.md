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
| `Sources/openrhyme` | The executable: `daemon`, `status`, `apps`, `inspect`, `events`, `export`, `version` |
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
