# Engine interface: how the Python MCP server drives the Swift engine

Status: research notes, 2026-09-01. Nothing here is implemented. This answers two questions that came up while scoping the split into an "engine" repo (this one, `OpenRhyme/OpenRhyme`, Swift) and an "MCP" repo (Python, also under the `OpenRhyme` org): *how does Python call a Swift program at all*, and *what should the boundary look like*.

## 1. Three processes, not two

| Process | Lifetime | Who starts it | Needs TCC grants? | Role |
|---|---|---|---|---|
| `openrhyme daemon` | always-on | `launchd` user agent (or the user, during dev) | **yes** — Accessibility + Input Monitoring | capture → HOT tier; runs `Compact` on a schedule |
| `openrhyme <subcommand> --json` | one shot | anyone (the MCP server, a shell, a cron) | no (talks to the daemon's data, not to apps) | control + inspection |
| `openrhyme-mcp` (Python) | per agent session | the agent host (Claude Desktop, Claude Code, …) over **stdio** | no | exposes tools/resources to the agent |

Why the MCP server cannot *be* the capture process, even though "one process the agent spawns" sounds simpler:

1. **It only runs while an agent is talking to it.** Capture has to run all day, including when no agent is open.
2. **TCC identity is per process.** If Python loaded Swift code in-process (a dylib via `ctypes`), the *Python interpreter* would be the thing that needs the Accessibility grant — and every Python/venv path would be a different identity. The daemon is the single, stable identity that holds the grants.
3. **Crash isolation.** A hung app stalling an AX call must not stall an agent's tool call, and vice versa.

So the daemon is a separate long-lived process either way; the only real question is how the Python side talks to it.

## 2. How Python calls a Swift program

There is no bridging library, and none is needed. A Swift executable is an ordinary Mach-O binary; Python runs it with the standard library:

```python
import json, subprocess

out = subprocess.run(["openrhyme", "status", "--json"], capture_output=True, text=True, check=True)
status = json.loads(out.stdout)
```

or, inside an async MCP server, `asyncio.create_subprocess_exec(...)`. That *is* "standard input/output, calling the process itself". The options, compared:

| Option | Mechanism | Pros | Cons | Verdict |
|---|---|---|---|---|
| **A. One-shot CLI, JSON on stdout** | `subprocess.run([...,"--json"])` | trivial, stateless, testable from a shell, no protocol to design | ~50–150 ms process spawn per call; not for streaming | **use for control/status/inspection** |
| **B. Long-lived subprocess, JSON-lines over stdin/stdout** | spawn `openrhyme serve --stdio` once; one JSON object per line each way | low latency, can stream, still stdio | you are designing and maintaining a bespoke RPC protocol (framing, ids, errors, lifecycle, reconnect) — a mini-MCP under MCP | keep in reserve; add only if A + C prove too slow |
| **C. Read SQLite directly** | Python `sqlite3` opens the store read-only (`file:…?mode=ro`, WAL) | zero IPC, zero protocol, FTS5 queries straight from Python, works even when the daemon is stopped | the schema becomes the API and must be versioned; two writers must never happen (Python stays read-only) | **use for all queries** |
| D. In-process dylib (`@_cdecl` + `ctypes`) | Python loads a Swift `.dylib` | no process boundary | TCC identity problem (§1), crash coupling, ABI upkeep | rejected |
| E. Unix domain socket / XPC / HTTP | daemon listens, Python connects | proper long-lived channel | XPC is not reachable from Python; HTTP was explicitly rejected; a Unix socket is fine but is option B with extra steps | rejected for now |

**Recommendation: A + C.** The daemon is the only writer. The Python MCP server reads the SQLite tiers directly for timeline/search tools and shells out to the CLI for anything that needs the engine's logic or state (status, allowlist changes, forcing a compaction, version/schema checks). If a streaming or sub-10 ms path is ever needed, option B is a `serve --stdio` subcommand away and the JSON shapes from A carry over.

This mirrors the architecture the spec already chose: "agents read the warm tier by default" (§6) — the warm tier *is* a SQLite file.

## 3. The contract (sketch — to be finalised with the first slice)

### 3.1 Command surface

```
openrhyme daemon                     run capture in the foreground (launchd keeps it alive)
openrhyme status   --json            trust state, capture health per app, tier sizes, last compaction
openrhyme apps     --json            allowlist: list / allow <bundle-id> / deny <bundle-id>
openrhyme compact  --json            run the deterministic rollup now; reports rows in/out
openrhyme inspect  --json            AX attributes of the focused element (developer tool)
openrhyme version  --json            {"engine": "0.1.0", "schema": 1}
```

### 3.2 JSON envelope

```json
{"ok": true,  "data": { … }}
{"ok": false, "error": {"code": "not_trusted", "message": "Accessibility permission missing", "hint": "…"}}
```

- One object on stdout; diagnostics on stderr; exit code `0` on `ok`, non-zero otherwise.
- Error `code`s are stable strings, not Swift error descriptions — the Python side branches on them.
- `version --json` is the handshake: the MCP server refuses to start if `schema` is newer than it understands.

### 3.3 Store location and files

```
~/Library/Application Support/OpenRhyme/
  hot.sqlite        raw events, WAL mode, ~1 day
  warm.sqlite       sessions + summaries, FTS5 virtual tables
  cold/             archived raw-event files, auto-cleaned by TTL
  config.json       allowlist, retention, feature flags
```

Python opens `warm.sqlite` (and `hot.sqlite` for "what am I doing right now") with `sqlite3.connect("file:…?mode=ro", uri=True)`. WAL mode makes concurrent reader + single writer safe without coordination.

### 3.4 What is public and what is not

Public (versioned, documented, tested): the SQLite schema, the CLI subcommands and their JSON, the store paths, `config.json`. Not public: any Swift module API. The Python repo depends only on the public surface, which is why the two repos can be released independently.

## 4. Locating the binary from Python

In order of preference:

1. `OPENRHYME_BIN` environment variable (dev override).
2. `openrhyme` on `PATH` — the intended install path is a Homebrew formula.
3. Later, optionally, a wheel that bundles the signed binary (the `ruff`/`maturin` pattern) — only if the Homebrew path proves too much friction.

## 5. The Python side, for orientation

The official MCP Python SDK is at v2 (`pip install mcp`, class `MCPServer`, formerly `FastMCP`); `mcp.run()` defaults to stdio, which is what Claude Desktop / Claude Code expect. The server is a thin mapping:

| MCP tool / resource | Backed by |
|---|---|
| `timeline(since, until)` | `SELECT` on `warm.sqlite` sessions |
| `search(query)` | FTS5 `MATCH` on `warm.sqlite` (+ embeddings later) |
| `now()` | `hot.sqlite`, last N minutes |
| `status()` | `openrhyme status --json` |
| `allow_app(bundle_id)` / `deny_app(bundle_id)` | `openrhyme apps … --json` |
| `compact()` | `openrhyme compact --json` |

That server has no capture logic, no TCC involvement, and no privileged identity — which is exactly what makes it safe to let any agent host spawn it.

## Sources

- MCP Python SDK v2 release notes — https://github.com/modelcontextprotocol/python-sdk/releases
- MCP SDK tiers (Swift SDK is Tier 3; Python is Tier 1) — https://modelcontextprotocol.io/docs/2026-07-28/sdk
- TCC identity is the code-signing requirement (csreq/cdhash) — https://docs.mumbli.app/for-developers/accessibility-permissions , https://evoleinik.com/posts/macos-dev-signing-preserve-permissions/
- OpenHistory (Swift collector + separate UI/agent layer, the same split) — https://github.com/ztratar/openhistory
