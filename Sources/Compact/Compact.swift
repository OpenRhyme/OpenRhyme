// Compact — the deterministic, inference-free layer.
//
// Sessionization by activity coherence (not fixed time windows), deduplication,
// idle-stretch dropping, repeated-event collapsing. Target: ~10x volume reduction
// before any agent sees the data. Pure functions over Store rows; no I/O beyond
// what Store provides, no network, no model calls.
//
// Reference: docs/computer-history-spec.md §6
