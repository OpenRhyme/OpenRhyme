# Knowledge graph — Phase 3 implementation plan

**Spec:** `docs/superpowers/specs/2026-09-04-semantic-layer-design.md` (revision 2)
**Also read:** `docs/superpowers/specs/2026-09-03-privacy-controls-design.md`.
**Depends on:** Phase 2 (semantic consolidation) for entity extraction, and therefore on **Phase 0.5** (`docs/superpowers/plans/2026-09-04-derived-data-deletion.md`) beneath it.
**Status:** proposed.

## Goal

Link extracted entities into a queryable graph, enabling multi-hop reasoning: "What project was I working on before I switched to debugging the scheduler?" Answer: RunaxAI frontend — the two entities are linked via "switched_from" and "switched_to" edges across adjacent sessions.

## What changes

### Schema (already defined in the spec)

Edge table in `semantic.sqlite`. Every edge, alias merge and derived entity is a derived row: it carries `derived_provenance` rows (spec §3.3) naming every session and bundle id that contributed, written in the same transaction as the edge itself. This is what lets `openrhyme purge` remove a graph edge whose only supporting session was just deleted.

A merged entity inherits the union of its members' provenance, not an averaged range. Entity resolution is the one place where merging is *lossy for deletion* if done carelessly: collapsing "scheduler" and "RunaxAI scheduler" into one row must not collapse their provenance, or purging one session would either over-delete a still-supported entity or leave a merged row half-derived from deleted events.

Two edge types:

- **Extraction edges** (from LLM output, Phase 2):
  - `entity_a uses entity_b` (project → tool)
  - `entity_a depends_on entity_b` (module → library)
  - `entity_a debugging entity_b` (user → crash entity)
  - `entity_a related_to entity_b` (co-occurring topics)

- **Derived edges** (inferred by the graph builder):
  - `entity_a switched_from entity_b` (session N entity → session N-1 entity)
  - `entity_a co_occurs_with entity_b` (>N sessions mention both)
  - `entity_a is_alias_of entity_b` (entity resolution merge)

### Graph builder

A new module in the MCP server that runs after each consolidation pass:

0. **Orphan sweep first:** drop entities and edges whose provenance points at events that no longer exist (matched on `(id, ts)`, never id alone — `events.id` has no `AUTOINCREMENT` and ids are reusable after a purge). Building a graph over stale nodes propagates deleted content into new edges.

1. **Entity resolution:** merge aliases (fuzzy name match + embedding similarity on entity descriptions). Example: "RunaxAI scheduler" and "scheduler" and "the scheduler module" → one canonical entity with aliases `["RunaxAI scheduler", "scheduler", "the scheduler module"]`. The merged row keeps every member's provenance rows.

2. **Co-occurrence edges:** for every pair of entities that appear in the same session, increment an edge weight. Above threshold, create a `co_occurs_with` edge.

3. **Temporal transition edges:** for consecutive sessions, link the dominant entity of session N to the dominant entity of session N-1 with `switched_from`.

4. **BFS graph traversal** for the MCP tool.

5. **Epoch check before commit:** re-read `meta.purge_epoch`; if it changed while the graph was being built, roll back and re-run. A purge that landed mid-build would otherwise be partly undone by edges derived from rows it deleted.

### New MCP tool

```python
@mcp.tool()
def graph_traverse(
    entity: str,
    hops: int = 2,
    edge_types: list[str] | None = None,
    limit: int = 50
) -> dict:
    """
    Traverse the knowledge graph from an entity, returning connected entities and edges.

    Returns:
    {
        "root": {"name": "scheduler", "entity_type": "project"},
        "nodes": [
            {"name": "RunaxAI", "entity_type": "project", "hops": 1, "edges": [...]}
        ],
        "edges": [
            {"source": "scheduler", "target": "RunaxAI", "edge_type": "part_of", "weight": 0.9}
        ]
    }
    """
```

Traversal is application-level BFS over SQLite:

```python
def _bfs(conn, root_entity_id, max_hops, edge_types_filter):
    visited = {root_entity_id: 0}
    queue = [(root_entity_id, 0)]
    nodes = []
    edges = []

    while queue:
        eid, hop = queue.pop(0)
        if hop >= max_hops:
            continue

        # Get connected entities
        rows = conn.execute("""
            SELECT e.id, e.name, e.entity_type, edge.edge_type, edge.weight
            FROM edges edge
            JOIN entities e ON (e.id = edge.target_entity AND edge.source_entity = ?)
                OR (e.id = edge.source_entity AND edge.target_entity = ?)
            WHERE edge.edge_type IN ?  -- or all if no filter
        """, (eid, eid, edge_types_filter or ALL_TYPES))

        for row in rows:
            edges.append(row)
            if row[0] not in visited:
                visited[row[0]] = hop + 1
                queue.append((row[0], hop + 1))
                nodes.append(row)

    return {"root": ..., "nodes": nodes, "edges": edges}
```

### What the graph must not become

A knowledge graph is an inference surface: it makes visible what no single row states. Two rules follow.

- **Protected time contributes no nodes.** A session of protected markers yields no entity and no edge — not even "user was in 1Password". The app identity is already in the raw timeline; promoting it into the graph, linking it to the entities of adjacent sessions, and letting `graph_traverse` walk from a project to a password manager reconstructs exactly what protection existed to prevent. `switched_from`/`switched_to` edges skip protected sessions rather than bridging across them with a labelled node.
- **Redaction markers are not entities.** A `[redacted:<rule>]` string is the absence of a value. It must never become an entity name, an alias, or an edge endpoint.

Both are asserted in tests, not left to the extraction prompt.

### Graph visualization (optional)

For the agent: return edges as a structured list, not a diagram. The agent can render it in text or ask for details. No diagram library needed.

## Implementation files

| File | What | Lines |
|---|---|---|
| `src/openrhyme_mcp/graph.py` | Orphan sweep, entity resolution, edge derivation, BFS traversal | ~220 |
| `src/openrhyme_mcp/server.py` | `graph_traverse()` tool | ~30 |
| `tests/test_graph.py` | Fixture entities/edges, test BFS, resolution, provenance, protected exclusion | ~140 |

## Acceptance criteria

1. Running graph build after consolidation produces at least `co_occurs_with` and `switched_from` edges.
2. `graph_traverse("scheduler", hops=2)` returns connected entities (RunaxAI, crash, task_queue).
3. Entity resolution merges "scheduler" and "RunaxAI scheduler" into one canonical entity.
4. Graph traversal on an empty semantic store returns a clean error, not a crash.
5. Every entity, alias merge and edge carries provenance; inserting one without it fails.
6. Purging the events behind a session removes the edges derived from it, and a merged entity supported only by purged sessions goes with them (verified against Phase 0.5).
7. A protected-marker session contributes no node and bridges no `switched_from` edge; a `[redacted:…]` string never becomes an entity.
8. No engine modifications needed beyond Phase 0.5.

## When to skip this phase

Phase 3 is optional. The `graph_traverse` tool is useful for multi-hop questions, but most agent queries are "what was I doing with X?" — single-hop, already answered by `facts()`. Build Phase 3 only after dogfooding Phase 2 reveals a concrete need for graph traversal. The entity resolution step (merge aliases) is the most valuable piece even without graph traversal — consider adding just that to Phase 2 as a cleanup pass.