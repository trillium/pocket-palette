# PocketPalette

An iPhone command palette for a Mac: fuzzy-search every voice or keyboard command the Mac currently has active, and tap one to run it. SwiftUI, iOS 17+, MIT.

The phone does not know which automation engine runs on the Mac. It talks to a small HTTP service, the **engine module**, that exposes the engine's active commands and runs them. Any engine can sit behind that seam, as long as it serves the contract in [`docs/mac-contract.md`](docs/mac-contract.md).

## What is in here
- **Palette** (`App/Sources/Core`, `Model`, `Views`): fuzzy matcher with filler/plural/synonym handling, open slots (`<text>`, `<app>`), a gated semantic fallback, concept links, context and run-history ranking, a dry-run confirm step, and Siri/Shortcuts intents.
- **Widget** (`Widget/`): home-screen widget of recent commands.
- **Audio building blocks** (`App/Sources/Audio`): energy endpointer, microphone capture, listen state machine, background grace period and capture heartbeat. They are tested and ready for an on-device speech front end; the palette UI does not use them yet.

## Build
1. `brew install xcodegen swiftlint shellcheck`
2. `make generate` builds the `.xcodeproj` from `project.yml` (never commit it).
3. `make test` runs the unit tests on a simulator. No Apple account needed.
4. `make check` is the full gate: shell, lint, secrets, tests.

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`. Set `PALETTE_SERVER_HOST` there to prefill the Mac address, or enter it in Settings. TestFlight steps: `docs/day-one-checklist.md`; credentials: `docs/signing.md`.

## Install on the iPhone (automatic, over Tailscale)
`make ship-gate`, then `make stable-install`. That is the whole install: it runs under `scripts/phone-session.sh`, which takes the phone lock and calls `phone-reach`; `phone-reach` brings up the tailnet CoreDevice bridge (LAN is only an automatic fallback), then the gated stable app is built, signed and installed with `devicectl`. There is no link to open and nothing to tap on the phone. `make stable-install` refuses unless `make ship-gate` left a pass for exactly this clean HEAD. The OTA pages (`make ota`, `make ota-serve`, [`docs/ota.md`](docs/ota.md)) are a non-captain fallback, never this install path.

## Beta and stable on one phone
Two apps (runbook rules 1, 2, 4): stable `com.trillium.pocketpalette` and beta `com.trillium.pocketpalette.beta` ("PocketPalette β", orange β BETA icon, `#if BETA`), each with its own widget (`.widget` / `.beta.widget`), App Group and widget link scheme (`pocketpalette` / `pocketpalette-beta`), so both live side by side and the beta widget talks to the beta app. Both targets reach the phone the same way (phone lock, then `DEVICE_ID="$(phone-reach --wait 120)"`); there is no device id to configure:
- `make beta` builds the "PocketPalette Beta" scheme (app and widget) and installs it, no gate.
- `make ship-gate` then `make stable-install` installs the stable app, and refuses unless `build/ship-pass/<HEAD sha>.json` exists for exactly this clean commit on `main`. The gate checks no unmerged `fm/*` branch exists, the tree is clean, `make check` passes, and the built app launched in the simulator prints `FMSelfCheck: ok` (`scripts/smoke.sh`).

Both installs append a line to `~/.ios-install-ledger.tsv` (`LEDGER=` overrides): time, device, bundle id, commit, build, gate pass. Both need signing, and the `.beta` ids (app, widget and App Group) registered by hand (`docs/day-one-checklist.md`).

## Phone sessions
Every device session goes through one wrapper (runbooks-84o rule 5): `make phone-session CMD='make beta'`, or `scripts/phone-session.sh <command...>`; `make beta` and `make stable-install` already run inside it. It guarantees the stable app is not left changed:
- It takes the lock `~/.fm-phone-lock` (a directory holding `pid`, `started`, `command`; one phone, one lock across all apps). A live holder makes it refuse and say who holds it; a dead holder, or one older than `PHONE_SESSION_TIMEOUT` (default `30m`; seconds or `Ns`/`Nm`/`Nh`), is reported and reclaimed.
- With the lock held it runs `DEVICE_ID="$(phone-reach --wait 120)"` (from the dotfiles `phone-reach` module: tailnet by default, LAN only as an automatic fallback) and exports `DEVICE_ID` to the command. If the phone cannot be reached it releases the lock, runs nothing and exits 1.
- It records the installed apps (`xcrun devicectl device info apps`), runs the command under a watchdog (killed at the timeout, status 124), and on exit, INT, TERM or timeout runs the restore check and releases the lock. The exit status is the command's.
- Restore check: the last known good stable build is the newest `~/.ios-install-ledger.tsv` line for the stable bundle id (never `.beta`) with gate pass yes. If the installed stable build differs, the kept ship-gated artifact (`OTA_DIR/builds/<id>/PocketPalette.ipa` with `meta.json` `pass: true`; `OTA_DIR` defaults to `~/ota/pocketpalette`) is reinstalled with `devicectl`, verified with a second apps listing, and a ledger line with note `restore` is appended. With no kept artifact for that commit it says so and installs nothing. Beta is never touched.
- Phone locked or offline: it prints "phone is locked or offline; stable app could not be verified or restored, will retry", writes `~/.fm-phone-restore-pending` (bundle id, known-good commit and build, device, time) and exits non-zero. The next run with the marker present (or after reclaiming a stale lock) retries the restore before running anything, and refuses to run the command while the stable app is unverified.
- Env: `PHONE_SESSION_TIMEOUT`, `PHONE_LOCK`, `PHONE_RESTORE_MARKER`, `OTA_DIR`, `INSTALL_LEDGER` (`LEDGER=` on make). Test: `make phone-session-test` (in `make check`).

## Minimum-good-version check
At launch and each time it comes to the front the app reads a small JSON file (`MIN_VERSION_URL` in `Config/Base.xcconfig`, built from `SIDE_HOST`, which you set in the gitignored `Config/Local.xcconfig`; Info.plist key `MinVersionURL`). If its own build is below `min_build` or listed in `broken_builds`, it shows "This build is broken. Install the stable app." instead of the normal UI. The check fails open: an unreachable file, a bad status, a parse error, a 3 s timeout or no network all mean "no restriction". The beta id `<id>.beta` looks up the stable id's entry. Set `MIN_VERSION_URL` empty (for example in `Config/Local.xcconfig`) to switch the check off.
- `-FMForceBroken` (launch argument) forces the broken screen; `scripts/smoke.sh` (the ship gate) relaunches with it and requires the `FMBrokenScreen: shown` line.
- `App/Sources/MinVersion/` is vendored from parrot-kit `MinVersionPolicy` and `BrokenBuildScreen` (main 7675044, MIT, access made internal); see `THIRD_PARTY_NOTICES.md`.

## Network trust
There is no token. The app expects to reach the Mac over a private network (for example a Tailscale tailnet), and App Transport Security permits plain http only to `*.ts.net` hosts (plus a single-host entry for `SIDE_HOST`, the min-version file's host); there is no blanket `NSAllowsArbitraryLoads`. Do not expose the engine module to the public internet.

## License
MIT, see `LICENSE`. Third-party notices: `THIRD_PARTY_NOTICES.md`.
