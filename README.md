# OpenRhyme

An open-source, local-first **computer history layer for macOS** — a daemon that turns what you do on your Mac into a private, searchable timeline that *any* AI agent can read.

> **Status:** Part 1 of the MVP is implemented — the capture daemon and the `openrhyme` CLI. The [MCP server](https://github.com/OpenRhyme/openrhyme-mcp) is also implemented. The original WARM/COLD storage tiers are superseded by the [semantic layer design](/docs/superpowers/specs/2026-09-04-semantic-layer-design.md): a companion semantic SQLite built asynchronously by a local LLM over the single HOT source of truth.

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
 │                                                                             │
 │  Capture ──raw events──▶ events.sqlite (single source of truth)            │
 │  AX observers,           searchable by CLI --json                           │
 │  listen-only event tap                                                      │
 └──────────────────────────────────┬──────────────────────────────────────────┘
                                    │  SQLite read-only  +  `openrhyme … --json`
                                    ▼
                   openrhyme-mcp  (Python, github.com/OpenRhyme/openrhyme-mcp)
                    │
                    ├── sessions (idle-gap, no LLM)
                    ├── search (FTS5 + vectors + RRF, on-device)
                    ├── consolidate (async, local LLM → semantic.sqlite)
                    └── ask (RAG over semantic store + raw events)
```

Key design choices (reasoning in the spec and the [semantic layer design](/docs/superpowers/specs/2026-09-04-semantic-layer-design.md)):

- **One HOT source of truth.** No WARM/COLD storage tiers. SQLite handles ~100K events/day with no pressure. A companion semantic store is built asynchronously by a local LLM, always rebuildable from the raw events.
- Session boundaries follow **activity coherence** (idle-gap detection), not fixed time windows.
- **No bundled LLM.** The capture daemon never calls a model. LLM work happens in a separate consolidation worker (launchd agent, no TCC grants) that reads through the CLI, same as every other consumer.
- Retrieval is **hybrid**: FTS5 for exact terms + dense embeddings for semantic match, fused by Reciprocal Rank Fusion.

## Repository layout

| Path | What |
|---|---|
| Path | What |
|---|---|---|
| `Sources/Capture` | Accessibility + input-activity capture (macOS only) |
| `Sources/Store` | SQLite event store; the schema is the contract other processes read |
| `Sources/openrhyme` | The executable: `daemon`, `status`, `apps`, `inspect`, `events`, `export`, `sessions`, `version` |
| `Tests/*` | One test target per module |
| `docs/computer-history-spec.md` | The original research & design spec |
| `docs/superpowers/specs/2026-09-04-semantic-layer-design.md` | The semantic layer design (supersedes WARM/COLD) |
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

## What's next

The capture daemon and MCP server are built. The semantic layer adds retrieval and reasoning:

| Phase | What | LLM cost | Delivers |
|---|---|---|---|
| **0** | Sessionize — idle-gap detection, `openrhyme sessions` CLI, MCP `sessions` tool | None | Agents see activity units, not raw logs |
| **1** | Hybrid search — FTS5 + on-device embeddings + RRF, MCP `search` tool | None | "Find the error from last week" works |
| **2** | Semantic consolidation — background LLM extracts facts/summaries, MCP `facts`/`ask` | ~30 calls/day | Agent knows your projects, patterns, decisions |
| **3** | Knowledge graph — entity resolution, edge derivation, BFS traversal | None (reuses Phase 2) | Multi-hop: "What was I doing before debugging X?" |

Details in the [semantic layer design](docs/superpowers/specs/2026-09-04-semantic-layer-design.md) and the implementation plans under `docs/superpowers/plans/`.

## Prior art

| Project | Approach | Gap |
|---|---|---|
| [OpenHistory](https://github.com/ztratar/openhistory) | Swift collector + Electron UI, hourly/daily summaries for local agents | Closest competitor; single-app shape |
| [ActivityWatch](https://activitywatch.net) | Cross-platform, local-first | App/window titles only, no content |
| Dayflow | Screenshot every 10 s, AI narrates the day | Vision-based, heavier |

## License

MIT — see [LICENSE](LICENSE).
