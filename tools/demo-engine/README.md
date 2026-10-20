# Demo engine

A dependency-free Python 3 reference implementation of the Mac side of [`docs/mac-contract.md`](../../docs/mac-contract.md), so PocketPalette runs standalone on a Mac with no other engine. It serves about 30 generic commands (open apps, window and volume actions, text snippets) and runs them with `open` and `osascript`.

## Start it

```sh
make demo-engine DRY_RUN=1     # safe: matches commands, runs nothing
make demo-engine               # real: runs commands on this Mac
```

Defaults to `127.0.0.1:7777`. Override with `HOST=` and `PORT=`.

For real runs, grant your terminal **Accessibility** permission (System Settings > Privacy & Security) so keystroke-based commands (window actions, text snippets) work.

## Bind to the tailnet address

The phone must reach the Mac over your private network. Bind to the Mac's Tailscale IP:

```sh
make demo-engine HOST=$(tailscale ip -4 | head -1)
```

The app only allows plain http to `*.ts.net` hosts, so use the Mac's MagicDNS name in the app. There is no auth: never bind to `0.0.0.0` or expose it to the public internet.

## Point the app at it

In PocketPalette settings, set the Mac address to `http://<mac-name>.<tailnet>.ts.net:7777`. The palette should list the sample commands within a couple of seconds.

## Try it with curl

```sh
curl -s localhost:7777/state
curl -si localhost:7777/commands | head -20
curl -s -XPOST 'localhost:7777/inject?dry_run=1' -d '{"phrase":"open safari"}'
curl -s -XPOST localhost:7777/inject -d '{"phrase":"volume up"}'
```

## Behavior notes

- Commands are filtered by the frontmost app: `new tab` only appears in Safari, `go back` in browsers.
- Captures (`open <app>`, `volume set <number>`, `type <text>`) are validated before anything runs.
- `force=1` skips the `rule_mismatch` check when an `id` is given.
- Runs are rate limited to 5/s.

## Tests

`make demo-engine-test` (also part of `make check`) covers every endpoint and error path with a fake runner; nothing touches the real system.
