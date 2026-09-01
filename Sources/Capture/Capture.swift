// Capture — macOS accessibility (AXUIElement / AXObserver) and input-activity
// (listen-only CGEventTap) capture.
//
// Owns: TCC trust checks + recovery, one AXObserver per allowed app, the event tap,
// per-app quirks (Electron AXManualAccessibility, text-attribute fallback order).
// Emits: a stream of plain, Sendable raw events. Never exposes AXUIElement outward.
// Knows nothing about storage, sessions, or agents.
//
// Reference: docs/accessibility-api.md
