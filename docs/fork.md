# Fork status

This repository is [mallenkb/tinycast](https://github.com/mallenkb/tinycast), an independent fork of
[abue-ammar/tinycast](https://github.com/abue-ammar/tinycast). Contact the fork maintainer at
[@mallenkb on X](https://x.com/mallenkb).

## Published source and local work

As of 30 October 2026, the published implementation includes rich clipboard link previews, live
launcher file results, system or Inter Variable typography, and palette and caret refinements.

The latest local build also includes rendered SVG clipboard previews and SVG type labels, a redesigned
feature icon set, grouped Settings navigation, and memory improvements. Those implementation changes
are not yet committed or pushed. A source checkout of this repository does not include them yet.

A local universal Release build, version 0.1.0, was packaged successfully for Apple silicon and Intel.
Its code signature verified. No GitHub binary release has been published. Building and signature
verification do not establish that every feature has passed runtime testing.

## Memory

The local optimization work limits decoded preview sizes and cache retention, cancels obsolete file
searches, and releases Settings content and icon caches on close. Closing a window releases owned
resources; the operating system may retain freed allocations in the process footprint.

The target is a small footprint without changing the search experience. Memory depends on the data,
active screen, and operating system, so an unconditional under-100-MB claim is not made here.

## Distribution status

- The app’s update feed still points to `abue-ammar/tinycast`.
- Release builds use `com.tinycast.app`, the same identity as upstream stable. Dev builds use
  `com.tinycast.app.dev` and keep separate data.
- The inherited GitHub Actions release workflow references the original Homebrew tap, website,
  and announcement setup. It needs adaptation for this fork before use.
- Local packages are self-signed. Successful signature verification is not Apple notarization.
- Upstream Homebrew instructions and upstream releases install the original project.

Before the first fork release, publish the intended source changes, choose the version and channel,
configure the fork’s updater and release destinations, and complete release validation. Third-party
icon assets in the local design work also need their source credits and distribution terms recorded
when those assets are published.

## Attribution

Original author: [Abue Ammar](https://github.com/abue-ammar).
Original project: [Tinycast](https://github.com/abue-ammar/tinycast).
Fork maintainer: [mallenkb](https://github.com/mallenkb).

The original copyright notice, AGPL-3.0-or-later license, contributor history, and existing contributor
agreement are preserved. This fork’s release and support channels are separate from upstream.
