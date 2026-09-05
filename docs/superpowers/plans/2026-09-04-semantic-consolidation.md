# Semantic consolidation — Phase 2 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md`
**Status:** proposed implementation plan. Depends on Phase 0 (sessionize) for session boundaries.

## Goal

Turn activity sessions into structured, queryable knowledge about the user. A local LLM reads each session's raw events and extracts: what projects were touched, what decisions were made, what errors occurred, what patterns emerge. This is the layer that makes OpenRhyme "know you" instead of just "logging you."

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Consolidation worker (launchd agent, one-shot per N minutes)    │
│                                                                  │
│  1. Read latest unprocessed sessions from events.sqlite          │
│     (via openrhyme sessions --since last_run --json)             │
│                                                                  │
│  2. For each session:                                            │
│     a. Get raw events: openrhyme events --since S --until E      │
│     b. Build context: {events, session meta, recent facts}       │
│     c. Call local LLM with extraction prompt                     │
│     d. Parse structured response                                │
│     e. Upsert entities, facts, summaries into semantic.sqlite    │
│                                                                  │
│  3. Rebuild FTS5 + vector indexes on semantic store              │
│                                                                  │
│  4. Record processed session IDs (idempotent)                    │
└──────────────────────────────────────────────────────────────────┘
```

The worker is a Python script launched by `launchd` (or run from a cron-like trigger). It has no TCC grants, no special permissions — reads the engine's data through the CLI, same as every other consumer.

## Extraction prompt

Each session is sent to the local LLM with:

```
You are analyzing a log of computer activity. Below is a session of raw
events from a user's Mac. Extract structured facts about what the user
was doing.

Session: {start_time} to {end_time}
Apps used: {apps list}
Event count: {count}
Previous facts about this session's entities (for continuity):
{relevant_existing_facts}

Raw events (last 50 shown; {total_events} total):
{events}

Respond in JSON format:
{
  "summary": "one paragraph describing what the user was doing",
  "entities": [
    {"name": "...", "entity_type": "project|file|person|concept|error|tool", "description": "..."}
  ],
  "facts": [
    {"entity_name": "...", "predicate": "...", "object": "...", "kind": "event|decision|error|pattern"}
  ],
  "edges": [
    {"source": "...", "target": "...", "edge_type": "uses|depends_on|debugging|related_to"}
  ]
}

Rules:
- Extract only facts directly supported by the events. Do not infer.
- If the session shows debugging, extract the error message and what was being debugged.
- If the session shows reading/researching, extract the topic and source.
- If the session shows coding, extract the project, file, and language.
- "kind: decision" is for explicit choices (downloads, installs, purchases, launches).
- "kind: error" is for errors, warnings, crashes.
- "kind: event" is for everything else (editing, browsing, writing).
- For predicates, prefer standard verbs: was_editing, was_reading, was_debugging,
  was_researching, configured, installed, encountered_error, created, refactored.
- Keep summaries concise (2-3 sentences maximum).
```

**Cost estimate:** ~500 tokens input per session (50 events at ~10 tokens each), ~200 tokens output. At ~30 sessions per workday, ~21K total tokens. On DeepSeek V4 Flash, negligible.

## New MCP tools

### `facts(query=None, entity=None, since=None, limit=50)`

Returns structured facts from the semantic store.

```json
{
  "facts": [
    {
      "entity": "scheduler",
      "entity_type": "project",
      "predicate": "was_debugging",
      "object": "crash in task_queue.pop()",
      "session_id": 42,
      "ts": "1735700400.0",
      "superseded": false
    }
  ],
  "count": 1,
  "provenance": "consolidation run at 2026-09-04T15:00:00Z"
}
```

Without query: returns recent facts sorted by `ts` desc (latest activity).
With query: FTS5 + vector search over fact text (`predicate + " " + object`).
With entity: filter by entity name.

### `ask(query)`

RAG query over the semantic store. Steps:
1. Embed the query
2. Vector search session_summaries + facts
3. Gather matching events from raw store (for drill-down)
4. Build context: relevant summaries + facts + raw events
5. Call the model (same LLM as consolidation) for a natural answer
6. Return answer + citations (session_id, source type)

```json
{
  "answer": "You were debugging a crash in the scheduler's task_queue.pop() around 2pm yesterday. You switched to it after reading about memory systems in the morning.",
  "citations": [
    {"session_id": 42, "source": "fact", "text": "was_debugging scheduler crash in task_queue.pop()"},
    {"session_id": 40, "source": "fact", "text": "was_reading about memory systems and LLM retrieval"}
  ]
}
```

## Semantic store management

### Build (one-time)

```bash
openrhyme-mcp consolidate build
# Reads all sessions → LLM → semantic.sqlite
```

### Incremental

```bash
openrhyme-mcp consolidate run
# Reads unprocessed sessions since last run → LLM → append to semantic store
```

### Reset

```bash
rm ~/Library/Application\ Support/OpenRhyme/semantic.sqlite
openrhyme-mcp consolidate build
# Rebuilds from scratch. Events are untouched.
```

### Scheduled (via launchd)

A plist runs `openrhyme-mcp consolidate run` every 30 minutes during working hours.

## Implementation files (MCP repo)

| File | What | Lines |
|---|---|---|
| `src/openrhyme_mcp/consolidate.py` | Main consolidation loop: read session → call LLM → upsert | ~200 |
| `src/openrhyme_mcp/semantic_store.py` | SQLite schema, upsert, query, FTS5/vector indexes for semantic store | ~200 |
| `src/openrhyme_mcp/prompts/consolidate.md` | The extraction prompt template | ~80 |
| `src/openrhyme_mcp/server.py` | `facts()` and `ask()` tools | ~60 |
| `tests/test_semantic_store.py` | In-memory semantic store, test upsert/query/supersession | ~100 |
| `tests/test_consolidate.py` | Fake LLM returns known JSON, assert correct writes | ~100 |

## Acceptance criteria

1. `openrhyme-mcp consolidate build` on a fixture of 3 sessions produces correct entities, facts, edges in semantic.sqlite.
2. `facts()` returns facts filtered by entity name.
3. `ask("what was I debugging?")` returns the correct answer with session citations.
4. A second consolidation run on the same sessions is idempotent (no duplicate facts).
5. Supersession works: same entity+predicate with newer timestamp marks old fact as superseded.
6. FTS5 + vector search work on the semantic store.
7. No engine modifications needed. Everything goes through the existing CLI.

## Dependencies

| Dep | Why |
|---|---|
| Local LLM endpoint | DeepSeek V4 Flash (your provider), or any OpenAI-compatible API |
| `httpx` | LLM API calls |
| `sqlite-vec` | Vector index on semantic store (already added in Phase 1) |

None of these are new — Phase 2 reuses what Phase 1 already configured.