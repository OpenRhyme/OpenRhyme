# Contributing

OpenRhyme is early. Contributions that move the spec forward, add per-app accessibility knowledge, or harden the capture loop are welcome. Read `docs/computer-history-spec.md` first — most "why" questions are answered there.

## Prerequisites

- macOS 14+ (development happens on macOS 26), Xcode 26.x with Swift 6.3 or newer.
- `swift format` ships with the toolchain; nothing else to install.

## Workflow

```sh
make build && make test && make lint
```

CI runs the same three steps on `macos-26`. `make format` rewrites files in place.

### Running against the real Accessibility API

- The binary needs **Accessibility** and **Input Monitoring**. When launched from a terminal, macOS attributes the request to the *terminal app* (the "responsible process") — granting it to Terminal/iTerm makes `swift run openrhyme` work, for development only.
- `swift build` produces ad-hoc-signed binaries whose grant resets on every rebuild. Use `tccutil reset Accessibility` or sign with a stable self-signed certificate. Details in `docs/accessibility-api.md` §2.
- Tests that need those grants must not run in CI: gate them behind an environment variable and unit-test the pure layers instead.

## Code conventions

- Swift 6 language mode, strict concurrency. `AXUIElement` and friends never cross an isolation boundary; `Capture` emits plain `Sendable` structs.
- Module boundaries are the spec's: `Capture` → `Store` ← `Compact`. Nothing in this repository makes a network call or invokes a model.
- Prefer Swift Testing (`import Testing`) for new tests.
- Formatting is `.swift-format`; the linter is strict in CI.

## Commits and pull requests

- One logical change per commit, with a short single-line message describing what changed. No attribution trailers or generated-by footers.
- PRs describe the change and how it was verified. Link the spec section if the change touches a design decision, and update the spec if the decision changed.
- Anything that widens what the daemon can see or where data can go needs a `SECURITY.md`-level justification in the PR.
