# OpenRhyme — semantic layer design

**Status:** proposed. Supersedes the WARM/COLD storage tiers from `docs/computer-history-spec.md` §6. The storage tiers are replaced by a companion semantic store built asynchronously over the single HOT SQLite source of truth.

**Scope:** the Swift engine (sessionize CLI command), plus the Python MCP server (hybrid search, semantic consolidation, temporal knowledge graph). This spec covers the architecture and data model; implementation plans live in `docs/superpowers/plans/`.

## 1. Why this replaces the tiered architecture

The original spec proposed three storage tiers: HOT (raw events), WARM (session summaries), COLD (archive). Rationale: reduce noise, compress history, enable long-term retrieval.

**What we learned during Part 1:**

- Raw events are cheap. SQLite handles ~100K rows per workday (~80 MB) with no pressure. At that rate, a year is ~30M rows — still comfortable in SQLite with proper indexing (`ts + id` covering index).
- Sessionization is a **query-time** or **background-index-time** problem, not a **storage** problem. No compaction pipeline needed.
- The agent brings the LLM. Deterministic sessionization heuristics are a pale substitute for what a local model can infer from 50 events in context.

**New architecture:**

```
daemon (Swift) ───writes──▶ events.sqlite (HOT, single source of truth)
                                    │
                          ┌─────────┴──────────┐
                          │                    │
                   openrhyme CLI         openrhyme-mcp (Python)
                   (read via --json)      │
                                          ├── sessionize (idle-gap, no LLM)
                                          ├── search (FTS5 + vectors + RRF)
                                          ├── consolidate (async, local LLM)
                                          │     └──▶ semantic.sqlite (companion)
                                          └── graph (entity links, optional)
```

No compaction daemon. No WARM/COLD migration logic. No extra background writer in the Swift engine. The companion `semantic.sqlite` is built by the MCP server's own background process, reading from the source of truth through the CLI.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Storage tiers | One HOT SQLite. Companion semantic store built asynchronously. | Simpler, less code, same capability. The LLM does abstraction at write time or query time — whichever the agent prefers. |
| Session boundary | Idle-gap detection. Configurable timeout (default 5 min). | Zero LLM, trivially testable, matches cognitive science (activity boundaries are pauses). |
| Search modality | Hybrid: FTS5 for exact match (filenames, errors, identifiers), dense embeddings for semantic match, RRF fusion. | Filenames and error strings are exact — embeddings miss them. Concepts and queries are semantic — FTS5 misses them. Both needed. |
| Embeddings | Apple `NLContextualEmbedding` (macOS 14+) as primary. Ollama fallback. | Free, on-device, no model download for the user. Apple silicon native. |
| Semantic store | SQLite with FTS5 + sqlite-vec. Same engine as events. | No new infra. Already proven (Memex, Kosmos, everything-search all use this stack). |
| LLM in capture path | **Never.** | Settled in the original spec. Capture is TCC-granted; an LLM adds attack surface, latency, and crash risk to the one privileged process. |
| LLM in consolidation | Yes — separate background process, no grants, reads through CLI. | The whole point. Local model (DeepSeek V4 Flash via your provider) or any Ollama model. |
| Fact supersession | Write-time: new fact with same entity+predicate marks old as superseded. | SodaMem and TSM both prove this prevents stale-fact poisoning. |
| Network | Zero. Embeddings and LLM both run locally or through your configured provider (which is already local). | Settled in the original spec. |
| Storage format | Events: existing schema, unchanged. Semantic: separate `.sqlite` in the same data dir (`~/Library/Application Support/OpenRhyme/semantic.sqlite`). | Source of truth stays pristine. Semantic store is disposable — rebuild any time from events. |

## 3. Data model

### 3.1 Sessions (engine CLI, no LLM)

A session is a contiguous block of activity with no gap longer than `idle_timeout` (default 300 s).

```sql
CREATE TABLE sessions (
    id          INTEGER PRIMARY KEY,
    start_ts    REAL NOT NULL,           -- unix seconds
    end_ts      REAL NOT NULL,
    app_count   INTEGER NOT NULL,        -- distinct bundle IDs in this session
    event_count INTEGER NOT NULL,
    bundle_ids  TEXT NOT NULL,            -- JSON array of bundle IDs
    dominant_kind TEXT NOT NULL,          -- most frequent event kind
    created_at  REAL NOT NULL            -- when sessionization ran
);
CREATE INDEX idx_sessions_start ON sessions(start_ts);
CREATE INDEX idx_sessions_end ON sessions(end_ts);
```

Derived from events via `openrhyme sessions --since <time>`. Not materialized into events.sqlite by default — the CLI command computes on read unless `--persist` is passed.

### 3.2 Semantic store (companion SQLite, built by consolidation worker)

