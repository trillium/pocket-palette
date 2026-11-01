# OTA publishing (`make ota`): non-captain fallback

**This is not the captain's install path.** The captain never opens a link. His phone gets the app with `make ship-gate` then `make stable-install`, which reaches the phone over Tailscale (`phone-reach`, via `scripts/phone-session.sh`) with no link and no tap (README: Install on the iPhone). This page documents the OTA tooling that remains as a fallback for a tester's device, and as the store of gated `.ipa` builds that `phone-session` restores the stable app from. The scripts are the generic OTA scripts from firstmate-share (`docs/ota.md` there), which mirror `~/code/TinyKeyboard/ota-publish.sh`.

## What it does
1. `make ship-gate`, from the integrated head (`main`). `make ota` refuses without its pass file.
2. `make ota`: archives with automatic signing for team `85PWBA3B59` (`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`), exports ad-hoc (`ota/exportOptions.plist`), and publishes `PocketPalette.ipa`, `manifest.plist`, `index.html` and `builds/<build>/` into `OTA_DIR` (default `~/ota/pocketpalette`). Each run stamps a fresh UTC timestamp as the build number on the app and the widget, so iOS always reinstalls.
3. `make ota-serve`: starts a loopback static server on `127.0.0.1:8792` over `OTA_DIR`, then puts `tailscale serve --https=8782` in front of it. Idempotent. It refuses a port that another process or serve mapping already holds, and refuses a Funnel-enabled one. Run it again after the Mac reboots.
4. The page is then served at `https://<this Mac>.hippo-tilapia.ts.net:8782/` for a tester's device on the tailnet (`make ota` prints the exact address). Nobody is asked to do this for the captain's phone.

`make ota` also prints the raw link, `itms-services://?action=download-manifest&url=https%3A%2F%2F<host>%3A8782%2Fmanifest.plist`. To check from the Mac, both of these must return 200:
- `curl -sI https://<host>:8782/manifest.plist`
- `curl -sI https://<host>:8782/PocketPalette.ipa`

## Never leave a broken build on the phone
1. **Ship gate (`make ship-gate`, `scripts/ship-gate.sh`).** It refuses unless no `fm/*` branch is unmerged, HEAD is the tip of `main`, the tree is clean, `make check` passes, and the built app passes its simulator smoke test (`scripts/smoke.sh`). On success it writes `build/ship-pass/<full-sha>.json` (override: `SHIP_PASS_DIR`).
2. **`make ota` only publishes gated builds.** It refuses (and touches nothing in `OTA_DIR`) unless a pass file names exactly HEAD and the tree is still clean. It opens the exported `.ipa` and refuses unless it is `com.trillium.pocketpalette`, carries the build number it just archived, and contains the widget.
3. **Rollback.** Each publish goes to `OTA_DIR/builds/<build>/` (its own `.ipa`, `manifest.plist`, `meta.json`). The page installs the newest and lists the previous three under **Rollback**, newest first; older builds are pruned (`OTA_KEEP_PREVIOUS`, default 3). A build whose `meta.json` lacks `"pass": true` is never listed. A tester's device rolls back from the page's **Rollback** list; the captain's phone is rolled back by `phone-session`, which reinstalls the last known good stable build from these kept builds.

## Overrides and ports
- `OTA_DIR`, `OTA_HTTPS_PORT` (**8782**, PocketPalette's port on mini0), `OTA_LOCAL_PORT` (8792, the loopback server: https port + 10). `OTA_BASE_URL` must start with `https://` and match where the folder is served.
- **Never Funnel.** Never use the HTTPS root (`:443`) or `:8443` on this Mac: both are public. Only `tailscale serve --https=<port>`.
- Ports on mini0: firstmate-share 8773, SayType 8777, Parrot Arcade 8778, SayType Board 8779, Parrot Mic 8780, Talon ASR 8781, PocketPalette 8782, testflight-starter 8783.
- `OTA_EXPORT=archive make ota` skips the ad-hoc export and zips the Apple Development-signed app straight from the archive (needs only the team profiles already in Xcode's UserData; installs only on devices those profiles list). Use it when the ad-hoc export fails with `No Accounts`. The ship gate and `.ipa` checks apply the same way.
- **Signing over ssh.** `codesign` from an ssh session gets `errSecInternalComponent`. Run `make ota` inside the logged-in GUI session, for example a one-shot LaunchAgent bootstrapped into `gui/$(id -u)` with `LimitLoadToSessionType` `Aqua`.
- To stop serving: `tailscale serve --https=8782 off`, then `kill "$(cat ~/.cache/pocketpalette-ota/http.pid)"`.

## Prerequisites (account holder)
- **Signing.** Team `85PWBA3B59` in the gitignored `Config/Local.xcconfig` (`DEVELOPMENT_TEAM`), equal to `teamID` in `ota/exportOptions.plist`. Automatic signing must be able to create profiles for `com.trillium.pocketpalette` and `.widget` with the App Group `group.com.trillium.pocketpalette`. Without an Apple ID in Xcode > Settings > Accounts, `xcodebuild` stops with `No Accounts`.
- **The device registered for the team.** Ad-hoc only installs on devices that were in the profile when it was made.
- **Tailscale.** MagicDNS and HTTPS certificates are on for the tailnet.

## Tests
`make ota-test` (part of `make check`) stubs `xcodebuild` and checks the published files, the pass-file and rollback rules, the team in `ota/exportOptions.plist` (it must equal `DEVELOPMENT_TEAM`), the provisioning flags and the `.ipa` inspection. It never signs, builds or serves anything.
