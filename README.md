# OpenRhyme

An open-source, local-first **computer history layer for macOS** — a daemon that turns what you do on your Mac into a private, searchable timeline that *any* AI agent can read.

> **Status:** pre-implementation. The design is settled ([spec](docs/computer-history-spec.md)), the workspace is scaffolded, and no capture code exists yet.

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
| `Sources/openrhyme` | The executable: `daemon`, `status`, `apps`, `compact`, `inspect`, `version` |
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

Running the daemon locally needs two grants — **Accessibility** and **Input Monitoring** — and ad-hoc-signed builds lose them on every rebuild. Read `docs/accessibility-api.md` §2 before trying.

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