```sql
-- Entities: projects, files, people, concepts extracted from sessions
CREATE TABLE entities (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    entity_type TEXT NOT NULL,            -- project, file, person, concept, tool, error
    first_seen  REAL NOT NULL,
    last_seen   REAL NOT NULL,
    aliases     TEXT NOT NULL DEFAULT '[]' -- JSON array: ["RunaxAI scheduler", "scheduler"]
);
CREATE INDEX idx_entities_name ON entities(name);
CREATE INDEX idx_entities_type ON entities(entity_type);

-- Facts: structured observations from a session
CREATE TABLE facts (
    id            INTEGER PRIMARY KEY,
    session_id    INTEGER NOT NULL REFERENCES sessions(id),
    entity_id     INTEGER NOT NULL REFERENCES entities(id),
    predicate     TEXT NOT NULL,          -- "was_editing", "debugged", "researched", "configured"
    object        TEXT NOT NULL,          -- the value or target
    ts            REAL NOT NULL,          -- when the fact was observed
    superseded_by INTEGER REFERENCES facts(id),   -- NULL = current, non-NULL = this fact is stale
    provenance    TEXT NOT NULL           -- JSON: {kind, event_count}
);
CREATE INDEX idx_facts_entity ON facts(entity_id);
CREATE INDEX idx_facts_session ON facts(session_id);
CREATE INDEX idx_facts_current ON facts(superseded_by) WHERE superseded_by IS NULL;

-- Session summaries (one per session, built by LLM)
CREATE TABLE session_summaries (
    session_id   INTEGER PRIMARY KEY REFERENCES sessions(id),
    summary      TEXT NOT NULL,
    embedding    BLOB,                   -- 768-dim float32 vector (sqlite-vec)
    created_at   REAL NOT NULL
);

-- Edges for optional knowledge graph
CREATE TABLE edges (
    id            INTEGER PRIMARY KEY,
    source_entity INTEGER NOT NULL REFERENCES entities(id),
    target_entity INTEGER NOT NULL REFERENCES entities(id),
    edge_type     TEXT NOT NULL,          -- "uses", "depends_on", "debugging", "related_to"
    weight        REAL NOT NULL DEFAULT 1.0,
    first_seen    REAL NOT NULL,
    last_seen     REAL NOT NULL
);
CREATE INDEX idx_edges_source ON edges(source_entity);
CREATE INDEX idx_edges_target ON edges(target_entity);

-- FTS5 virtual tables for full-text search
CREATE VIRTUAL TABLE facts_fts USING fts5(
    predicate, object,
    content='facts', content_rowid='id'
);

CREATE VIRTUAL TABLE session_summaries_fts USING fts5(
    summary,
    content='session_summaries', content_rowid='session_id'
);
```

## 4. Phases

| Phase | What | Who | LLM cost | Delivers |
|---|---|---|---|---|
| **0** | Sessionize: idle-gap detection in the engine CLI. New `openrhyme sessions` command. New MCP `sessions` tool. | Swift engine + MCP | None | Agents see activity units, not raw event logs |
| **1** | Hybrid search: FTS5 on events, embeddings via `NLContextualEmbedding`, RRF fusion. New MCP `search` tool. | MCP server only | None (on-device embeddings) | "Find me the error from last week" works |
| **2** | Semantic consolidation: background cron reads new sessions, calls local LLM to extract facts, builds semantic store. New MCP `facts` and `ask` tools. | MCP server + launchd | ~30 calls/day (workday) | Agent knows your projects, patterns, decisions |
| **3** | Knowledge graph: entity resolution, edge construction, graph traversal. New MCP `graph_traverse` tool. | MCP server | None (LLM already extracted entities in Phase 2) | Multi-hop: "What was I doing before I started debugging the scheduler?" |

Each phase is independent. Phase 0 and 1 are worth doing alone even if nothing else ships. Phase 2 is the semantic "know me" layer that makes the project transformative. Phase 3 is optional sugar on top.

## 5. MCP tool surface (final)

| Tool | Phase | Input | Returns |
|---|---|---|---|
| `events()` | ✅ (existing) | `since`, `until`, `kinds`, `app`, `limit`, `max_value_chars` | Raw events |
| `status()` | ✅ (existing) | — | Engine + MCP status |
| `apps()` | ✅ (existing) | — | Allowlist + running apps |
| `allow_app()` / `deny_app()` | ✅ (existing) | `bundle_id` | — |
| `sessions()` | 0 | `since`, `until`, `app`, `limit` | Activity session list |
| `search()` | 1 | `query`, `since`, `kinds`, `app`, `limit` | Ranked event results with relevance scores |
| `facts()` | 2 | `query`, `since`, `entity`, `limit` | Structured facts from the semantic store |
| `ask()` | 2 | `query` | RAG over semantic store: summary answer with citations |
| `graph_traverse()` | 3 | `entity`, `hops`, `edge_types` | Subgraph of related entities + edges |

## 6. Privacy & trust boundaries

- **Sessionization** runs on the user's machine, no network, no model.
- **Embeddings** use Apple's on-device model (macOS 14+). Falls back to Ollama localhost. No data leaves the machine.
- **Semantic consolidation** calls a local LLM. The user configures the provider (DeepSeek, Ollama, etc.) in the MCP server's config. Same model they already use for everything else.
- **The semantic store is disposable.** Delete `semantic.sqlite` and re-consolidate from scratch. The source events are never modified.
- **Supersession** prevents factual drift. If the LLM extracts "working on RunaxAI scheduler" in session A and "paused scheduler, working on auth module" in session B, the first fact is superseded. An agent reading the semantic store sees the current state.

## 7. Risks

| Risk | Mitigation |
|---|---|
| LLM hallucinates facts from events | Every fact carries `session_id` — agent can drill to raw events with `events()` and verify. |
| Embedding quality suffers on short/noisy AX text (URLs, single words) | FTS5 catches exact strings. Hybrid search means one modality backs the other. |
| `NLContextualEmbedding` unavailable (macOS < 14 or pre-download) | Fallback to Ollama embedding model. Configurable. |
| Semantic store grows unbounded | Supersession prunes stale facts at write time. Periodic compaction (reindex FTS5, vacuum). Disposable by design — delete and rebuild. |
| User has no local LLM | Phase 0 and 1 need no LLM. Phase 2 requires one — same requirement as every other personal AI tool. The agent host (Claude, etc.) already provides one. |