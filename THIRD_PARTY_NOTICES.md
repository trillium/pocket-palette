# Third-party notices

PocketPalette's own code is MIT (see `LICENSE`).

## Bundled today
Vendored source (MIT), compiled into the app:

| Code | License | Source |
|---|---|---|
| `App/Sources/MinVersion/MinVersionPolicy.swift`, `BrokenBuildScreen.swift` | MIT, Copyright (c) 2026 Trillium Smith | parrot-kit `KitCore.MinVersionPolicy` and `ParrotKitUI.BrokenBuildScreen` (main 7675044), access made internal |

The app otherwise links only Apple system frameworks. It ships no other third-party code, model weights, or audio.

## Build and test tooling (not shipped in the app)
| Tool | License | Use |
|---|---|---|
| XcodeGen | MIT | Generates the Xcode project from `project.yml` |
| SwiftLint | MIT | `make lint` |
| ShellCheck | GPL-3.0 | `make shell`; run as a separate tool, not linked or distributed |

## Planned (not yet included)
If on-device speech recognition is added on top of `App/Sources/Audio`, these are the expected dependencies. Their notices must be added here before they ship:

| Component | License | Obligation |
|---|---|---|
| NVIDIA Parakeet TDT model weights | CC-BY-4.0 | Attribution to NVIDIA, link to the license, state changes (e.g. CoreML conversion). Weights are downloaded at runtime or bundled, never committed. |
| FluidAudio (Swift package) | Apache-2.0 | Keep its LICENSE and NOTICE; mark modified files. |
