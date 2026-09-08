# Derived-data deletion — Phase 0.5 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md` §4 (revision 2)
**Also read:** `docs/superpowers/specs/2026-09-03-privacy-controls-design.md` §5.6/§5.7/§5.8 and the README's Privacy/Limits sections. This plan extends machinery that slice built; it should reuse it, not reinvent it.
**Status:** proposed. **Gate: no phase that writes to `semantic.sqlite` ships before this does.**

## Goal

Make invariant **D1** true and enforced:

> No derived row outlives the events it was derived from. A deletion command must not report success while the data it promised to remove is still readable somewhere.

Concretely: after `openrhyme purge --app com.1password.1password --yes`, there is no summary in `semantic.sqlite` describing what happened in 1Password, and no FTS token left over from one.

## Why the engine and not the Python worker

The guarantee cannot depend on a separate process, in a separate repo, being installed, scheduled or reachable. A user who deletes the MCP server still has a `semantic.sqlite`. The engine already resolves the data dir, already owns `purge` and the retention sweep, and already has the lock-retry, `VACUUM` and `wal_checkpoint(TRUNCATE)` machinery — built, in the privacy slice, for exactly this class of bug. Deleting rows by provenance is neither inference nor network: both non-negotiables hold.

## What changes

### 1. `Sources/Store/DerivedStore.swift` (new, ~200 lines)

A small, deliberately dumb reader/deleter for `semantic.sqlite`. It understands `meta` and `derived_provenance` and nothing else about the schema — it never reads a summary or a fact body.

```swift
public struct DerivedDeletionOutcome: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        case absent                              // no derived store on disk
        case cleaned(rows: Int, sessions: Int, perTable: [String: Int])
        case removedWholeFile(reason: String)    // contract unreadable → file unlinked
        case failed(reason: String)              // could do neither — caller must not claim success
    }
    public var disposition: Disposition
    public var vacuumed: Bool
    public var checkpointed: Bool
}

public struct DerivedStore {
    public static func openIfPresent(dataDir: URL) throws -> DerivedStore?
    public func deleteMatching(_ selector: DerivedSelector) throws -> DerivedDeletionOutcome
    public func summary() throws -> DerivedSummary       // counts, size, last_run_ts, orphans, provider
}
```

`DerivedSelector` mirrors the purge selectors: `.timeRange(since:until:)`, `.app(bundleID:)`, `.eventIDs([(id, ts)])` (for `--url-contains` / `--apply-rules`), `.all`, `.olderThan(cutoff)`.

**Matching is always `(id, ts)`, never id alone.** `events.id` is `INTEGER PRIMARY KEY` without `AUTOINCREMENT`, so a purge that removes the newest rows frees those ids for reuse; an id-only match can come to mean a different event. Add a test that purges the tail of a fixture, writes new events, and asserts no derived row is matched by a reused id.

**Bias to over-deletion.** A derived row with *any* provenance edge intersecting the purged set is deleted, even if it also drew on surviving events. The survivors regenerate it on the next consolidation pass. Over-deletion costs recomputation; under-deletion is the failure this plan exists to prevent. The outcome reports the amplification (`rows`, `sessions`) so it is visible.

**Table-name safety.** The engine only deletes from tables listed in `meta.content_tables`, and validates each name against that list before interpolating it. A table present in the file but absent from `content_tables` means the contract is not being honoured → whole-file removal (below).

### 2. Deletion sequence (`DerivedStore.deleteMatching`)

1. `chmod 0600` the file and its `-wal`/`-shm` before anything else.
2. Read `meta.deletion_contract_version`; if missing, unparseable or newer than supported → **whole-file removal**.
3. One transaction: select `(row_table, row_id)` from `derived_provenance` matching the selector; `DELETE` from each declared content table; delete matching provenance rows; delete from each `meta.vector_tables` entry; `purge_epoch += 1`; `rebuild_required = 1`.
4. `INSERT INTO <fts>(<fts>) VALUES('rebuild')` for every table in `meta.fts_tables`. **This step is not optional**: an external-content FTS5 index keeps the tokens of rows deleted out from under it, which is the same "deleted but still readable" bug in a different file.
5. `VACUUM`, then `PRAGMA wal_checkpoint(TRUNCATE)`, each through `PurgeCommand.retryOnBusy` / `retryUntilTrue`. In WAL mode `VACUUM` rewrites into the WAL; without the truncating checkpoint the deleted text stays in the file. This is the first of the privacy slice's five defects, and it applies here verbatim.
6. Return the outcome. `vacuumed`/`checkpointed` are reported as they actually happened, never assumed.

### 3. Three outcomes, none of them a silent success

| Situation | Behaviour | Reported as |
|---|---|---|
| Contract intact | Surgical delete + FTS rebuild + VACUUM + checkpoint | `cleaned`, with counts |
| Cannot open / no `meta` / no `derived_provenance` / unsupported version / undeclared content table | **Unlink `semantic.sqlite`, `-wal`, `-shm`** | `removedWholeFile(reason)`, with the reason printed in plain language |
| Locked past the retry window, or unlink fails | Do not pretend | `failed(reason)`, non-zero exit, the path named, no success line |

