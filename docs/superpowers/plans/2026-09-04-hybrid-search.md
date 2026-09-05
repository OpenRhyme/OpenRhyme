# Hybrid search — Phase 1 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md`
**Status:** proposed implementation plan.

## Goal

Make raw events searchable by meaning, not just filterable by time/app/kind. An agent can ask "find me the thing about the scheduler crash" and get the right events, even when the query doesn't contain the exact words in the event text.

## What changes

### Engine (Swift) — no changes

The engine's events table is already indexed by `(ts, id)`. For Phase 1, the MCP server builds its own indexes over the existing events database, read-only. No engine modifications needed.

### MCP server (Python) — new search capability

**New tool: `search(query, since=None, until=None, kinds=None, app=None, limit=20, mode="hybrid")`**

```json
{
  "results": [
    {
      "event": { /* full RawEvent */ },
      "score": 0.87,
      "method": "hybrid"   // "semantic", "lexical", or "hybrid"
    }
  ],
  "count": 1
}
```

**Architecture within the MCP server:**

```
search(query) ──▶ [FTS5 search over event values]
               ──▶ [Vector search over embedding index]
                    │
                    └──▶ RRF fusion ──▶ ranked results
```

**Embedding provider:**

Primary: Apple `NLContextualEmbedding` via a subprocess call to a tiny Swift helper that imports the `NaturalLanguage` framework.

Why not Python? Apple's NL framework is Swift/ObjC only. A Python FFI bridge exists but breaks on every macOS update. A 20-line Swift helper that reads stdin, embeds, writes stdout is more reliable.

Fallback: Ollama `nomic-embed-text` via HTTP on localhost. Configured in the same config file as everything else.

```python
# config.py addition
@dataclass(frozen=True)
class SearchSettings:
    embedder: str = "apple"  # "apple" or "ollama"
    ollama_endpoint: str = "http://localhost:11434"
    ollama_model: str = "nomic-embed-text"
    fts5_enabled: bool = True
    vector_enabled: bool = True
    rrf_k: int = 60  # RRF constant
```

**Index building (one-time + incremental):**

On MCP server startup:
1. Check if the events database has an FTS5 index on `value` and `window_title`
2. If not, create it: `CREATE VIRTUAL TABLE events_fts USING fts5(value, window_title)`
3. Check if a vector index exists (`sqlite-vec` table)
4. If not, build one: iterate events, embed each `value`, store vector + event_id

Incremental: on each call, check for unindexed events (by `id`). Embed and index any new ones.

```python
async def _ensure_indexes(settings: Settings):
    conn = open_readonly(settings.db_path)
    # FTS5 — can create on a read-only connection? No. Need the engine to create it, or
    # the MCP server to open read-write for index creation only.
    # Design decision: the engine creates the FTS5 index on daemon startup.
    # The MCP server only uses it.
```

**Design decision:** The engine (`openrhyme daemon`) creates the FTS5 index on startup, as a one-time migration. The MCP server reads it. This avoids giving the MCP server write access to the events database.

**Search flow:**

```python
def _hybrid_search(query: str, limit: int) -> list[SearchResult]:
    query_embedding = _embed(query)

    # Channel 1: FTS5
    fts5_results = conn.execute("""
        SELECT e.*, rank
        FROM events_fts f
        JOIN events e ON e.rowid = f.rowid
        WHERE events_fts MATCH ?
        ORDER BY rank
        LIMIT ?
    """, (query, limit * 2))

    # Channel 2: Vector
    vec_results = conn.execute("""
        SELECT e.*, distance
        FROM vec_events v
        JOIN events e ON e.id = v.event_id
        ORDER BY vec_distance_cosine(v.embedding, ?)
        LIMIT ?
    """, (query_embedding, limit * 2))

    # Fuse with RRF
    fused = reciprocal_rank_fusion(fts5_results, vec_results, k=60)
    return fused[:limit]
```

**Implementation files (new or modified in MCP repo):**

| File | What | Lines |
|---|---|---|
| `src/openrhyme_mcp/embed.py` | Embedding abstraction: Apple helper subprocess + Ollama fallback | ~100 |
| `src/openrhyme_mcp/search.py` | Hybrid search: FTS5 + vector + RRF | ~150 |
| `src/openrhyme_mcp/server.py` | New `search()` tool | ~30 |
| `src/openrhyme_mcp/config.py` | `SearchSettings` dataclass | ~15 |
| `tests/test_search.py` | Fixture DB with known events, assert results | ~120 |

**Test strategy:**
- Create fixture events.sqlite with known values ("scheduler crash error", "reading about memory systems", "installing brew packages")
- Index with FTS5 + sqlite-vec
- Search "crash in scheduler" → assert `method: "hybrid"` and rank 1 contains "scheduler crash"
- Search "brew install" → assert `method: "lexical"` (FTS5 rank higher than vector)
- Rebuild index from scratch → assert no duplicate rows

## Acceptance criteria

1. `openrhyme-mcp` with `--search` enabled builds FTS5 and vector indexes on startup.
2. `search("what was that error about the scheduler")` returns the right event from a known fixture.
3. `search("install brew stuff")` returns events with "brew" or "install" even when the vector embedding is weak.
4. No engine changes required. MCP server does everything through the existing CLI + read-only SQLite.
5. Embedding provider is configurable (`apple` / `ollama`).
6. Test suite covers: exact-match, semantic-match, hybrid, empty results, missing db, unindexed db.

## Dependencies

| Dep | Why | New in OpenRhyme |
|---|---|---|
| `sqlite-vec` | Vector ANN index in SQLite | Yes — Python package, added to `pyproject.toml` |
| Swift helper binary | Apple `NLContextualEmbedding` | Yes — tiny SwiftPM target in the engine repo, or a standalone file shipped with the MCP server |
| `httpx` | Ollama API calls (fallback) | Already a dep or very small; add to `pyproject.toml` |

## Risks

| Risk | Mitigation |
|---|---|
| FTS5 index requires write access to events.sqlite | Engine creates it on daemon startup. Engine already has write access. |
| sqlite-vec extension not loadable in Python | It's a loadable extension. Test in CI. Fallback: pure Python KNN over numpy. |
| Apple embedder helper binary not built | Fallback to Ollama. MCP server logs a warning. |
| Embedding dimension changes (NLContextualEmbedding upgrade between macOS versions) | Store embedder signature (model version) in the vec_events table. Rebuild if signature changes. |