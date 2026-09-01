# Security policy

OpenRhyme's proposition is that it can read almost everything on your screen and never sends it anywhere. That makes security bugs product-defining, not incidental.

## Guarantees this project intends to keep

- **No network I/O in the engine.** No telemetry, no update check, no cloud tier.
- No screenshots, microphone, camera, or system audio.
- No raw keystroke logging. Input capture is aggregated activity; text content comes from the accessibility tree, which is field-aware, so secure text fields are excluded.
- Data lives under the user's home directory in SQLite files the user can inspect and delete.
- The per-app allowlist is enforced by the daemon, because macOS cannot enforce it.

A change that weakens any of these is a security issue even when intentional — it must be discussed in the open first.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository (**Security** tab → **Report a vulnerability**). Include the macOS version, how the daemon was launched (terminal or launchd), and reproduction steps. Do not open a public issue for anything that could expose captured data.

You will get an acknowledgement within a few days. There is no bug bounty.

## Scope

In scope: the Swift engine in this repository, its on-disk formats, and the command-line surface the MCP server drives. The Python MCP server has its own repository and policy.
