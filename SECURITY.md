# Security Policy

## Reporting a Vulnerability

For this fork, report privately through
[GitHub vulnerability reporting](https://github.com/mallenkb/tinycast/security/advisories/new).
Do not include credentials or private clipboard content in public issues or X posts.

Include your macOS version, the Tinycast version and channel, reproduction steps, and the impact.
Please don't disclose publicly until it's fixed.

We'll respond as quickly as we can and keep you posted.

## Supported Versions

This fork has no published stable or beta binaries yet. Report against the current `main` branch
and include the commit hash. Upstream Homebrew packages install the original project.

## Scope

Of particular interest:

- **Accessibility (TCC)** — anything that widens what the paste grant enables.
- **Clipboard history** — text and images cached on disk; unintended exposure or capture.
- **Network** — Tinycast is offline by default and every networked feature is consent-gated. A path
  that reaches the network without consent, or survives consent being withdrawn, is high severity.
- **Hotkeys** — the in-house hotkey stack and the Input Monitoring grant.
- **Signing and distribution** — the DMG and Homebrew cask chain.

Out of scope: builds being self-signed rather than notarized (known, see
[`docs/signing.md`](docs/signing.md)), and anything needing existing code execution or admin rights on
the machine.
