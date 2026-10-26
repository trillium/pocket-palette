# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: docs/versioning.md.

## [Unreleased]

### Added
- Minimum-good-version check: `RootView` reads `MIN_VERSION_URL` (Info.plist `MinVersionURL`) at launch and when the app comes to the front and shows the broken-build screen on `.broken`; `.ok` and `.unknown` (unreachable file, bad status, parse error, 3 s timeout) show the normal UI. `MinVersionPolicy` and `BrokenBuildScreen` vendored from parrot-kit 7675044 (MIT). `-FMForceBroken` forces the screen; the ship gate's `scripts/smoke.sh` requires it to render. Single-host App Transport Security exception generated from `SIDE_HOST` (set in the gitignored `Config/Local.xcconfig`) (`NSExceptionAllowsInsecureHTTPLoads` only).
- Phone sessions (runbooks-84o rule 5): `scripts/phone-session.sh` / `make phone-session CMD='...'` runs a device command under `~/.fm-phone-lock`, records the installed apps, and on exit, INT, TERM or timeout reinstalls the last known good stable build if it changed, verifying with `devicectl device info apps`; an unreachable phone writes `~/.fm-phone-restore-pending` and the next session retries first. Tested with a stubbed `xcrun` (`scripts/test-phone-session.sh`, `make phone-session-test`).
- Beta flavour (runbook rule 1): `Config/Beta.xcconfig`, build configuration `Beta`, scheme "PocketPalette Beta" covering the app and its widget, bundle id `com.trillium.pocketpalette.beta` (widget `.beta.widget`), its own App Group and widget link scheme (`pocketpalette-beta`), display name "PocketPalette β", a `BETA` compile condition and a β BETA icon; the default scheme stays stable.
- `make beta` and `make stable-install` (rules 2 and 4), via `scripts/install.sh`: install with `xcrun devicectl` on `DEVICE_ID`; the stable install refuses without a `make ship-gate` pass for the clean HEAD; each install appends a line to the `LEDGER`.
- `make ship-gate` (`scripts/ship-gate.sh`, `scripts/smoke.sh`): unmerged-branch check (`make unmerged`), tip and clean tree, `make check`, then a simulator smoke run of the built app, which prints `FMSelfCheck: ok` under `-FMSelfCheck 1`.
- Tests in `make check`: `scripts/test-beta.sh`, `scripts/test-ship-gate.sh` (gate refusals, `stable-install` pass check and `beta` with `devicectl` stubbed), `scripts/test-unmerged-branches.sh`, `SelfCheckTests`.

### Changed
- The App Group and the widget link scheme now come from `APP_GROUP_ID` / `PALETTE_URL_SCHEME` in `Config/*.xcconfig` (entitlements and Info.plist) instead of being hardcoded; stable values are unchanged.

## [0.2.0] - 2026-10-20

### Added
- Initial public release of PocketPalette: voice command palette that runs commands on a Mac engine.
- Reference Mac demo engine, dependency-free (`make demo-engine`).
- Semantic versioning from git tags: `scripts/version.sh`, `scripts/release.sh`, `docs/versioning.md`; version shown in Settings > About.

### Changed
- Version and build number are stamped automatically from git; `make bump` is removed.
