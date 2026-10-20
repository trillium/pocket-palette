Legend: **[HAND]** only the Apple account holder can do it (no script can or should). **[SCRIPT]** one command.

### A. One-time per Apple account (skip if already done)
1. **[HAND]** Enroll in the Apple Developer Program (paid, US$99/year) at developer.apple.com/programs. A free Personal Team cannot use TestFlight.
2. **[HAND]** Accept the latest Program License Agreement and the Paid Applications agreement at developer.apple.com and appstoreconnect.apple.com. Uploads fail until they are accepted.
3. **[HAND]** In App Store Connect > Users and Access > Integrations > App Store Connect API, generate a **Team Key** with the **App Manager** role. Download the `.p8` once (Apple will not show it again). Note the **Key ID** and the **Issuer ID**.
4. **[HAND]** Store the `.p8` outside every repo (for example `~/.appstoreconnect/AuthKey_<KEYID>.p8`, `chmod 600`), and export `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` from your shell profile or secret manager. See `docs/signing.md`.
5. **[HAND]** Note your 10-character **Team ID** (developer.apple.com > Membership details).

### B. Once per new app
6. **[HAND]** Set `PRODUCT_BUNDLE_IDENTIFIER` in `Config/Base.xcconfig` to a bundle id you own, and `DEVELOPMENT_TEAM` (your Team ID) in the gitignored `Config/Local.xcconfig`.
7. **[SCRIPT]** `make generate && make doctor && make test` (simulator only, no account needed).
8. **[HAND]** Register the bundle id: developer.apple.com > Certificates, Identifiers & Profiles > Identifiers > **+** > App IDs > App. Use exactly the bundle id from `Config/Base.xcconfig`. (With the API key, `make archive` can create it automatically; registering by hand is the explicit alternative.)
9. **[HAND]** Create the app record: App Store Connect > Apps > **+** > New App. Pick the same bundle id, a unique SKU, and a name. This must exist before the first upload.
10. **[HAND]** Replace the placeholder icon `App/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` with your 1024x1024 opaque PNG (no alpha). TestFlight accepts the placeholder; the App Store does not.

### C. Every build
11. **[SCRIPT]** `make doctor SIGNING=1` must show no FAIL lines.
12. **[SCRIPT]** `make bump` (new build number), `make archive` (signed release archive).
13. **[SCRIPT]** `make upload` first: a dry run that prints exactly what would be sent. Then `make upload CONFIRM=1` to send for real.
14. **[HAND]** Wait for processing (a few minutes). In App Store Connect > your app > TestFlight, answer the compliance prompt if shown (the template already declares `ITSAppUsesNonExemptEncryption = NO`).
15. **[HAND]** First build only: add **Internal Testing** testers (people with an App Store Connect role) and install via the TestFlight app. No App Review is needed for internal testing. External testers need Beta App Review and `TESTFLIGHT_INTERNAL_ONLY=0`.

### Never
- Never commit a `.p8`, `.p12`, `.mobileprovision`, `.pem` or `.env` file (hooks block it).
- Never paste a key, issuer id or token into a chat, issue or commit message.
