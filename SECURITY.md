# Security policy

OpenRhyme's proposition is that it can read almost everything on your screen and never sends it anywhere. That makes security bugs product-defining, not incidental.

## Guarantees this project intends to keep

- **No network I/O in the engine.** No telemetry, no update check, no cloud tier.
- No screenshots, microphone, camera, or system audio.
- No raw keystroke logging. Input capture is aggregated activity; text content comes from the accessibility tree, which is field-aware, so secure text fields are excluded.
- Data lives under the user's home directory in SQLite files the user can inspect and delete.
- The per-app allowlist is enforced by the daemon, because macOS cannot enforce it.
- Sensitive contexts — password-manager apps, vault and credential URLs, `.env` and key files, credential-named fields — are **never read**, not read and discarded: the policy is checked before the content ladder runs, so the text never enters the process.
- Recognised secret shapes (AWS/GitHub/Stripe/Slack/Google/OpenAI/Anthropic keys, private-key blocks, JWTs, connection-string passwords, high-entropy tokens) are redacted from what is captured, and redacted again on every read — so a rule added today also protects rows captured before it existed.
- The data directory is `0700` and the database file `0600`, so no other local account can read them.
- The MCP server has no independent database access: it reads through the engine's own CLI, so nothing it returns can bypass redaction.

A change that weakens any of these is a security issue even when intentional — it must be discussed in the open first.

## Limits

Stated plainly, not implied:

- **Pattern detection is best-effort.** The redactor matches known secret shapes and a Shannon-entropy backstop; it will miss custom or unusual secret formats. Treat it as a safety net, not a guarantee.
- **Chrome Incognito is not detectable through the Accessibility API** — incognito windows expose no title or attribute the engine can reliably key off. Safari private windows are caught (their window title says so).
- **File permissions do not stop another process running as you.** `0700`/`0600` keeps out other user accounts on the machine, not other software running under your own account.
- **A backup you make is your responsibility.** Nothing here (redaction, permissions, purge) reaches into a copy you've made yourself — a `Time Machine` snapshot, a synced folder, an exported file.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository (**Security** tab → **Report a vulnerability**). Include the macOS version, how the daemon was launched (terminal or launchd), and reproduction steps. Do not open a public issue for anything that could expose captured data.

You will get an acknowledgement within a few days. There is no bug bounty.

## Scope

In scope: the Swift engine in this repository, its on-disk formats, and the command-line surface the MCP server drives. The Python MCP server has its own repository and policy.
