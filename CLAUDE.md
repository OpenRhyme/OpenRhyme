# OpenRhyme — instructions for Claude Code

## What this is

Open-source, local-first "Computer History" for macOS: a Swift daemon captures activity via the Accessibility API plus a listen-only event tap, stores it in tiered SQLite, compacts it deterministically, and a separate Python MCP server ([OpenRhyme/openrhyme-mcp](https://github.com/OpenRhyme/openrhyme-mcp), locally `../openrhyme-mcp`) exposes it to agents. Full reasoning lives in `docs/computer-history-spec.md` — read it before any design work.

## State (2026-09-01)

Workspace scaffolded, no implementation yet. Every `Sources/*/*.swift` file is a comment-only stub. **The MVP design is approved: `docs/superpowers/specs/2026-09-01-mvp-capture-engine-design.md`** — read it before implementing anything; implementation plans live in `docs/superpowers/plans/`. Decisions made after the original spec: Swift engine, own AX layer (AXorcist as reference only), MCP in Python in a separate repo, MIT, **no storage tiers in the MVP** (one `events` table).

## Non-negotiables

- **No network code in this repo.** Not for telemetry, updates, or "just fetching". If a task seems to need it, stop and say so.
- No screenshots, no audio, no raw key logging (aggregate input activity only); never read `AXSecureTextField` content.
- No bundled LLM and no inference in `Compact`. The rollup is deterministic; prose is the agent's job.
- Sessionize by activity coherence, never by fixed time windows.
- The SQLite schema and the `openrhyme … --json` output are public contracts. Change them only with a version bump and a migration.

## Layout

- `Sources/Capture` — AX observers, event tap, TCC handling, per-app quirks. Emits `Sendable` structs only; `AXUIElement` never leaves this module.
- `Sources/Store` — HOT / WARM / COLD tiers, SQLite + FTS5, migrations.
- `Sources/Compact` — pure functions: sessionization, dedup, idle drop, collapse.
- `Sources/openrhyme` — the one executable: `daemon`, `status`, `apps`, `compact`, `inspect`, `version`.
- `docs/accessibility-api.md` — request/response model, full error table, verified traps. Consult before touching `Capture`.
- `docs/engine-interface.md` — process topology and the Python ↔ engine contract.

## Commands

`make build` · `make test` · `make lint` (strict swift-format) · `make format`. CI runs the same on `macos-26`.

## Conventions

- Swift 6 strict concurrency. Keep all AX/CG calls on one dedicated run-loop thread behind a global actor.
- Swift Testing for tests. Tests touching live AX need TCC grants → gate them; never assume CI has them.
- Small, focused modules. If editing a file requires the whole spec in context, the file is too big.
- Commits: short single-line messages, no attribution trailers.
- Verify API facts against the SDK headers (`$(xcrun --show-sdk-path)/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Headers/AX*.h`) rather than memory. Constant names in the docs were taken from there.
