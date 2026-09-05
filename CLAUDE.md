# OpenRhyme — instructions for Claude Code

## What this is

Open-source, local-first "Computer History" for macOS: a Swift daemon captures activity via the Accessibility API plus a listen-only event tap and stores it in one SQLite events table, and a separate Python MCP server ([OpenRhyme/openrhyme-mcp](https://github.com/OpenRhyme/openrhyme-mcp), locally `../openrhyme-mcp`) exposes it to agents. Original reasoning lives in `docs/computer-history-spec.md`; its §6 storage tiers are **superseded** by `docs/superpowers/specs/2026-09-04-semantic-layer-design.md`. Read both before any design work, and `docs/superpowers/specs/2026-09-03-privacy-controls-design.md` before touching anything that reads, writes or deletes captured content.

## State (2026-09-04)

Part 1 of the MVP plan is implemented: Core, Store, CLI (`daemon`, `status`, `apps`, `inspect`, `events`, `export`, `version`) and heartbeat capture. Opaque-app detection remains Part 2 (`docs/superpowers/plans/`). **The MVP design is approved: `docs/superpowers/specs/2026-09-01-mvp-capture-engine-design.md`** — read it before implementing anything; implementation plans live in `docs/superpowers/plans/`. Decisions made after the original spec: Swift engine, own AX layer (AXorcist as reference only), MCP in Python in a separate repo, MIT, **no storage tiers in the MVP** (one `events` table). Content extraction (deep AX text into `value`, with `extra.textSource`) landed on top of Part 1. Observers (event-driven capture: `AXObserver` + `NSWorkspace` lifecycle, debounced value changes, menu selections, Electron enabling) landed on top. Capture noise reduction (normalized-title fingerprints, input-gated notifications, recent-content memory, configurable notification set) landed on top. Privacy controls (never-capture rules, secret redaction, purge/retention, owner-only store, MCP reads through the CLI) landed on top. **The storage tiers are retired** — one events table, plus a proposed companion semantic store built by the Python worker (`docs/superpowers/specs/2026-09-04-semantic-layer-design.md`, not yet implemented).

## Non-negotiables

- **No network code in this repo.** Not for telemetry, updates, or "just fetching". If a task seems to need it, stop and say so.
- No screenshots, no audio, no raw key logging (aggregate input activity only); never read `AXSecureTextField` content.
- **No bundled LLM and no inference anywhere in this repo.** The capture path and the whole Swift engine stay inference-free: the daemon holds the Accessibility grant, and the one privileged process does not get a model bolted to it. The consolidation worker in the separate Python repo may call a local model — that is where prose happens. This rule is about *this* repo's processes, not about whether the project ever uses an LLM.
- Sessionize by activity coherence, never by fixed time windows. Idle-gap detection satisfies this — a gap is a property of the activity stream, not a calendar boundary; hourly/daily buckets are what the rule forbids. Reasoning in the semantic layer design §11.1.
- The SQLite schema and the `openrhyme … --json` output are public contracts. Change them only with a version bump and a migration.

## Layout

- `Sources/Capture` — AX observers, event tap, TCC handling, per-app quirks. Emits `Sendable` structs only; `AXUIElement` never leaves this module.
- `Sources/Store` — one SQLite `events` table (schema v1) plus `meta`; migrations, delete/vacuum/checkpoint. No tiers, no FTS5.
- `Sources/Compact` — **retired placeholder.** One comment file, an empty test target, still wired into `Package.swift`. Its job (sessionization, dedup, idle drop, collapse) is superseded by the semantic layer design; do not build on it.
- `Sources/openrhyme` — the one executable: `daemon`, `status`, `apps`, `inspect`, `events`, `export`, `purge`, `privacy`, `version`.
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
