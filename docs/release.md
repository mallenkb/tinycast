# Release

## Status of this fork

Version 0.1.0 is the first locally packaged release of `mallenkb/tinycast`. Downloads and the in-app
update feed use this fork's GitHub releases. The universal DMG and ZIP are self-signed and not
notarized. Version 0.1.1 additionally scopes cached updates and accepted asset URLs to this fork.
Version 0.1.2 adds dictionary source selection and idle memory reclamation. Version 0.1.4 integrates
upstream application fixes, deeplinks, extension authentication and AI protocol updates.
GitHub Actions now provides fork-specific build checks and a manual signed release workflow.

How a build reaches a user. The local development loop is in [development.md](development.md);
the signing identity itself is in [signing.md](signing.md).

## Packaging a DMG locally

```sh
./Scripts/build-dmg.sh            # -> build/Tinycast-Universal-<version>.dmg (version from project.yml)
./Scripts/build-dmg.sh 0.5.7      # -> build/Tinycast-Universal-0.5.7.dmg
```

It builds a universal Release `Tinycast.app` signed with `Tinycast Self-Signed` and packs it with an
`/Applications` symlink. It writes `Tinycast-Universal-<version>.dmg` and a matching updater ZIP.
`TINYCAST_ARCHS` selects architectures and `TINYCAST_SIGNING_IDENTITY` overrides the certificate.
Developer ID Application identities use a secure timestamp. Self-signed builds use no timestamp.
The inherited per-channel CI workflow is documented below for reference.

## Signing & Gatekeeper

Both local builds and CI releases sign with the same stable `Tinycast Self-Signed` identity, not an
Apple Developer ID — so macOS quarantines a directly-downloaded DMG. The Homebrew cask strips that
automatically; direct downloaders run `xattr -dr com.apple.quarantine "…/Tinycast.app"` once. Full
details in [signing.md](signing.md).

## How the in-app updater consumes a release

Every release publishes two assets from one build: `Tinycast-<version>.dmg`, which people download by
hand and which the cask installs, and `Tinycast-<version>.zip`, which the in-app updater installs. The
zip is produced with `ditto -c -k --keepParent --sequesterRsrc` — the only zip that leaves the code
signature verifiable, which matters because the updater refuses any bundle whose signature does not
prove it is ours.

A stable release publishes two more from the `universal` job, `Tinycast-Universal-<version>.dmg` and
`.zip`, built from the same commit at the same version and bundle id but with both slices. They are
uploaded *after* the thin pair, which keeps the thin zip first in the asset list so builds predating
architecture-aware selection keep choosing it.

Three things a release must keep true, or the updater skips it:

- **It carries a `.zip` asset this Mac can run.** A DMG-only release is not installable and is not
  offered, and an Intel build is offered nothing rather than a thin arm64 zip.
- **The tag parses as `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-beta.N`,** and agrees with the
  `prerelease` flag. A tag of any other shape is treated as mis-published and skipped.
- **It is not a draft.**

**Both casks declare `auto_updates true`.** That is Homebrew's flag for an app that manages its own
version, and it is what keeps `brew update && brew upgrade` from fighting an app that updated itself:
brew never reports Tinycast outdated, never re-downloads it, and never rolls a self-updated copy back.
Removing that line would reintroduce exactly those three problems. See
[features/updates.md](features/updates.md).

## GitHub Actions

`Build` runs on pushes to main, pull requests and manual dispatch. It uses GitHub's `xcode-27` hosted
runner, runs lint and focused dictionary, icon-cache, settings-file and backup harnesses, then builds
an unsigned Apple silicon Debug build. Signed releases retain universal validation. The build log is retained for seven days. It does not run the focus-taking
onboarding harness or the offscreen form-rendering checks that fail on the current SDK.

`Release` is a manual workflow for this fork on main. Update project.yml's version first, push that
commit, then choose Actions → Release → Run workflow and enter the same stable version. The job checks
that the release does not already exist, validates sources, imports the existing signing identity,
builds the universal DMG and updater ZIP, verifies all four executable architecture pairs and signatures,
and publishes both archives with SHA256SUMS.txt. Release notes include generated changes and fork
installation instructions. It does not update upstream taps or send announcements.

Configure these repository Actions secrets before running `Release`:

- `SIGNING_P12_BASE64`: the PKCS#12 certificate and private key for the existing Tinycast Self-Signed identity.
- `SIGNING_P12_PASSWORD`: that export's password.

The workflow stops before building if either secret is absent. When secrets are absent, package
locally with the existing signing identity and upload the verified assets through the GitHub CLI. Using the existing identity preserves
in-app update signature checks and permission continuity. CI builds need neither secret. The temporary
runner keychain and certificate export are removed when the release job finishes.

The fork's existing releases remain self-signed and not notarized. Local packaging remains available
through `Scripts/build-dmg.sh`.
