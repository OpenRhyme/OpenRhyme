# Hybrid search — Phase 1 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md` (revision 2)
**Also read:** `docs/superpowers/specs/2026-09-03-privacy-controls-design.md` §5.7/§5.9 — the read path this plan consumes is the redacted one, on purpose.
**Depends on:** Phase 0.5 (`docs/superpowers/plans/2026-09-04-derived-data-deletion.md`). The index is derived data; it does not get written before the engine can delete it.
**Status:** proposed implementation plan (revision 2).

## Goal

Make raw events searchable by meaning, not just filterable by time/app/kind. An agent can ask "find me the thing about the scheduler crash" and get the right events, even when the query doesn't contain the exact words in the event text.

## What changed in revision 2

Revision 1 put an FTS5 index **inside `events.sqlite`**, created by the daemon at startup, and had the MCP server open the events database read-only to build a vector index. Both must not ship:

- **An FTS5 index is a second copy of the text.** Read-time redaction lives in `openrhyme events`; it cannot reach index tokens. A secret redacted on every read path would sit tokenised and searchable in the same file.
- **External-content FTS5 retains deleted rows' tokens.** `purge` and the retention sweep `DELETE` from `events` directly. Without the matching triggers the index quietly keeps the text of every purged row — "deleted but still readable", the exact defect the privacy slice fixed five times.
- **Direct read-only SQLite from the MCP was deliberately removed.** The privacy slice deleted `store.py`'s `query_events`/`shape_row`/`open_readonly` so that no agent path bypasses read-time redaction (privacy spec §5.9). Reopening it here would reintroduce the bypass and embed *unredacted* text into vectors.
- Revision 1 also contradicted itself: acceptance criterion 4 said "no engine changes required" two paragraphs after specifying an engine change.

**Revision 2:** the index lives in `semantic.sqlite` (`indexed_events` + `indexed_events_fts` + a sqlite-vec table), is populated from `openrhyme events --json` — the **redacted** projection — and is covered by the deletion contract like every other derived row.

## What changes

### Engine (Swift) — no changes

None. No FTS5 table in `events.sqlite`, no daemon-startup migration, no new flags. The engine's only involvement with the index is deleting from it, which Phase 0.5 already implements generically.

### MCP server (Python) — new search capability

**New tool: `search(query, since=None, until=None, kinds=None, app=None, limit=20, mode="hybrid")`**

```json
{
  "results": [
    {
      "event": { /* RawEvent, as the CLI returned it — already redacted */ },
      "score": 0.87,
      "method": "hybrid"   // "semantic", "lexical", or "hybrid"
    }
  ],
  "count": 1
}
```

**Architecture within the MCP server:**

```
openrhyme events --json (redacted)
        │
        ▼
  indexed_events  ──▶ indexed_events_fts (FTS5)
   (semantic.sqlite)──▶ vec_indexed_events (sqlite-vec)
        │
search(query) ──▶ FTS5 channel ──┐
              ──▶ vector channel ─┴──▶ RRF fusion ──▶ ranked results
```

**Indexing (incremental):**

1. Read `meta.last_indexed_event_id` and `meta.purge_epoch` from `semantic.sqlite`.
2. Shell out to `openrhyme events --since <cursor time> --json` with an explicit `--max-value-chars`. **Never `--ignore-privacy`**, never a direct SQLite handle.
3. Insert one `indexed_events` row per event: `event_id`, `ts`, `bundle_id`, the redacted `text` projection, and its embedding. Write a `derived_provenance` row for each (`row_table='indexed_events'`, `min_event_id = max_event_id = event_id`, `start_ts = end_ts = ts`, `bundle_id`).
4. Before commit, re-read `meta.purge_epoch`. If it changed, roll back and re-run — a purge landed mid-index and some of what was just read is now deleted.
5. Advance `last_indexed_event_id`.

Rows whose text is empty (protected markers, see below) are indexed with an empty `text` so their `ts`/`bundle_id` still participate in filters, but they contribute no tokens and no vector.

**Embedding provider:**

Primary: Apple `NLContextualEmbedding` via a subprocess call to a small Swift helper importing `NaturalLanguage`. Python FFI into the NL framework breaks on macOS updates; a helper that reads stdin, embeds, writes stdout is more reliable. The helper is a standalone file shipped with the MCP server — **not** a new target in the engine repo, which stays free of anything the search feature owns.

Fallback: Ollama `nomic-embed-text` over HTTP on `localhost`. This is a network call in the literal sense (spec §5) and is described as such, not as "zero network". A non-localhost embedding endpoint follows the same `allow_remote_provider` rule as the consolidation LLM.

```python
# config.py addition
@dataclass(frozen=True)
class SearchSettings:
    embedder: str = "apple"                      # "apple" or "ollama"
    ollama_endpoint: str = "http://localhost:11434"
    ollama_model: str = "nomic-embed-text"
    max_value_chars: int = 2000                  # explicit bound; never 0
    fts5_enabled: bool = True
    vector_enabled: bool = True
    rrf_k: int = 60
```

**Search flow:**

