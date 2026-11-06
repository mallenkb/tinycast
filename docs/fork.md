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

## Release 0.1.5

Version 0.1.5 adds recorded English pronunciation through public Wiktionary and Wikimedia
Commons APIs without an API key. It includes Play/Stop, normal and slow playback, accent choices,
approximate Sounds like guides, original IPA, alternative pronunciations, and source/licence credits.
Stale work is cancelled and playback resources are released after use. Audio downloads on demand;
the previously suggested bounded persistent disk cache is not implemented.

Validation covers 123 background harnesses and the separately authorized onboarding focus test,
live recording downloads, default-volume normal/slow playback, passive layout and link checks,
and repeated muted playback with Settings. The final Release memory run peaked at 75.2 MB and
settled at 49.7 MB. The separately authorized rendered-control pass verified Play/Stop, Slow and accent switching,
including the updated recording source and licence.

## Release 0.1.6

Version 0.1.6 offers native system speech and recorded Wikimedia audio in one compact card
below the word. It shows one Sounds like guide, Play/Stop and Slow, with source/accent selectors.
Equivalent guides and accent labels are deduplicated. Source credits and licences are available
through the source menu. The native option does not wait for online phonetic metadata to play.

Native speech selects installed standard voices, preferring a shared US/UK public-name family.
Enhanced/premium, novelty and Personal Voice entries are excluded. Source switching stops the other
playback path. The background suite passed 127 harnesses; the unchanged onboarding focus harness
was not rerun for this change. The signed Dev build and localization/lint checks passed. The final combined-source Release probe
peaked at 90.0 MB including new speech/audio helpers, with a conservative lifetime-peak sum of
94.0 MB and a warmed closed combined footprint of 67.8 MB. The compact apple card passed passive
layout inspection.

Dark mode uses a deeper tint on the native palette glass and lower-opacity selection and hover fills.
Light mode is unchanged. The signed Debug build and 38 appearance assertions passed; a visual check
of the darker tint was not performed. The combined memory measurements above predate the tint change.

## Release 0.1.7

About has a separate Updates section above Links, with a primary Check for Updates button. Settings
search points to the new section, and its heading is translated into all eight supported languages.

Clipboard visual previews are centered above Information, including images, SVG, web cards, color
swatches and file/media previews. File Search uses balanced vertical preview padding. Image-only
extension Detail results are centered in their viewport, while text keeps its document alignment.

The pronunciation card uses two rows separated by a divider. Sounds like stays on the left with both
selectors together on the right; the guide, speaker and Slow toggle occupy the second row.

Debug builds, localization synchronization and lint passed. These layout changes were not verified
with runtime or visual tests, and memory was not remeasured for this update.

## Release 0.1.8

The Changelog menu opens `mallenkb/tinycast` releases through `ReleaseFeed.repository`, the same
repository setting used by the updater. Debug compilation and lint passed; no runtime check was run.

## Memory

The local optimization work limits decoded preview sizes and cache retention, cancels obsolete file
searches, and releases Settings content and icon caches on close. Closing a window releases owned
resources; the operating system may retain freed allocations in the process footprint.

The target is a small footprint without changing the search experience. Memory depends on the data,
active screen, and operating system, so an unconditional under-100-MB claim is not made here.

## Distribution status

- Downloads, update checks and the Changelog menu use `mallenkb/tinycast` releases.
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
