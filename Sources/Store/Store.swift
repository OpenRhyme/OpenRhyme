// Store — the three storage tiers.
//
//   HOT   raw events, ~1 day, SQLite (WAL)
//   WARM  session-level summaries / semantic memory, SQLite + FTS5
//   COLD  raw archives on disk, drilled into on demand, auto-cleaned
//
// The SQLite schema is a public contract: the Python MCP server opens the database
// read-only. Schema changes are versioned and migrated; see docs/engine-interface.md.
