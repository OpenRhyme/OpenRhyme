# Sessionize — Phase 0 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md` (revision 2)
**Also read:** `docs/superpowers/specs/2026-09-03-privacy-controls-design.md` — this command reads the store the privacy slice hardened, and must not become a way around it.
**Status:** design approved; implementation plan below.

## Goal

Give agents activity units to work with instead of raw event logs. A session is a contiguous block of activity with no gap longer than `idle_timeout` (default 300 s).

## What changes

### Engine (Swift)

**New command: `openrhyme sessions --since <time> [--until <time>] [--app bundle] [--limit n] --json`**

Returns sessions derived from the events table:

```json
{
  "ok": true,
  "data": {
    "sessions": [
      {
        "session_key": "84213:1735699200.0",
        "first_event_id": 84213,
        "last_event_id": 85060,
        "start": 1735699200.0,
        "end": 1735700400.0,
        "duration_s": 1200,
        "app_count": 3,
        "event_count": 847,
        "protected_event_count": 12,
        "bundle_ids": ["com.apple.TextEdit", "com.apple.Safari", "com.microsoft.VSCode"],
        "dominant_kind": "context.snapshot"
      }
    ],
    "count": 1
  }
}
```

**`session_key` is `"<first_event_id>:<start_ts>"`, not an ordinal** (spec §3.1). Ordinals renumber on every re-run, and everything built on top of a session — every fact, summary and edge — would silently repoint after one purge. The pair also survives SQLite rowid reuse, which is real here: `events.id` is `INTEGER PRIMARY KEY` with no `AUTOINCREMENT`, so a purge that removes the newest rows frees those ids for reuse. Never match on an event id alone anywhere in this feature.

**Algorithm (pure SQL, no Swift loop):**

```sql
-- 1. Find gap boundaries: events where the gap to the next event > idle_timeout
WITH gaps AS (
  SELECT
    id,
    ts,
    LEAD(ts) OVER (ORDER BY ts, id) AS next_ts,
    CASE
      WHEN LEAD(ts) OVER (ORDER BY ts, id) - ts > 300 THEN 1  -- gap exceeds timeout
      ELSE 0
    END AS is_break
  FROM events
  WHERE ts >= ? AND ts <= ?
),
-- 2. Label each event with its session group
groups AS (
  SELECT
    id,
    ts,
    SUM(is_break) OVER (ORDER BY ts, id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS session_group
  FROM gaps
)
-- 3. Aggregate session boundaries and stats
SELECT
  MIN(e.id)  AS first_event_id,
  MAX(e.id)  AS last_event_id,
  MIN(e.ts)  AS start_ts,
  MAX(e.ts)  AS end_ts,
  COUNT(DISTINCT e.bundle_id) AS app_count,
  COUNT(*) AS event_count,
  SUM(CASE WHEN json_extract(e.extra, '$.protected') = 1 THEN 1 ELSE 0 END) AS protected_event_count,
  json_group_array(DISTINCT e.bundle_id) AS bundle_ids,
  (
    SELECT kind FROM events
    WHERE ts >= MIN(g.ts) AND ts <= MAX(g.ts)
    GROUP BY kind ORDER BY COUNT(*) DESC LIMIT 1
  ) AS dominant_kind
FROM groups g
JOIN events e ON e.id = g.id
WHERE e.ts >= ? AND e.ts <= ?
GROUP BY session_group
ORDER BY start_ts
LIMIT ?
```

`session_key` is formatted from `first_event_id` and `start_ts` in Swift, not in SQL.

The `--app` filter becomes a WHERE clause on `bundle_id` before gap computation.

**Implementation details:**
- New file: `Sources/openrhyme/SessionsCommand.swift` (~90 lines)
- Reuses the existing `EventStore.query()` pattern, but wrapped in a new `SessionStore` function
- No new module or dependencies. Pure SQL computation on a read-only connection.
- **This command reports metadata only** — counts, timestamps, bundle ids, kinds. It never returns `value`, `selected_text`, `window_title`, `document` or `url`, so there is no redaction decision to make and no `--ignore-privacy` flag to add. If a future revision returns any text from this command, it goes through the same read-time redaction `events` uses; nothing here gets its own text path.
- `--persist` writes session boundaries into **`semantic.sqlite`**, not into `events.sqlite`. The events schema is a public contract (v1) and gains no tables from this feature. Persisted sessions are derived rows like any other: they carry provenance (spec §3.3) and are removed by `purge` and the retention sweep (spec §4). If the deletion contract (Phase 0.5) is not yet in place, `--persist` is not implemented — see Ordering below.

**Tests:**
- Create 10 events with known timestamps: 5 within a 4-minute window, 2-minute gap, 5 more within a 4-minute window. Assert 2 sessions returned, with correct boundary timestamps, `app_count`, `event_count`.
- `session_key` stability: run sessionization twice over the same fixture, assert identical keys. Then delete an event from the *middle* of session 2, re-run, assert session 1's key is unchanged.
- Protected markers: a fixture where a whole session is `extra.protected` rows asserts `event_count == protected_event_count`, a real `bundle_ids` list, and no crash on the all-null text columns.
- Assert the command emits no text column in any output shape (a regression test against someone helpfully adding `value` later).

### MCP server (Python)

**New tool: `sessions(since, until=None, app=None, limit=50)`**

Calls `openrhyme sessions --since <time> [--until <time>] [--app bundle] --limit N --json` and returns `{"sessions": [...], "count": N}`. Follows the same engine-CLI pattern as `events()`: shells out, unwraps the JSON envelope. **It does not open SQLite** — the privacy slice deleted the MCP's direct database access on purpose (privacy spec §5.9), and nothing in the semantic layer reopens it.

**Implementation details:**
- New method in `server.py` or a `SessionsTool` module
- Reuses the same `_engine()` wrapper and `_parse_time()` helpers
- ~30 lines
- The docstring states that `protected_event_count` counts events from protected contexts whose content was never captured — so an agent reading a session with a high protected count says "that time is protected", not "that time is missing".

**Test:**
- Fake engine returns known sessions JSON; assert tool returns correct shape and the CLI invocation includes expected flags.
- Assert `--ignore-privacy` never appears in any constructed argument list (a cheap guard that stays true forever).

### No changes needed

- Engine schema: sessions are not stored in `events.sqlite`, ever. `--persist` targets the derived store.
- Existing MCP tools: unchanged.

## Acceptance criteria

1. `openrhyme sessions --since 1h --json` returns the correct session boundaries for that hour.
2. An agent asking "what sessions did I have this morning?" gets a coherent answer via the MCP `sessions` tool.
3. `session_key` is stable across re-runs over unchanged events.
4. Sessions that consist only of protected markers are returned normally, with `protected_event_count == event_count`.
5. 5-minute idle timeout is the default; configurable via `--idle-timeout` or `config.json`.
6. No text column appears in the output; no `--ignore-privacy` path exists in this command or its MCP tool.
7. `make build && make test && make lint` pass.
8. CI green.

## Ordering

Phase 0 without `--persist` writes nothing to disk and is safe to ship immediately. **`--persist` is gated on Phase 0.5** (the deletion contract in `purge` and the retention sweep, spec §4): the first derived row must not exist before the engine can delete it. Ship `sessions` read-only first if Phase 0.5 is not ready.
