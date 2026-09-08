# OpenRhyme — semantic layer design

**Status:** proposed (revision 2, 2026-09-04). Supersedes the WARM/COLD storage tiers from `docs/computer-history-spec.md` §6. The storage tiers are replaced by a companion semantic store built asynchronously over the single SQLite source of truth.

**Read first:** `docs/superpowers/specs/2026-09-03-privacy-controls-design.md` and the README's **Privacy** and **Limits** sections. This design adds a *second place captured content lives*, and the privacy slice that shipped before it establishes the standard that second place has to meet. Revision 1 of this spec was written against a `main` that predates that slice and mentioned `purge`, `privacy`, `redact` and `protect` exactly zero times; §4 exists because of that.

**Scope:** the Swift engine (`sessions` CLI command, derived-store deletion in `purge`/retention/`privacy`), plus the Python MCP server ([OpenRhyme/openrhyme-mcp](https://github.com/OpenRhyme/openrhyme-mcp)) which owns hybrid search, semantic consolidation and the temporal knowledge graph. This spec covers architecture and data model; implementation plans live in `docs/superpowers/plans/`.

## 1. Why this replaces the tiered architecture

The original spec proposed three storage tiers: HOT (raw events), WARM (session summaries), COLD (archive). Rationale: reduce noise, compress history, enable long-term retrieval.

**What we learned during Part 1:**

- Raw events are cheap. SQLite handles ~100K rows per workday (~80 MB) with no pressure. At that rate, a year is ~30M rows — still comfortable in SQLite with proper indexing (`ts + id` covering index).
- Sessionization is a **query-time** or **background-index-time** problem, not a **storage** problem. No compaction pipeline needed.
- The agent brings the LLM. Deterministic sessionization heuristics are a pale substitute for what a local model can infer from 50 events in context.

**New architecture:**

```
daemon (Swift) ───writes──▶ events.sqlite (single source of truth, 0600)
                                    │
                    ┌───────────────┴────────────────┐
                    │                                │
          openrhyme CLI (redacts on read)    openrhyme purge / retention
                    │                                │  deletes from BOTH stores (§4)
                    ▼                                ▼
        openrhyme-mcp (Python)  ──builds──▶  semantic.sqlite (derived, 0600)
          ├── sessions (idle-gap, no LLM)         entities · facts · summaries
          ├── search (FTS5 + vectors + RRF)       edges · embeddings · search index
          ├── consolidate (async, local LLM)      every row carries provenance
          └── graph (entity links, optional)
```

No compaction daemon. No WARM/COLD migration logic. No extra background writer in the Swift engine. The companion `semantic.sqlite` is built by the MCP server's background worker, reading the source of truth **through the CLI** — which means it inherits read-time redaction (§6).

The one thing the engine does own in the derived store is **deletion** (§4). That is deliberate: a deletion guarantee cannot depend on a separate process in a separate repo being installed, running, or reachable.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Storage tiers | One SQLite source of truth. Companion semantic store built asynchronously. | Simpler, less code, same capability. The LLM does abstraction at write time or query time — whichever the agent prefers. |
| Session boundary | Idle-gap detection. Configurable timeout (default 5 min). | Zero LLM, trivially testable, matches cognitive science (activity boundaries are pauses). Compatible with the "activity coherence, never fixed time windows" non-negotiable — see §11.1. |
| Session identity | `first_event_id` of the session, plus the `[start_ts, end_ts]` range. Never a renumbered ordinal. | Sessions are computed on read; an ordinal renumbers on every re-run and would silently repoint every derived row. See §3.1. |
| Search modality | Hybrid: FTS5 for exact match (filenames, errors, identifiers), dense embeddings for semantic match, RRF fusion. | Filenames and error strings are exact — embeddings miss them. Concepts and queries are semantic — FTS5 misses them. Both needed. |
| Where the search index lives | In `semantic.sqlite`, built from the CLI's **redacted** output. **Not** an FTS5 table inside `events.sqlite`. | An index inside the source store would hold a second, unredacted copy of every value that read-time redaction cannot reach and `purge` would leave behind as orphaned tokens. See §4.6. |
| Embeddings | Apple `NLContextualEmbedding` (macOS 14+) as primary. Ollama fallback. | Free, on-device, no model download for the user. Apple silicon native. |
| Semantic store | SQLite with FTS5 + sqlite-vec, one file, same data dir. | No new infra. One file to protect, one file to delete from, one file to state limits about. |
| LLM in capture path | **Never.** | Settled in the original spec, and still load-bearing: the daemon holds the Accessibility grant. An LLM there adds attack surface, latency and crash risk to the one privileged process. |
| LLM in consolidation | Yes — separate background process in the **Python** repo, no TCC grants, reads through the CLI. | The Swift engine stays inference-free; the worker is where prose happens. See §11.2. |
| Fact supersession | Write-time marking **plus** a bounded compaction pass that actually deletes superseded rows. | Marking alone does not bound growth — it only bounds what a query returns. See §7 and §3.2. |
| Network | **None in this repo (Swift engine) — a hard non-negotiable.** The Python worker makes local HTTP calls (Ollama / a local OpenAI-compatible server on `localhost`) by default, and *can* be configured to call a remote provider, which sends captured screen content off the machine. | Revision 1 claimed "Zero" two rows above naming an Ollama fallback and a hosted provider. Loopback HTTP is still a network call and a remote provider is still exfiltration. See §5. |
| Remote provider | Opt-in, explicit, never a default. Refused unless `allow_remote_provider: true`; reported by `status`/`privacy`; content sent there is outside every deletion guarantee. | A local-first tool that just shipped privacy controls does not get to quietly ship a default that uploads your screen. See §5. |
| Derived-data deletion | `purge` and the retention sweep delete matching derived rows in the **same command**, then VACUUM + WAL-checkpoint `semantic.sqlite`. Failure is reported, never swallowed. | §4. This is the hard requirement of this revision. |
| Derived store at rest | `0600` file in the `0700` data dir, applied on create **and** corrected on existing files by both the engine and the worker. | §5 of the privacy spec, applied to a file that is arguably more sensitive than the source. See §4.7. |
| Storage format | Events: existing schema v1, unchanged. Semantic: separate `semantic.sqlite` in the same data dir (`~/Library/Application Support/OpenRhyme/`). | Source of truth stays pristine. Derived store is rebuildable — but rebuildable is *not* a deletion story (§4.1). |

## 3. Data model

### 3.1 Sessions (engine CLI, no LLM)

A session is a contiguous block of activity with no gap longer than `idle_timeout` (default 300 s).

**Session identity is the id of the session's first event**, carried alongside its timestamp range. There is no ordinal `sessions.id` and no foreign key into a `sessions` table:

- §3.1 of revision 1 said sessions are computed on read and only materialised with `--persist`. Revision 1 then declared `facts.session_id REFERENCES sessions(id)` against ordinals that renumber on every re-run. After one purge, or one change to `idle_timeout`, every fact would have pointed at a different session than the one it came from. A referential integrity constraint that references a table which usually does not exist, keyed by a number that changes, is worse than no constraint.
- The replacement is a **stable, content-derived key**: `session_key = "<first_event_id>:<start_ts>"`. It is reproducible from the events alone, traceable to a real row, and it is *the same tuple the deletion mechanism needs* (§4.3), so provenance and identity are one thing rather than two.
- The `ts` half is not decoration. `events.id` is `INTEGER PRIMARY KEY` **without** `AUTOINCREMENT`, so SQLite may reuse a rowid after a purge that removes the newest rows. An id alone can therefore come to mean a different event; an `(id, ts)` pair cannot. Every match in §4 uses both. (A future schema v2 should switch to `AUTOINCREMENT`; that is a public-contract change needing a version bump and migration, so it is out of scope here and recorded in §7.)

Shape returned by `openrhyme sessions`:

```json
{
  "session_key": "84213:1735699200.0",
  "first_event_id": 84213,
  "last_event_id": 85060,
  "start": 1735699200.0,
  "end": 1735700400.0,
  "duration_s": 1200,
  "app_count": 3,
  "event_count": 847,
  "bundle_ids": ["com.apple.TextEdit", "com.apple.Safari", "com.microsoft.VSCode"],
  "dominant_kind": "context.snapshot",
  "protected_event_count": 12
}
```

`protected_event_count` counts rows carrying `extra.protected` — see §6.3. Sessions are computed on read; `--persist` writes them into `semantic.sqlite` (never into `events.sqlite`, which stays exactly as the schema contract describes it) as an ordinary derived table with provenance like any other.

### 3.2 Semantic store (companion SQLite, built by the consolidation worker)

Every content-bearing table carries the provenance columns. They are `NOT NULL`: a row that cannot say which events it came from cannot be deleted when those events are, so it must not be writable in the first place.

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
    session_key   TEXT NOT NULL,          -- "<first_event_id>:<start_ts>", NOT a foreign key (§3.1)
    entity_id     INTEGER NOT NULL REFERENCES entities(id),
    predicate     TEXT NOT NULL,          -- "was_editing", "debugged", "researched", "configured"
    object        TEXT NOT NULL,          -- the value or target
    ts            REAL NOT NULL,          -- when the fact was observed
    superseded_by INTEGER REFERENCES facts(id),   -- NULL = current, non-NULL = this fact is stale
    superseded_at REAL,                   -- when it was superseded; drives compaction (§7)
    provenance    TEXT NOT NULL           -- JSON: {kind, event_count}
);
CREATE INDEX idx_facts_entity ON facts(entity_id);
CREATE INDEX idx_facts_session ON facts(session_key);
CREATE INDEX idx_facts_current ON facts(superseded_by) WHERE superseded_by IS NULL;

-- Session summaries (one per session, built by LLM)
CREATE TABLE session_summaries (
    id           INTEGER PRIMARY KEY,
    session_key  TEXT NOT NULL UNIQUE,
    summary      TEXT NOT NULL,
    embedding    BLOB,                   -- 768-dim float32 vector (sqlite-vec)
    created_at   REAL NOT NULL
);

-- Edges for the optional knowledge graph
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

-- The search index over raw events, built from the CLI's redacted output (§2, §4.6).
CREATE TABLE indexed_events (
    event_id      INTEGER PRIMARY KEY,    -- events.id, paired with ts everywhere (§3.1)
    ts            REAL NOT NULL,
    bundle_id     TEXT,
    text          TEXT NOT NULL,          -- redacted projection, never raw
    embedding     BLOB
);
CREATE INDEX idx_indexed_events_ts ON indexed_events(ts);

-- FTS5 virtual tables for full-text search
CREATE VIRTUAL TABLE facts_fts USING fts5(
    predicate, object,
    content='facts', content_rowid='id'
);

CREATE VIRTUAL TABLE session_summaries_fts USING fts5(
    summary,
    content='session_summaries', content_rowid='id'
);

CREATE VIRTUAL TABLE indexed_events_fts USING fts5(
    text,
    content='indexed_events', content_rowid='event_id'
);
```

### 3.3 Provenance — the deletion contract

One table maps every derived row back to the events that produced it. It is the only thing the engine needs to understand in order to delete correctly, which is what keeps the engine out of the semantics business.

```sql
CREATE TABLE derived_provenance (
    row_table     TEXT    NOT NULL,   -- 'facts' | 'entities' | 'edges' | 'session_summaries' | 'indexed_events' | 'sessions'
    row_id        INTEGER NOT NULL,   -- the row's INTEGER PRIMARY KEY in that table
    session_key   TEXT    NOT NULL,   -- "" for rows not tied to a session (e.g. indexed_events)
    min_event_id  INTEGER NOT NULL,
    max_event_id  INTEGER NOT NULL,
    start_ts      REAL    NOT NULL,
    end_ts        REAL    NOT NULL,
    bundle_id     TEXT    NOT NULL DEFAULT '',  -- one row per contributing bundle id
    PRIMARY KEY (row_table, row_id, session_key, bundle_id)
);
CREATE INDEX idx_prov_ts     ON derived_provenance(start_ts, end_ts);
CREATE INDEX idx_prov_ids    ON derived_provenance(min_event_id, max_event_id);
CREATE INDEX idx_prov_bundle ON derived_provenance(bundle_id);
```

A cross-session row (an entity, an edge, a merged alias) gets **one provenance row per contributing session and bundle id**, not an averaged range. That is what makes "this entity was partly derived from the session you just purged" answerable at all.

`meta` in the derived store carries the contract the engine reads:

| key | meaning |
|---|---|
| `deletion_contract_version` | integer. The engine refuses to guess at a version it does not support (§4.5). |
| `derived_schema_version` | the worker's own schema version; the engine does not interpret it. |
| `content_tables` | JSON array of tables the engine may `DELETE` from by `(row_table, row_id)`. |
| `fts_tables` | JSON array of FTS5 tables to `'rebuild'` after any external delete (§4.6). |
| `vector_tables` | JSON array of `{table, key_column, row_table}` for sqlite-vec tables keyed off a content row. |
| `idle_timeout_s` | the timeout the store was built with; a change marks the store for rebuild (§7). |
| `purge_epoch` | integer, incremented by the engine on every deletion. The worker re-checks it before commit (§4.4). |
| `rebuild_required` | `0`/`1`; set by the engine when it deleted rows or removed the file. |
| `last_run_ts`, `last_indexed_event_id` | the worker's cursor. All worker state lives here — there is no second state file (§4.7). |
| `provider_kind`, `provider_host` | `local`/`remote` and the configured endpoint host, for `status`/`privacy` to report (§5). |

## 4. Derived data and the deletion guarantee (hard requirement)

### 4.1 The requirement

> **D1 — No derived row outlives the events it was derived from.**
>
> A deletion command must not report success while the data it promised to remove is still readable somewhere. `openrhyme purge` and the automatic retention sweep must remove the derived rows produced from the events they delete, in the same command, before reporting success — or say plainly that they could not.

This is not a new standard. It is the standard the privacy slice already set, and the same defect it fixed five times: a purge that reported success while every deleted row sat in plaintext; a report advising a command that would delete nothing; a count of `0` reading as "nothing sensitive stored"; a capture path that bypassed every rule; an audit command that promised everything and hid two columns. The shape is always **the product told a worried person their data was safe when it was not**.

The concrete failure this section exists to prevent: a user purges a captured password-manager session; the raw rows go; `purge` reports `{"deleted": 412, "vacuumed": true}`; and a summary reading *"logged into 1Password, entry github.com (work)"* sits in `semantic.sqlite` indefinitely, readable by any process running as the user, served to any agent that calls `facts()` or `ask()`.

**"The semantic store is disposable — delete and rebuild" is not a mitigation.** Rebuilding happens *from events*, so a rebuild does drop the purged content — but only if someone rebuilds. Until then the stale store persists, nothing tells the user it exists, and `purge`'s success message is a false statement about the state of the disk. Disposability is a *recovery* property, not a *deletion* property.

**Bias: over-deletion, always.** When a derived row was produced from a mix of purged and surviving events, it is deleted. The surviving events regenerate an equivalent row on the next consolidation pass, minus the purged contribution. Over-deletion costs recomputation; under-deletion is the privacy failure this section exists to prevent. `purge` reports the amplification (`"derived rows removed: 37, across 12 sessions"`) so the cost is visible rather than surprising.

### 4.2 Who performs the deletion

**The Swift engine, synchronously, inside `purge` and the retention sweep.** Not the Python worker.

- The guarantee must not depend on a separate process in a separate repo being installed, running, currently scheduled, or even present. A user who removes the MCP server still has a `semantic.sqlite` on disk.
- The engine already owns the data directory, already resolves it from `$OPENRHYME_DATA_DIR`, and already has the lock-retry, VACUUM and WAL-checkpoint machinery that the privacy slice built for exactly this problem.
- Deleting rows by provenance is not inference and not network. The **no LLM in the engine** and **no network in this repo** non-negotiables are untouched: the engine reads `meta` and `derived_provenance`, issues `DELETE`s, rebuilds FTS indexes, vacuums. It never reads a summary, never writes one, never interprets a fact.

### 4.3 Matching rule

For each purge selector, the derived rows to delete are every row with **at least one provenance edge intersecting the purged set**, matched on id **and** timestamp (never id alone — see §3.1 on rowid reuse):

| Selector | Derived rows removed |
|---|---|
| `--since` / `--until` | any row whose `[start_ts, end_ts]` overlaps the purged window (`NOT (end_ts < since OR start_ts > until)`) |
| `--app <bundle-id>` | any row with a provenance edge whose `bundle_id` matches |
| `--url-contains`, `--apply-rules` | the purged events are a scattered id set; remove any row where `min_event_id <= purged_id <= max_event_id` **and** the purged event's ts falls inside `[start_ts, end_ts]` |
| `--all` | every row in every declared content table, plus all provenance |
| retention sweep (`ts < cutoff`) | any row with `start_ts < cutoff` — a session straddling the cutoff loses its derived rows too |

`--dry-run` reports derived counts alongside event counts and deletes nothing from either store. A dry run that reported only the event count would be the "report advising a command that would delete nothing while claiming it worked" defect again, one level up.

### 4.4 Sequence

1. Delete the matching events (existing behaviour), collecting the deleted set's id list, ts range and bundle ids.
2. If `semantic.sqlite` is absent, report `derived: {present: false}` and stop. Nothing to do, and say so rather than staying silent.
3. Open it read-write, `chmod 0600` it and its `-wal`/`-shm` (§4.7).
4. Read `meta.deletion_contract_version`. Unsupported or missing → §4.5.
5. In one transaction: select the matching `(row_table, row_id)` set from `derived_provenance`; `DELETE` from each table named in `meta.content_tables` (rejecting any table name not in that list); delete the matching provenance rows; delete matching rows from each `meta.vector_tables` entry; increment `meta.purge_epoch`; set `meta.rebuild_required = 1`.
6. `INSERT INTO <fts>(<fts>) VALUES('rebuild')` for every table in `meta.fts_tables` (§4.6).
7. `VACUUM`, then `PRAGMA wal_checkpoint(TRUNCATE)`, each with the same bounded lock-retry `PurgeCommand` already uses for `events.sqlite`. **Yes, the derived store is vacuumed and checkpointed** — for the identical reason the events store is: in WAL mode `VACUUM` rewrites the database into the WAL, and without the explicit truncating checkpoint the deleted text stays in the file. Skipping this would reproduce, in the new store, the first of the five defects verbatim.
8. Report.

`purge --json` gains:

```json
"derived": {
  "store": "semantic.sqlite",
  "present": true,
  "cleaned": true,
  "rows_deleted": 37,
  "sessions_affected": 12,
  "tables": {"facts": 24, "entities": 3, "session_summaries": 6, "edges": 4},
  "fts_rebuilt": ["facts_fts", "session_summaries_fts", "indexed_events_fts"],
  "vacuumed": true,
  "checkpointed": true
}
```

Human output gets one line in the same register as the existing purge output, and `cleaned: false` is never printed as a success.

**Concurrency with the worker.** The worker may be mid-run. It takes an ordinary SQLite write transaction, and before committing re-reads `meta.purge_epoch`; if the epoch changed since its run began, it rolls back and re-runs against the current events. Without that check, a worker that read events at T0 could re-insert, at T2, facts derived from rows the purge deleted at T1 — resurrecting deleted content through the back door.

### 4.5 When it cannot be done surgically — say so, or remove the file

Three outcomes, in order of preference. None of them is "report success and move on".

1. **Contract intact** → surgical deletion as above. `cleaned: true`.
2. **Contract broken** — `semantic.sqlite` exists but the engine cannot open it, cannot read `meta`, finds a `deletion_contract_version` newer than it supports, finds `derived_provenance` missing, or finds a content table not covered by provenance → **remove the whole derived store**: unlink `semantic.sqlite`, `-wal` and `-shm`. Report it plainly: *"the semantic store could not be cleaned selectively (unsupported deletion_contract_version 3); it was removed entirely and will be rebuilt from the remaining events."* This is strictly safe and costs only recomputation. It is also why all derived state lives in one file (§4.7) — the fallback is total only if there is nothing else on disk holding derived content.
3. **Neither is possible** — the file is locked past the retry window, or removal fails on permissions → **fail loudly**. `cleaned: false` with the reason and the file path, a non-zero exit, and human output that does not claim the purge finished. The events deletion still happened and is reported honestly as partial. This is the "told plainly, not silently deferred" branch: the user gets the exact path and the exact command to retry, never a green tick over a store that still holds their password-manager summary.

The retention sweep, which runs unattended inside the daemon, mirrors `RetentionSweepOutcome` exactly: it never throws, never wedges the capture loop, and reports a `derivedReclaimIncomplete` outcome through `onError` rather than logging a "swept" line that misrepresents an incomplete clean as done. The first-sweep-after-enabling skip announcement must name the derived rows that *would* go, not just the events — otherwise the review window the skip exists to provide is showing half the picture.

### 4.6 The search index is derived data too, and must not live in `events.sqlite`

Revision 1's hybrid-search plan proposed `CREATE VIRTUAL TABLE events_fts USING fts5(value, window_title)` inside `events.sqlite`, created by the daemon at startup. That must not ship:

- An FTS5 index is a **second copy of the text**. Read-time redaction runs in `openrhyme events`; it cannot reach index tokens. A secret redacted on every read path would still be sitting, tokenised and searchable, in the same file.
- With `content='events'` external-content FTS5, deleting a row from `events` without the matching delete trigger leaves the tokens orphaned in the index. `purge` and the retention sweep both delete rows directly. The index would quietly retain the text of every purged row.
- It contradicted the plan's own acceptance criterion ("no engine changes required") two paragraphs after specifying an engine change.

Instead the index lives in `semantic.sqlite` as `indexed_events`, populated from `openrhyme events --json` — the **redacted** projection — and is covered by §4.3 like every other derived row. After any external deletion the engine runs the FTS5 `'rebuild'` command on every table named in `meta.fts_tables`, which discards orphaned tokens outright.

### 4.7 One file, one place to look

All derived state lives in exactly one file: `semantic.sqlite` in the engine's data dir. No side-car index, no separate worker state file, no cursor in `~/.cache`, no LLM request log. The worker's cursor lives in that file's `meta`.

This is a deletion property, not tidiness: the whole-file fallback (§4.5) is only a real guarantee if there is nothing else on disk holding derived content, and the user-facing claim "your history lives in two files, and `purge` empties both" is only checkable if it is true.

Consequences that must be honoured by the worker:

- **No prompt/response logging by default.** A debug log of what was sent to the model is a third copy of captured content, in a file no deletion command knows about. If a debug log is offered at all it is off by default, written inside the data dir at `0600`, and named in `purge --all`.
- **No temp files outside the data dir.** Batches assembled for the model are held in memory or in a `0600` file in the data dir, deleted on completion.

### 4.8 Discovery — the user has to know it exists

Revision 1's store was invisible: nothing created it in a way the user would notice, nothing reported it, and no command mentioned it. "Nothing tells the user it exists" is how a `0` count comes to read as a clean bill of health.

- `openrhyme privacy` reports the derived store: present or not, path, size, row counts per content table, `last_run_ts`, and whether the configured LLM provider is local or remote (§5). It also reports **orphans**: derived rows whose source events no longer exist, matched on `(id, ts)`. A non-zero orphan count means something deleted events without cleaning the derived store — an older engine, a manual `sqlite3` delete — and the report names the command that fixes it.
- `openrhyme status` reports presence and size in one line.
- The README's Privacy section gains the derived store in the same plain register as the rest, and the Limits section gains its honest caveats — but only once the mechanism actually ships. A README that describes derived-store purging before Phase 2 lands would be the same class of false claim this section exists to prevent.
- Consolidation runs an orphan sweep before it starts, so a store that drifted gets cleaned at the next opportunity even without a purge.

### 4.9 What deletion cannot reach

Stated here so it is never implied otherwise:

- **Content sent to a remote provider is outside every deletion guarantee** (§5). `purge` deletes local rows; it has no reach into a third party's logs. This is the single strongest argument for keeping the provider local.
- `purge` is not forensic erasure — the existing README limit applies identically to `semantic.sqlite`: vacuum returns extents un-zeroed, so raw-disk recovery may still find fragments. FileVault is the mitigation, not `purge`.
- A derived row built from a row that was captured *before* a protect rule existed still reflects that content until the source row is purged. Read-time redaction protects the CLI's output, and the worker reads through the CLI, so newly-built derived rows inherit today's rules — but rows built by an earlier consolidation pass, under weaker rules, do not retro-redact. `purge --apply-rules` removes both halves; a rebuild fixes the rest.

## 5. Network, and what a remote provider means

Revision 1's decisions table said `Network | Zero` and then, two rows above, named an Ollama fallback and "DeepSeek V4 Flash via your provider"; the consolidation plan listed `httpx` for an "OpenAI-compatible API". That is three claims that cannot all be true.

The accurate statement:

- **The Swift engine in this repo has no network code, and that is a hard non-negotiable.** Not for telemetry, updates, or "just fetching". Nothing in this design changes it: the engine's only new I/O is deleting rows from a local file.
- **The consolidation and embedding worker lives in the separate Python repo** ([openrhyme-mcp](https://github.com/OpenRhyme/openrhyme-mcp)). The non-negotiable scopes to this repo, so an HTTP call there is **not automatically a violation** — but the spec has to say that out loud rather than claim a zero that is not true.
- **By default the worker talks only to `localhost`** — Ollama or a local OpenAI-compatible server. That is still a network call in the literal sense (a socket, an HTTP request, a process that could be something other than what you think is listening on that port). Calling it "zero network" is the kind of overclaim that erodes trust when someone runs `lsof` and finds a connection.
- **A remote provider means captured screen content leaves your machine.** Every session the worker consolidates is sent, as text, to whatever endpoint is configured. That text is the redacted projection (§6), not raw — but a redacted projection of what you read all day is still an extraordinarily intimate document, and once it is sent, no OpenRhyme command can delete it.

Therefore:

| Rule | Behaviour |
|---|---|
| Default | `provider_endpoint` defaults to `http://localhost:11434`. A non-localhost endpoint is **refused at startup** unless `allow_remote_provider: true` is also set. |
| Consent | Turning it on is a two-key edit, not one — the endpoint plus an explicit acknowledgement flag whose name says what it does. |
| Visibility | `openrhyme privacy` and `status` report `provider: local` or `provider: remote (api.example.com)`. The worker logs the endpoint on every run. |
| Posture record | A change from local to remote is recorded the way `daemon.started` records the privacy posture, so history can answer "was my screen being uploaded during that stretch?" |
| Honesty | The README states, in the Privacy register: with a remote provider configured, your redacted activity summaries are sent to that provider and OpenRhyme cannot delete them again. |

## 6. Redaction inheritance and the CLI boundary

### 6.1 The worker reads through the CLI — deliberately

The privacy slice removed the MCP server's direct SQLite access on purpose (privacy spec §5.9): `store.py`'s `query_events`/`open_readonly` were deleted, and `events` now shells out to `openrhyme events --json`. The consolidation worker and the search indexer follow the same rule, and it is a **feature, not an inconvenience**:

- Everything the worker sees has already been through **read-time redaction**, so a secret captured before a rule existed is redacted on the way into the derived store too. The derived store inherits every improvement to the rules for free.
- There is exactly one chokepoint to audit. A second reader with its own SQLite handle would be a second policy implementation to keep in sync, and the one that drifts is the one that leaks.

### 6.2 The worker must never pass `--ignore-privacy`

`--ignore-privacy` exists for one purpose: letting the **owner** audit their own store from a terminal, with a stderr warning, to confirm a purge worked. It must never appear in the worker, the MCP server, a launchd plist, a config default, or a test fixture that could be copied into production. An automated background process that quietly reads the unredacted store, summarises it with an LLM, and writes the result to a second file is precisely the bypass the privacy slice closed.

The same applies to `--max-value-chars`: the worker passes an explicit bound; it does not reach for `0` (full text) to "get better summaries".

### 6.3 What a protected context looks like to a consolidator

A protected context produces a **marker row with no content at all** — no window title, document, URL, role, element title, value or selected text; only `pid`/`bundle_id`/`app_name` plus `extra.protected`, `extra.protectedBy`, `extra.reason` and `extra.fingerprint`. Consecutive protected heartbeats dedup to one marker.

So a session spent in 1Password looks, to the worker, like a handful of contentless rows. That is correct and must be preserved:

- The worker treats markers as **evidence of time spent, never as missing data**. A summary for such a session says the app was in use and its content is protected. It does not guess, does not infer from surrounding sessions, and does not extract entities from the app name plus imagination.
- **Nobody "fixes" empty sessions by reaching around the CLI into SQLite.** There is nothing to find: the content was never read into the daemon's memory in the first place (privacy spec §4). A future contributor who sees empty sessions and reaches for `sqlite3` will get the same empty rows and will have broken the redaction boundary for nothing.
- A session whose events are *all* markers should produce a summary and no facts. Facts extracted from a protected session are hallucinations by construction.
- `protected_event_count` on the session record (§3.1) makes this visible to the agent, so "I can see you were in a protected app for 20 minutes" is answerable without pretending to know more.

## 7. Bounding growth honestly

Revision 1's risks table claimed supersession "prunes stale facts at write time". It does not: the schema only sets `superseded_by`, nothing is deleted, and the store grows monotonically. Two corrections, and the claim now matches the mechanism:

- **What supersession actually does** is bound what a *query* returns. `idx_facts_current` makes "current facts" cheap; stale rows stay on disk and stay searchable through `facts_fts` unless something removes them.
- **The mechanism that bounds disk** is a compaction pass at the end of each consolidation run: delete facts where `superseded_by IS NOT NULL AND superseded_at < now - fact_history_days` (default 30), plus their provenance rows, then rebuild the FTS tables and VACUUM on a schedule. Entities and edges with no surviving facts are removed in the same pass.
- **The real bound**, though, is D1 (§4.1): derived rows never outlive their source events, so with `capture.retention_days` set, the derived store inherits the same horizon automatically. With retention off, both stores grow — which is the honest answer, and the same answer the events store already gives.

## 8. Phases

| Phase | What | Who | LLM cost | Delivers |
|---|---|---|---|---|
| **0** | Sessionize: idle-gap detection in the engine CLI. New `openrhyme sessions` command. New MCP `sessions` tool. | Swift engine + MCP | None | Agents see activity units, not raw event logs |
| **0.5** | **Deletion contract in the engine**: `purge` and the retention sweep clean `semantic.sqlite`; `privacy`/`status` report it; permissions enforced. Ships *before* anything writes a derived row. | Swift engine | None | D1 holds from the first derived row ever written |
| **1** | Hybrid search: FTS5 + embeddings over the redacted projection in `semantic.sqlite`, RRF fusion. New MCP `search` tool. | MCP server only | None (on-device embeddings) | "Find me the error from last week" works |
| **2** | Semantic consolidation: background worker reads new sessions, calls a local LLM to extract facts, builds the semantic store. New MCP `facts` and `ask` tools. | MCP server + launchd | ~30 calls/day (workday) | Agent knows your projects, patterns, decisions |
| **3** | Knowledge graph: entity resolution, edge construction, graph traversal. New MCP `graph_traverse` tool. | MCP server | None (LLM already extracted entities in Phase 2) | Multi-hop: "What was I doing before I started debugging the scheduler?" |

**Phase 0.5 is a gate, not a suggestion.** No phase that writes to `semantic.sqlite` ships before the engine can delete from it. Building the store first and adding deletion later is how the original defect happened; it is also how a user ends up with months of underived-but-undeletable summaries at the moment the mechanism finally lands. Phases 0 and 1 are worth doing alone; Phase 3 is optional sugar.

## 9. MCP tool surface (final)

| Tool | Phase | Input | Returns |
|---|---|---|---|
| `events()` | ✅ (existing) | `since`, `until`, `kinds`, `app`, `limit`, `max_value_chars` | Raw events, redacted by the engine |
| `status()` | ✅ (existing) | — | Engine + MCP status |
| `apps()` | ✅ (existing) | — | Allowlist + running apps |
| `allow_app()` / `deny_app()` | ✅ (existing) | `bundle_id` | — |
| `sessions()` | 0 | `since`, `until`, `app`, `limit` | Activity session list, incl. `protected_event_count` |
| `search()` | 1 | `query`, `since`, `kinds`, `app`, `limit` | Ranked event results with relevance scores |
| `facts()` | 2 | `query`, `since`, `entity`, `limit` | Structured facts from the semantic store |
| `ask()` | 2 | `query` | RAG over semantic store: summary answer with citations |
| `graph_traverse()` | 3 | `entity`, `hops`, `edge_types` | Subgraph of related entities + edges |

No tool exposes `--ignore-privacy`, and none opens either SQLite file directly.

## 10. Privacy & trust boundaries

- **Sessionization** runs on the user's machine, no network, no model.
- **Embeddings** use Apple's on-device model (macOS 14+), falling back to Ollama on localhost. Nothing leaves the machine.
- **Consolidation** calls an LLM that is local by default; a remote provider is an explicit opt-in with the consequences in §5.
- **Everything the worker reads has been redacted by the engine** (§6.1), and a protected context yields nothing to read (§6.3).
- **The derived store is `0600` in a `0700` dir**, applied on create and corrected on existing files by both the engine and the worker — the events store shipped `0644` for weeks before the privacy slice caught it, and the fix had to handle *existing* files, not only new ones. The derived store is arguably the more sensitive of the two: a summary distils what raw rows only imply. "Read the last month of my activity" is work; "read the six-sentence summary of my last month" is not.
- **The derived store is deletable, not merely disposable** (§4). It is also still disposable: `rm semantic.sqlite` and re-consolidate remains valid, and the engine sets `rebuild_required` when it has deleted from it.
- **Supersession prevents factual drift** in what a query returns; §7 says what bounds the disk.

## 11. Relationship to the repo's non-negotiables

### 11.1 "Sessionize by activity coherence, never by fixed time windows"

Idle-gap detection **satisfies** this rule; it does not bend it. The non-negotiable exists to forbid calendar bucketing — hourly or daily rollups that shred a task spanning lunch. A gap is a property of the activity stream itself: the boundary lands where the user stopped, wherever that falls, and a session may be four minutes or four hours. Nothing in this design buckets by clock time.

Stated honestly, though, an idle gap is a *weaker* form of coherence than `docs/computer-history-spec.md` §6.1 imagined ("bursts of related app/file/window switches"). A gap-free stretch in which you switch from one project to an unrelated one is one session under this rule. That is a known limitation, not a hidden one: Phase 2's LLM can split a session it recognises as two activities, and the session key stays stable because it is derived from the first event of each resulting block. If a future slice adds coherence signals (project/document change, app-cluster change), it strengthens the boundary rather than replacing the mechanism.

### 11.2 "No bundled LLM and no inference in the capture path"

The old wording — *"No bundled LLM and no inference in `Compact`. The rollup is deterministic; prose is the agent's job."* — is stale in two ways: `Compact` is retired by this design, and this design does propose an LLM in the consolidation worker. Read literally, a future session would conclude this PR violates a non-negotiable. The rule is rewritten in `CLAUDE.md` to say what is actually load-bearing:

- **The capture path and the whole Swift engine stay inference-free.** No bundled model, no inference, no model call from any process in this repo. That constraint is real and unchanged: the daemon holds the Accessibility grant, and the one privileged process does not get an inference engine bolted to it.
- **The consolidation worker, in the separate Python repo, may use a local model.** It holds no TCC grants, reads only the redacted CLI projection, and writes only the derived store.

Nothing here weakens the capture-path rule; it narrows the sentence to the thing it was actually protecting.

### 11.3 `Compact` is retired

`Sources/Compact` never grew past a placeholder (one comment file, an empty test target). Its job — sessionization, dedup, idle dropping, collapse — is done by idle-gap sessionization on read (Phase 0) plus the worker's consolidation (Phase 2). The target is left in `Package.swift` for now because removing it is a code change and this is a documentation revision; `CLAUDE.md` describes it as the retired placeholder it is. The privacy spec's deferred note — "Compact and the summary tool, which must consume the redacted projection when they land" — is satisfied by §6.1: the successor reads through the CLI.

## 12. Risks

| Risk | Mitigation |
|---|---|
| **Derived rows survive a purge of their source events** | §4 in full: mandatory provenance, engine-side deletion in the same command, VACUUM + checkpoint, whole-file fallback, loud failure. Tested by purging a fixture and asserting zero surviving derived rows *and* zero surviving tokens in the rebuilt FTS index. |
| **A derived store predating the contract exists on disk** | The engine treats a missing/unsupported `deletion_contract_version` as "cannot clean selectively" and removes the file (§4.5). An unknown derived store is never left in place. |
| Event ids are reusable (`INTEGER PRIMARY KEY`, no `AUTOINCREMENT`) after a purge that removes the newest rows | Every provenance match uses `(id, ts)`, never id alone (§3.1). Recorded as a follow-up: schema v2 should use `AUTOINCREMENT`, which needs a version bump and migration. |
| `idle_timeout` changes and every session key shifts | `meta.idle_timeout_s` records what the store was built with; a mismatch sets `rebuild_required` and the worker rebuilds rather than accumulating two incompatible generations of keys. |
| LLM hallucinates facts from events | Every fact carries `session_key` and a provenance range — the agent can drill to raw events with `events()` and verify. Facts from all-protected sessions are forbidden by construction (§6.3). |
| A remote provider is configured by accident | Refused unless explicitly acknowledged; reported by `status`/`privacy`; recorded in the posture history (§5). |
| Embedding quality suffers on short/noisy AX text (URLs, single words) | FTS5 catches exact strings. Hybrid search means one modality backs the other. |
| `NLContextualEmbedding` unavailable (macOS < 14 or pre-download) | Fallback to an Ollama embedding model on localhost. Configurable. |
| Semantic store grows unbounded | §7: supersession bounds queries; a compaction pass bounds disk; D1 plus `capture.retention_days` bounds the horizon. Not "supersession prunes at write time" — it does not. |
| Redacted text is embedded, so `[redacted:aws-key]` becomes a searchable token | Accepted and preferable to indexing the secret. The redaction marker is a useful signal in its own right; the structural rules are the thing to improve if it is noisy. |
| User has no local LLM | Phases 0, 0.5 and 1 need none. Phase 2 requires one — the same requirement as every other personal AI tool, and the agent host already provides one. |
