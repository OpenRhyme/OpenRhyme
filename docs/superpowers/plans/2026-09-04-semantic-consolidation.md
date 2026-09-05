# Semantic consolidation — Phase 2 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md` (revision 2)
**Also read:** `docs/superpowers/specs/2026-09-03-privacy-controls-design.md` in full. This worker turns captured screen content into prose about the user; every constraint that slice established applies to it.
**Depends on:** Phase 0 (session boundaries) and **Phase 0.5** (`docs/superpowers/plans/2026-09-04-derived-data-deletion.md`) — the deletion contract must exist before the first summary is written.
**Status:** proposed implementation plan (revision 2).

## Goal

Turn activity sessions into structured, queryable knowledge about the user. A local LLM reads each session's redacted events and extracts: what projects were touched, what decisions were made, what errors occurred, what patterns emerge. This is the layer that makes OpenRhyme "know you" instead of just "logging you."

It is also the layer that makes a second, more distilled copy of the user's life. A summary reading *"logged into 1Password, entry github.com (work)"* is more revealing than the rows it came from, and unlike those rows it fits in one screen. Everything below follows from that.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Consolidation worker (launchd agent, one-shot per N minutes)    │
│                                                                  │
│  0. Orphan sweep: drop derived rows whose source events are gone │
│     (matched on (id, ts) — never id alone)                       │
│                                                                  │
│  1. Read unprocessed sessions:                                   │
│     openrhyme sessions --since <last_run> --json                 │
│                                                                  │
│  2. For each session:                                            │
│     a. Get redacted events: openrhyme events --since S --until E │
│        --max-value-chars <bound>   (never --ignore-privacy)      │
│     b. If every event is a protected marker → summary only,      │
│        no entities, no facts, no edges                           │
│     c. Build context: {events, session meta, recent facts}       │
│     d. Call the LLM (local by default; remote is opt-in, §5)     │
│     e. Parse structured response                                 │
│     f. Upsert entities/facts/summaries WITH provenance rows      │
│  3. Compaction pass: delete facts superseded longer than         │
│     fact_history_days ago, plus orphaned entities and edges      │
│  4. Rebuild FTS5 + vector indexes on the semantic store          │
│  5. Re-check meta.purge_epoch; if it moved, roll back and re-run │
│  6. Record last_run_ts / processed session keys (idempotent)     │
└──────────────────────────────────────────────────────────────────┘
```

The worker is a Python script launched by `launchd`. It has no TCC grants and no special permissions — it reads the engine's data through the CLI, same as every other consumer.

## Non-negotiable constraints for this worker

These are not style preferences; each one corresponds to a defect the privacy slice already had to fix.

1. **Read only through the CLI.** No `sqlite3.connect()` on `events.sqlite`, ever. The privacy slice deleted the MCP's direct database access precisely so no agent path bypasses read-time redaction (privacy spec §5.9). Reading through `openrhyme events` is what makes the derived store inherit every redaction rule, including rules added *after* the events were captured — a deliberate property, not an accident of convenience.
2. **Never pass `--ignore-privacy`.** That flag exists so the owner can audit their own store from a terminal, with a stderr warning. A background process that silently reads the unredacted store, hands it to an LLM and writes the result to a second file is the exact bypass the flag was designed not to become. It must not appear in the worker, the MCP server, the launchd plist, a config default, or a test fixture someone could copy.
3. **Never pass `--max-value-chars 0`.** Pass an explicit bound. "Full text produces better summaries" is true and is not a reason.
4. **Protected sessions yield no facts.** A protected context stores a marker row with *no content at all* — no window title, document, URL, role, element title, value or selected text; only the app identity plus `extra.protected`/`extra.protectedBy`. A session made of markers gets a summary saying the app was in use and its content is protected. Extracting entities or facts from such a session means inventing them.
5. **Nobody "fixes" empty sessions by reaching around the CLI.** There is nothing behind the CLI to find: for a protected context the daemon never performed a content read in the first place (privacy spec §4). A contributor who sees blank sessions and reaches for `sqlite3` will get the same blank rows and will have broken the redaction boundary for nothing. Say so in a comment at the read site.
6. **Every written row carries provenance** (spec §3.3) in the same transaction as the row itself. A derived row that cannot say which events it came from cannot be deleted when they are — so it must not be writable. Enforce with `NOT NULL` plus a test that inserting without provenance fails.
7. **All state lives in `semantic.sqlite`.** No cursor file, no cache dir, no prompt/response log by default. A debug log of what was sent to the model is a third copy of captured content in a file no deletion command knows about; if it exists at all it is off by default, `0600`, inside the data dir, and removed by `purge --all`.
8. **`0600` on open, every time**, including on files that already exist. The events store shipped `0644` for weeks; the fix had to handle existing installs.

## The LLM provider (spec §5)

| Rule | Behaviour |
|---|---|
| Default endpoint | `http://localhost:11434` (Ollama) or any OpenAI-compatible server on localhost. |
| Remote endpoint | **Refused at startup** unless `allow_remote_provider: true` is set alongside it. Two keys, not one, and the flag's name says what it does. |
| Disclosure | `meta.provider_kind` / `meta.provider_host` are written on every run so `openrhyme privacy` and `status` can report `provider: local` or `provider: remote (host)`. |
| What the user is opting into | With a remote provider, the redacted text of every consolidated session is sent to that provider. It is a distilled record of everything they read on screen. **OpenRhyme cannot delete it again** — `purge` reaches local files only. The config comment, the README line and the startup log all say this in those terms. |
| Honesty about "local" | A localhost call is still a network call. The worker says "local provider on localhost:11434", not "no network". |

