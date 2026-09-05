# Sessionize — Phase 0 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md`
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
        "id": 1,
        "start": "1735699200.0",
        "end": "1735700400.0",
        "duration_s": 1200,
        "app_count": 3,
        "event_count": 847,
        "bundle_ids": ["com.apple.TextEdit", "com.apple.Safari", "com.microsoft.VSCode"],
        "dominant_kind": "context.snapshot"
      }
    ],
    "count": 1
  }
}
```

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
  session_group + 1 AS id,
  MIN(ts) AS start_ts,
  MAX(ts) AS end_ts,
  COUNT(DISTINCT bundle_id) AS app_count,
  COUNT(*) AS event_count,
  json_group_array(DISTINCT bundle_id) AS bundle_ids,
  -- dominant kind
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

The `--app` filter becomes a WHERE clause on `bundle_id` before gap computation.

**Implementation details:**
- New file: `Sources/openrhyme/SessionsCommand.swift` (~80 lines)
- Reuses the existing `EventStore.query()` pattern, but wrapped in a new `SessionStore` function
- No new module or dependencies. Pure SQL computation on a read-only connection.
- `--persist` flag: writes session boundaries back to a `sessions` table (for the consolidation worker in Phase 2). Without it, sessions are computed on read.

**Test:**
- Create 10 events with known timestamps: 5 within a 4-minute window, 2-minute gap, 5 more within a 4-minute window
- Assert 2 sessions returned
- Verify boundary timestamps, app_count, event_count

### MCP server (Python)

**New tool: `sessions(since, until=None, app=None, limit=50)`**

Calls `openrhyme sessions --since <time> [--until <time>] [--app bundle] --limit N --json` and returns `{"sessions": [...], "count": N}`. Follows the same engine-CLI pattern as `events()`: shells out, unwraps the JSON envelope.

**Implementation details:**
- New file: new method in `server.py` or a `SessionsTool` module
- Reuses the same `_engine()` wrapper, `_parse_time()` helpers
- ~30 lines

**Test:**
- Fake engine returns known sessions JSON
- Assert tool returns correct shape
- Assert CLI invocation includes expected flags

### No changes needed

- Engine schema: sessions are not stored by default. Only the `--persist` flag writes them.
- Data directory: no new files unless `--persist` is used.
- Existing MCP tools: unchanged.

## Acceptance criteria

1. `openrhyme sessions --since 1h --json` returns the correct session boundaries for that hour.
2. An agent asking "what sessions did I have this morning?" gets a coherent answer via the MCP `sessions` tool.
3. 5-minute idle timeout is the default; configurable via `--idle-timeout` or `config.json`.
4. `make build && make test && make lint` pass.
5. CI green.

## Future (Phase 2 depends on this)

The `--persist` flag materializes session boundaries that the consolidation worker reads. Without Phase 2, sessions are purely query-time and leave no trace on disk.