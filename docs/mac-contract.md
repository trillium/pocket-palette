# Mac engine module: the HTTP contract the app relies on

The app talks to one HTTP service on the Mac. Whatever engine runs commands there (a voice-control system, a hotkey daemon, a script runner) is wrapped by an **engine module** that serves these calls. `App/Tests/PaletteAPITests.swift` pins the client side of this contract.

| Call | Notes |
|---|---|
| `GET /state` | `{host, ts, rev, app{name,bundle}, window{title,filename,file_ext}, modes[], tags[], language, commands_rev}`. No ETag. Polled every 1.5 s while foregrounded, doubling to 20 s on failure. |
| `GET /commands[?rev=R]` | `{commands_rev, count, commands[{id, rule, kind, slots[], context, lineno, shadowed, scope, apps[], tags[]}]}` with `ETag: "<rev>"`. `?rev=R` or `If-None-Match: "R"` equal to the current rev gives 304 with no body. |
| `POST /execute[?dry_run=1][&force=1]` | Body `{"phrase": "...", "id": "..."}` (id optional), `Content-Length` required, 4096 B cap (413), phrase <= 200 printable chars. 200 `{ok, matched_rule, path}`. Used by the Siri/Shortcuts intents. |
| `POST /inject[?dry_run=1][&force=1]` | What the app sends for a row tap and the Run field. Body `{"phrase": "..."}`, same limits as `/execute`. The engine runs the phrase as if it had been spoken. 200 `{ok, phrase, ran[{rule,path}]}`; with `dry_run=1` 200 `{ok, dry_run:true, phrase, would_run[{rule,path}]}` and nothing runs. |

## Context and per-command scope
`/state` is the current context: frontmost `app`, active `modes[]` and `tags[]`, `window`, `language`. `/commands` serves only the commands active in that context; `commands_rev` changes whenever that set changes.

| Field | Meaning |
|---|---|
| `scope` | `app`: the command needs a specific frontmost app. `tag`: no app requirement, but it needs an active tag (e.g. `browser`). `global`: anything else. Missing or unknown values decode as `global`. |
| `apps[]` | App names the command requires; any one satisfies it (empty unless `scope` is `app`). |
| `tags[]` | Tags the command requires. |

## Rule syntax
`rule` uses a small spoken-grammar notation: `(a|b)` alternatives, `[x]` optional words, `<name>` a capture (`<text>`, `<prose>`, `<app>`, `<number>`, ...), `{name}` a list. Rules with a capture or list cannot be sent as-is: the app opens a sheet prefilled with the rule so the user types the concrete phrase. Other rules are sent as their spoken form (`RuleSpeller`: first alternative of each group, optionals dropped).

## Errors
Errors are `{"ok":false,"error":"<code>"}`:

| Status | Code | App message |
|---|---|---|
| 401 | `unauthorized` | Unauthorized |
| 403 | `denied` | Blocked: the phone may not run this command |
| 403 | `tailnet_identity_required` | Refused: use the feed's tailscale serve address |
| 403 | `inject_needs_loopback_bind` | Refused: the feed must bind loopback behind tailscale serve |
| 404 | `unknown_command` | Command list is out of date (list refreshes) |
| 409 | `rule_mismatch` + `would_run.rule` | The Mac would run "X" instead |
| 413 | `body_too_large` | Request too large; the client also refuses before sending |
| 422 | `no_match`, `not_single_command` | No matching command / Phrase matches more than one command |
| 423 | `not_in_command_mode` | The engine is not in command mode |
| 429 | `rate_limited` + `Retry-After` | Rate limited (5/s): retry in Ns |
| 504 | `execute_timeout` | The Mac did not run it in time |
| connection refused / timeout / 502 / 503 / bare 504 | n/a | **Mac offline** (last cached list stays, greyed out) |