Whole-file removal is safe precisely because all derived state lives in one file (spec §4.7) and the store is rebuildable. `failed` is the "told plainly, not silently deferred" branch: the events deletion still happened and is reported as partial, with the retry command.

### 4. `Sources/openrhyme/PurgeCommand.swift`

- After the events deletion, run the matching derived deletion and fold the outcome into the report.
- `--dry-run` reports derived counts too. A dry run that showed only event counts would be the "report advising a command that would delete nothing while claiming it worked" defect, one level up.
- `--json` gains the `derived` object from spec §4.4.
- Human output gains one line, and never prints a success line when the disposition is `failed`.
- Exit code: `failed` → non-zero, even when the events deletion succeeded.

### 5. `Sources/openrhyme/DaemonCommand.swift` — retention sweep

- Extend `RetentionSweepOutcome` with the derived disposition; add a `derivedReclaimIncomplete` case reported through `onError`.
- Selector is `.olderThan(cutoff)` — any derived row with `start_ts < cutoff`, so a session straddling the cutoff loses its derived rows too.
- Never throws; a derived-store failure must not wedge the capture loop, exactly like the existing sweep.
- **The first-sweep-after-enabling skip notice must name the derived rows that would go, not just the events.** The skip exists to give the user one full review window; showing half the picture is how a count comes to read as reassurance.
- The clock guard applies unchanged — it gates the whole sweep, derived rows included.

### 6. `Sources/openrhyme/PrivacyCommand.swift` and `StatusCommand.swift`

`privacy` gains a derived-store section (spec §4.8): present/absent, path, size on disk, row counts per content table, `last_run_ts`, `deletion_contract_version`, provider kind and host (`local` / `remote (host)`), and an **orphan count** — derived rows whose source events no longer exist, matched on `(id, ts)`. A non-zero orphan count names the command that fixes it.

`status` gains one line: present/absent and size.

Both are read-only and must never create, migrate or write the derived store — the same rule `privacy` already follows for `events.sqlite`.

Wording discipline, learned five times over: none of these counts is a clean bill of health. `0 derived rows` means "nothing derived is stored", not "nothing sensitive is stored", and the human output says so on the same line, the way `stored_rows_matching_rules` already does.

### 7. Permissions

`Paths.ensureDataDir()` already forces `0700`. Add `semantic.sqlite` (+ `-wal`/`-shm`) to the `0600` correction that `EventStore` performs on open, applied by every engine command that touches the derived store, and **on existing files, not only new ones** — the events store shipped `0644` for weeks and the fix had to handle installs that already existed. The Python worker chmods on its own opens too; belt and braces, because an install whose worker predates the rule still gets corrected by the engine.

## Tests

- `DerivedStoreTests`: each selector deletes exactly the intended rows; over-deletion of a straddling row is asserted, not accidental; provenance rows go with their content rows; FTS `'rebuild'` leaves no orphaned token (query the FTS table for a purged term and assert zero hits — the whole point); `VACUUM`/checkpoint reported honestly when they fail.
- Contract-failure fixtures: no `meta`; `deletion_contract_version` = 999; missing `derived_provenance`; a content table absent from `content_tables`. Each asserts whole-file removal *and* that no `.sqlite`, `-wal` or `-shm` survives.
- Locked-file fixture: assert `failed`, non-zero exit, no success line on stdout.
- Rowid-reuse fixture: purge the tail, insert new events, assert no derived row matches a reused id.
- `CLITests`: `purge --dry-run` reports derived counts and deletes nothing from either store; `purge --apply-rules --yes` on a fixture leaves zero derived rows for the purged session; `privacy --json` shape includes the derived block; `status` line present.
- Retention: sweep with a derived store present removes matching derived rows; the first-run skip notice names both counts.
- End-to-end regression for the defect this exists to prevent: build a fixture with a protected-app session and a summary derived from it, purge by app, assert the summary is gone from the table **and** from the FTS index, and that the reported success is only printed when both are true.

## Acceptance criteria

1. `openrhyme purge` in every selector mode removes matching derived rows, rebuilds FTS, vacuums and checkpoints `semantic.sqlite`, and reports counts.
2. A derived store the engine cannot understand is removed entirely, with the reason stated plainly.
3. A derived store the engine can neither clean nor remove produces a non-zero exit and no success claim.
4. The retention sweep does the same automatically, and its first-run skip notice names derived rows.
5. `openrhyme privacy` and `status` show the derived store, including orphans and provider kind.
6. `semantic.sqlite` is `0600` in a `0700` dir, corrected on existing installs.
7. No LLM, no network, no new dependency in the Swift engine.
8. `make build && make test && make lint` pass; CI green.

## Out of scope

- Changing `events.sqlite`'s schema. The `AUTOINCREMENT` fix for rowid reuse is a v2 concern with a version bump and migration; this plan works around it with `(id, ts)` matching.
- Writing anything to the derived store. The engine only ever deletes from it.
