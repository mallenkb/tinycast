# Fork status

This repository is [mallenkb/tinycast](https://github.com/mallenkb/tinycast), an independent fork of
[abue-ammar/tinycast](https://github.com/abue-ammar/tinycast). Contact the fork maintainer at
[@mallenkb on X](https://x.com/mallenkb).

## Releases 0.1.0 through 0.1.3

Version 0.1.1 binds the update cache to this fork and rejects assets from other repositories. This
prevents a cached upstream version from appearing after switching to the fork.

Version 0.1.2 adds a searchable dictionary selector that remembers the preferred source, the native
Dictionary icon in the empty state, and memory reclamation after searches and Settings activity.

The first fork release includes rich clipboard link previews with Open Graph images, rendered SVG
previews and type labels, live launcher file results, system or Inter Variable typography, and palette
and caret refinements. It also includes redesigned feature icons, grouped Settings navigation, and
memory improvements.

The universal DMG and updater ZIP support Apple silicon and Intel on macOS 26 or later. The source
for the packaged build is available at each release tag. Build and signature validation do not establish
that every feature has passed runtime testing.

## Release 0.1.4

Version 0.1.4 includes application changes through upstream commit `a9eb610f`, immediately before
its notarization change. This includes atomic imports and cancellation fixes, extension authentication
and runtime compatibility, OpenAI Responses/MCP handling, consent-aware deeplinks, rich-text clipboard
capture, window-edge/fullscreen display commands, OpenCode MCP support, thinking expansion and native
glass/shadow updates. The fork's dictionary selector, feature artwork, memory policy and update feed
remain in place. Developer ID signing, notarization and upstream publishing workflows are excluded.

Local validation on 5 November 2026 passed 119 background harnesses, the JavaScript runtime fixtures,
lint and localization checks. The final Debug and Release builds passed without new Swift warnings.
Onboarding focus and the form-input pixel check were omitted from the background run. Live provider
calls and multi-display window moves still need manual verification.

The inactive memory probe exercised three rounds of dictionary searches and General, Applications
and Commands settings, followed by HTML/RTF conversion. Two Release runs peaked at 73.3 MB; closing
Settings returned them to 48.2–49.5 MB, matching the warmed dictionary baseline. They settled at
43.4–43.7 MB after all windows closed. Final Debug peaked at 93.2 MB and settled at 62.9 MB.
Every Settings hosting controller was released. These are macOS physical-footprint measurements in decimal MB; no helper processes
appeared during this workload. An earlier Debug run reached 102.5 MB, so a strict ceiling across runs
is still unproven. The measured Release snapshot predates only two lint-equivalent UTF-8 decoding
edits; the final Debug snapshot matches the current production source.

## Memory

The local optimization work limits decoded preview sizes and cache retention, cancels obsolete file
searches, and releases Settings content and icon caches on close. Closing a window releases owned
resources; the operating system may retain freed allocations in the process footprint.

The target is a small footprint without changing the search experience. Memory depends on the data,
active screen, and operating system, so an unconditional under-100-MB claim is not made here.

## Distribution status

- Downloads and update checks use `mallenkb/tinycast` releases.
- Release builds use `com.tinycast.app`, the same identity as upstream stable. Dev builds use
  `com.tinycast.app.dev` and keep separate data.
- Releases are packaged locally with the fork's self-signed certificate. It is not notarized.
  Installation instructions are in the README and release notes.
- GitHub Actions validates pushes and pull requests and provides a manual signed release workflow.
  It uses fork release assets and does not update upstream taps, websites, or announcements.
- Original author credit and third-party notices remain in the app and repository.

## Attribution

Original author: [Abue Ammar](https://github.com/abue-ammar).
Original project: [Tinycast](https://github.com/abue-ammar/tinycast).
Fork maintainer: [mallenkb](https://github.com/mallenkb).

The original copyright notice, AGPL-3.0-or-later license, contributor history, and existing contributor
agreement are preserved. This fork’s release and support channels are separate from upstream.