## Extraction prompt

Each session is sent to the LLM with:

```
You are analyzing a log of computer activity. Below is a session of raw
events from a user's Mac. Extract structured facts about what the user
was doing.

Session: {start_time} to {end_time}   (key: {session_key})
Apps used: {apps list}
Event count: {count}   ({protected_count} of these are protected markers
with no content — the user was in an app whose content is never captured)
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
- Text of the form [redacted:<rule>] is a secret the engine removed. Never
  guess what it was, never treat it as an entity name, never reproduce it
  as a fact object.
- Protected markers mean the content was deliberately never captured. Say
  the app was in use; do not speculate about what happened in it.
- If the session is entirely protected markers, return a summary and empty
  entities/facts/edges.
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

**Cost estimate:** ~500 tokens input per session (50 events at ~10 tokens each), ~200 tokens output. At ~30 sessions per workday, ~21K total tokens — negligible on a local model.

## Supersession and what actually bounds the store

Revision 1's risk table claimed supersession "prunes stale facts at write time". It does not: setting `superseded_by` marks a row, it does not delete one, and the store grew monotonically. The corrected mechanism (spec §7):

- Write time: a new fact with the same `entity + predicate` sets `superseded_by` and `superseded_at` on the old one. This bounds what a **query** returns.
- End of each run: delete facts where `superseded_by IS NOT NULL AND superseded_at < now - fact_history_days` (default 30), with their provenance rows; then delete entities and edges with no surviving facts; then rebuild FTS and `VACUUM` on a schedule. This bounds **disk**.
- The real horizon is D1 (spec §4.1): derived rows never outlive their source events, so `capture.retention_days` bounds the derived store automatically. With retention off, both stores grow — which is the honest answer and the same one the events store already gives.

## New MCP tools

### `facts(query=None, entity=None, since=None, limit=50)`

```json
{
  "facts": [
    {
      "entity": "scheduler",
      "entity_type": "project",
      "predicate": "was_debugging",
      "object": "crash in task_queue.pop()",
      "session_key": "84213:1735699200.0",
      "ts": 1735700400.0,
      "superseded": false
    }
  ],
  "count": 1,
  "provenance": "consolidation run at 2026-09-04T15:00:00Z"
}
```

Without query: recent facts by `ts` desc. With query: FTS5 + vector search over `predicate + " " + object`. With entity: filter by name. The docstring states that facts are derived from the redacted projection and that protected time contributes none.

### `ask(query)`

RAG over the semantic store:
1. Embed the query.
2. Vector search `session_summaries` + `facts`.
3. Hydrate supporting events **through `openrhyme events`** (not from the index copy), so a purged event cannot be cited.
4. Build context; call the model.
5. Return the answer plus citations (`session_key`, source type).

```json
{
  "answer": "You were debugging a crash in the scheduler's task_queue.pop() around 2pm yesterday. You switched to it after reading about memory systems in the morning.",
  "citations": [
    {"session_key": "84213:1735699200.0", "source": "fact", "text": "was_debugging scheduler crash in task_queue.pop()"},
    {"session_key": "83990:1735680000.0", "source": "fact", "text": "was_reading about memory systems and LLM retrieval"}
  ]
}
```

## Semantic store management

```bash
openrhyme-mcp consolidate build     # all sessions → LLM → semantic.sqlite
openrhyme-mcp consolidate run       # unprocessed sessions since last run
openrhyme-mcp consolidate status    # counts, last run, provider kind, orphan count
```

**Reset** stays valid — `rm ~/Library/Application\ Support/OpenRhyme/semantic.sqlite` then `consolidate build` — but it is a *recovery* path, not the deletion story. Deletion is `openrhyme purge`, which removes the derived rows for the events it deletes in the same command (spec §4). Revision 1 offered `rm` as the mitigation for a purged password-manager session surviving in a summary; it is not one, because nothing ran it and nothing told the user it needed running.

**Scheduled:** a launchd plist runs `consolidate run` every 30 minutes during working hours. The plist contains no `--ignore-privacy` and no remote endpoint.

## Implementation files (MCP repo)

| File | What | Lines |
|---|---|---|
| `src/openrhyme_mcp/consolidate.py` | Main loop: sessions → LLM → upsert, orphan sweep, epoch check | ~260 |
| `src/openrhyme_mcp/semantic_store.py` | Schema, provenance writes, supersession, compaction, meta (shared with Phase 1) | ~260 |
| `src/openrhyme_mcp/provider.py` | LLM endpoint, local/remote gate, disclosure | ~80 |
| `src/openrhyme_mcp/prompts/consolidate.md` | The extraction prompt template | ~90 |
| `src/openrhyme_mcp/server.py` | `facts()` and `ask()` tools | ~60 |
| `tests/test_semantic_store.py` | In-memory store: upsert, query, supersession, compaction, provenance NOT NULL | ~140 |
| `tests/test_consolidate.py` | Fake LLM returns known JSON; assert writes, idempotence, protected handling | ~160 |
| `tests/test_provider.py` | Remote endpoint refused without the flag; disclosure written to meta | ~60 |

## Acceptance criteria

1. `consolidate build` on a fixture of 3 sessions produces correct entities, facts, edges — each with a provenance row.
2. `facts()` filters by entity name; `ask("what was I debugging?")` answers with session citations.
3. A second run over the same sessions is idempotent (no duplicate facts).
4. Supersession marks the old fact; the compaction pass actually deletes it once `fact_history_days` has passed.
5. FTS5 + vector search work on the semantic store.
6. **A session of only protected markers produces a summary and zero facts/entities/edges.**
7. **Every constructed CLI invocation is asserted free of `--ignore-privacy` and of `--max-value-chars 0`**, and the worker opens no handle on `events.sqlite`.
8. Inserting a content row without provenance fails.
9. A non-localhost provider endpoint is refused without `allow_remote_provider: true`; `meta.provider_kind` reflects reality.
10. Purging the source events of a consolidated session leaves no fact, summary, entity, edge or FTS token behind (verified against Phase 0.5).
11. An orphan sweep removes derived rows whose source events vanished by other means.
12. No engine modifications needed beyond Phase 0.5. Everything else goes through the existing CLI.

## Dependencies

| Dep | Why |
|---|---|
| Local LLM endpoint | Ollama or any OpenAI-compatible server on localhost. A remote provider is opt-in and disclosed (spec §5). |
| `httpx` | HTTP to that endpoint. Python repo only — the Swift engine's "no network code" rule is untouched. |
| `sqlite-vec` | Vector index on the semantic store (added in Phase 1) |
