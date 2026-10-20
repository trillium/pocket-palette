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

To run on a device, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`. Set `PALETTE_SERVER_HOST` there to prefill the Mac address, or enter it in Settings. TestFlight steps: `docs/day-one-checklist.md`; credentials: `docs/signing.md`.

## Network trust
There is no token. The app expects to reach the Mac over a private network (for example a Tailscale tailnet), and App Transport Security permits plain http only to `*.ts.net` hosts. Do not expose the engine module to the public internet.

## License
MIT, see `LICENSE`. Third-party notices: `THIRD_PARTY_NOTICES.md`.
