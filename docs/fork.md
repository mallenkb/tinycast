# Fork status

This repository is [mallenkb/tinycast](https://github.com/mallenkb/tinycast), an independent fork of
[abue-ammar/tinycast](https://github.com/abue-ammar/tinycast). Contact the fork maintainer at
[@mallenkb on X](https://x.com/mallenkb).

## Releases 0.1.0 and 0.1.1

Version 0.1.1 binds the update cache to this fork and rejects assets from other repositories. This
prevents a cached upstream version from appearing after switching to the fork.

The first fork release includes rich clipboard link previews with Open Graph images, rendered SVG
previews and type labels, live launcher file results, system or Inter Variable typography, and palette
and caret refinements. It also includes redesigned feature icons, grouped Settings navigation, and
memory improvements.

The universal DMG and updater ZIP support Apple silicon and Intel on macOS 26 or later. The source
for the packaged build is available at each release tag. Build and signature validation do not establish
that every feature has passed runtime testing.

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
- The inherited GitHub Actions workflow still references upstream services and is not used for this
  release. Local packaging does not update upstream taps, websites, or announcements.
- Original author credit and third-party notices remain in the app and repository.

## Attribution

Original author: [Abue Ammar](https://github.com/abue-ammar).
Original project: [Tinycast](https://github.com/abue-ammar/tinycast).
Fork maintainer: [mallenkb](https://github.com/mallenkb).

The original copyright notice, AGPL-3.0-or-later license, contributor history, and existing contributor
agreement are preserved. This fork’s release and support channels are separate from upstream.