```python
def _hybrid_search(query: str, limit: int) -> list[SearchResult]:
    query_embedding = _embed(query)

    fts5_results = sem.execute("""
        SELECT e.*, rank
        FROM indexed_events_fts f
        JOIN indexed_events e ON e.event_id = f.rowid
        WHERE indexed_events_fts MATCH ?
        ORDER BY rank
        LIMIT ?
    """, (query, limit * 2))

    vec_results = sem.execute("""
        SELECT e.*, distance
        FROM vec_indexed_events v
        JOIN indexed_events e ON e.event_id = v.event_id
        ORDER BY vec_distance_cosine(v.embedding, ?)
        LIMIT ?
    """, (query_embedding, limit * 2))

    return reciprocal_rank_fusion(fts5_results, vec_results, k=60)[:limit]
```

Results are hydrated back through `openrhyme events` before being returned, so what the agent sees is the current redacted row, not a stale index copy. An event id that no longer resolves is dropped from the results and queued for orphan cleanup — the index lagging a purge must never surface deleted content.

**Privacy properties this plan must preserve (assert them in tests, don't assume them):**

- Every indexed byte came from `openrhyme events` with redaction applied. Search over a store holding `[redacted:aws-key]` returns the marker, never the key.
- Protected contexts produce contentless marker rows. They index to empty text and must not be "fixed" by reaching into SQLite — there is nothing there to find; the content was never read into the daemon (privacy spec §4).
- `--ignore-privacy` appears nowhere in this feature.
- The index is deleted by `purge`/retention along with its source rows (Phase 0.5).

**Implementation files (MCP repo):**

| File | What | Lines |
|---|---|---|
| `src/openrhyme_mcp/embed.py` | Embedding abstraction: Apple helper subprocess + Ollama fallback | ~100 |
| `src/openrhyme_mcp/semantic_store.py` | `semantic.sqlite` schema, provenance writes, meta/epoch handling | ~200 |
| `src/openrhyme_mcp/indexer.py` | Incremental index build from CLI output | ~120 |
| `src/openrhyme_mcp/search.py` | Hybrid search: FTS5 + vector + RRF | ~150 |
| `src/openrhyme_mcp/server.py` | New `search()` tool | ~30 |
| `src/openrhyme_mcp/config.py` | `SearchSettings` dataclass | ~15 |
| `tests/test_search.py` | Fixture store with known events, assert results | ~140 |

**Test strategy:**
- Fixture: a fake engine CLI returning known events ("scheduler crash error", "reading about memory systems", "installing brew packages"), plus one row whose value is `[redacted:aws-key]` and one protected marker.
- Search "crash in scheduler" → `method: "hybrid"`, rank 1 contains "scheduler crash".
- Search "brew install" → lexical channel outranks vector.
- Search for the raw secret string → zero hits; search for `redacted` → the marker row. Proves the index never saw plaintext.
- Rebuild from scratch → no duplicate rows; `last_indexed_event_id` correct.
- Purge simulation: bump `purge_epoch` mid-index → the run rolls back rather than committing rows for deleted events.
- Every constructed CLI argument list is asserted free of `--ignore-privacy` and of `--max-value-chars 0`.

## Acceptance criteria

1. The index builds into `semantic.sqlite` from CLI output only; the MCP server opens no handle on `events.sqlite`.
2. `search("what was that error about the scheduler")` returns the right event from a known fixture.
3. `search("install brew stuff")` returns events with "brew" or "install" even when the vector embedding is weak.
4. No engine changes required — and none snuck in: no FTS5 table exists in `events.sqlite` after the feature ships.
5. Indexed text is provably the redacted projection (the secret-string test above).
6. Every indexed row carries provenance and is removed by `openrhyme purge` (verified against Phase 0.5's machinery).
7. Embedding provider is configurable (`apple` / `ollama`); a non-localhost endpoint is refused without `allow_remote_provider`.
8. Test suite covers exact-match, semantic-match, hybrid, empty results, missing store, unindexed store, purge-during-index.

## Dependencies

| Dep | Why | New in OpenRhyme |
|---|---|---|
| `sqlite-vec` | Vector ANN index in the semantic store | Yes — Python package, added to `pyproject.toml` |
| Swift helper binary | Apple `NLContextualEmbedding` | Yes — a standalone file shipped with the MCP server, not a target in the engine repo |
| `httpx` | Ollama HTTP calls (localhost by default) | Added to `pyproject.toml`. Lives in the Python repo; the Swift engine's "no network code" rule is untouched (spec §5) |

## Risks

| Risk | Mitigation |
|---|---|
| An FTS5 index over `events.sqlite` gets re-proposed as "simpler" | It is simpler and it leaks: read-time redaction cannot reach index tokens, and external-content FTS5 keeps the tokens of purged rows. Recorded here so the next person finds the reason before the shortcut. |
| The index lags a purge and surfaces deleted content | Results are hydrated through the CLI; unresolvable ids are dropped and queued for orphan cleanup. `purge_epoch` aborts an indexing run that straddles a deletion. |
| sqlite-vec extension not loadable in Python | It is a loadable extension; test in CI. Fallback: pure-Python KNN over numpy. |
| Apple embedder helper not built | Fall back to Ollama; log a warning. Never silently return lexical-only results labelled "hybrid". |
| Embedding dimension changes across macOS versions | Store the embedder signature in the vector table; rebuild when it changes. |
| Redaction markers become high-frequency tokens | Accepted: indexing the marker is correct, indexing the secret is not. Improve the structural rules if the noise matters. |
