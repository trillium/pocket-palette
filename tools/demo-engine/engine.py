#!/usr/bin/env python3
"""PocketPalette reference engine module (demo).

Serves the HTTP contract in docs/mac-contract.md with a small sample command
set and runs commands on macOS via osascript/open. Standard library only.

    python3 tools/demo-engine/engine.py [--host H] [--port P] [--dry-run]
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MAX_BODY = 4096
MAX_PHRASE = 200
RATE_LIMIT = 5  # requests per second to the run endpoints

# ---------------------------------------------------------------- rule syntax


def speak(rule):
    """Spoken form: first alternative of each group, optionals dropped."""
    out = rule
    while True:
        new = re.sub(r"\[[^\[\]()]*\]", "", out)
        new = re.sub(r"\(([^()|]*)(?:\|[^()]*)?\)", r"\1", new)
        if new == out:
            return " ".join(out.split())
        out = new


def has_capture(rule):
    return bool(re.search(r"[<{][a-z_]+[>}]", rule))


def _compile(rule):
    """Compile spoken-grammar notation to a regex with named captures."""
    pos = 0
    names = []

    def seq(stop):
        nonlocal pos
        parts = []
        while pos < len(rule) and rule[pos] not in stop:
            c = rule[pos]
            if c == "(":
                pos += 1
                alts = [seq("|)")]
                while rule[pos] == "|":
                    pos += 1
                    alts.append(seq("|)"))
                pos += 1
                parts.append("(?:" + "|".join(alts) + ")")
            elif c == "[":
                pos += 1
                inner = seq("]")
                pos += 1
                parts.append("(?:" + inner + ")?")
            elif c in "<{":
                end = rule.index(">" if c == "<" else "}", pos)
                name = rule[pos + 1:end]
                pos = end + 1
                names.append(name)
                if name == "number":
                    parts.append(r"(?P<number>\d{1,3})")
                elif c == "<":
                    parts.append(r"(?P<%s>.+?)" % name)
                else:
                    parts.append(r"(?P<%s>[\w .+-]+?)" % name)
            elif c == " ":
                pos += 1
                parts.append(r"\s+")
            else:
                pos += 1
                parts.append(re.escape(c))
        return "".join(parts)

    return re.compile("^" + seq("") + "$", re.I)


# ------------------------------------------------------------------ commands
# kind: "action" runs something, "text" types a snippet.
# run: ("open", app) | ("osa", script) | ("type", text) | ("open-capture",)
#      | ("type-capture",) | ("volume-capture",)

SNIPPET_SIGNOFF = "Best regards,\nPocketPalette Demo"


def _cmd(rule, run, kind="action", scope="global", apps=(), tags=()):
    return {"rule": rule, "run": run, "kind": kind, "scope": scope,
            "apps": list(apps), "tags": list(tags)}


COMMANDS = [
    _cmd("open (finder|files)", ("open", "Finder")),
    _cmd("open safari", ("open", "Safari")),
    _cmd("open terminal", ("open", "Terminal")),
    _cmd("open notes", ("open", "Notes")),
    _cmd("open calendar", ("open", "Calendar")),
    _cmd("open music", ("open", "Music")),
    _cmd("open system settings", ("open", "System Settings")),
    _cmd("open <app>", ("open-capture",)),
    _cmd("volume up", ("osa", "set volume output volume ((output volume of (get volume settings)) + 10)")),
    _cmd("volume down", ("osa", "set volume output volume ((output volume of (get volume settings)) - 10)")),
    _cmd("volume mute", ("osa", "set volume output muted true")),
    _cmd("volume unmute", ("osa", "set volume output muted false")),
    _cmd("volume set <number>", ("volume-capture",)),
    _cmd("window minimize", ("osa", 'tell application "System Events" to keystroke "m" using command down')),
    _cmd("window close", ("osa", 'tell application "System Events" to keystroke "w" using command down')),
    _cmd("window fullscreen", ("osa", 'tell application "System Events" to keystroke "f" using {control down, command down}')),
    _cmd("(next|switch) app", ("osa", 'tell application "System Events" to keystroke tab using command down')),
    _cmd("hide app", ("osa", 'tell application "System Events" to keystroke "h" using command down')),
    _cmd("show desktop", ("osa", 'tell application "System Events" to key code 103')),
    _cmd("take screenshot", ("osa", 'tell application "System Events" to keystroke "3" using {shift down, command down}')),
    _cmd("lock screen", ("osa", 'tell application "System Events" to keystroke "q" using {control down, command down}')),
    _cmd("snippet email signoff", ("type", SNIPPET_SIGNOFF), kind="text"),
    _cmd("snippet meeting link", ("type", "https://meet.example.com/demo"), kind="text"),
    _cmd("snippet thanks", ("type", "Thanks, I will take a look and get back to you."), kind="text"),
    _cmd("snippet on my way", ("type", "On my way, back in a few minutes."), kind="text"),
    _cmd("type <text>", ("type-capture",), kind="text"),
    _cmd("new tab", ("osa", 'tell application "System Events" to keystroke "t" using command down'),
         scope="app", apps=["Safari"]),
    _cmd("reload page", ("osa", 'tell application "System Events" to keystroke "r" using command down'),
         scope="app", apps=["Safari"]),
    _cmd("new note", ("osa", 'tell application "System Events" to keystroke "n" using command down'),
         scope="app", apps=["Notes"]),
    _cmd("go back", ("osa", 'tell application "System Events" to keystroke "[" using command down'),
         scope="tag", tags=["browser"]),
]

for _i, _c in enumerate(COMMANDS):
    _c["id"] = "demo-%02d" % (_i + 1)
    _c["lineno"] = _i + 1
    _c["regex"] = _compile(_c["rule"])
    _c["captures"] = has_capture(_c["rule"])

BROWSERS = {"Safari", "Google Chrome", "Firefox", "Arc"}


def _applescript_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", '" & return & "') + '"'


class RunError(Exception):
    def __init__(self, status, code, **extra):
        super().__init__(code)
        self.status, self.code, self.extra = status, code, extra


# -------------------------------------------------------------------- engine


class Engine:
    def __init__(self, name="demo-engine", dry_run=False, runner=None, frontmost=None):
        self.name = name
        self.dry_run = dry_run
        self.runner = runner or self._run_subprocess
        self.frontmost = frontmost or self._frontmost
        self.rev = 1
        self.rate_lock = threading.Lock()
        self.recent = []

    # --- macOS bridge
    @staticmethod
    def _run_subprocess(argv):
        try:
            subprocess.run(argv, check=True, timeout=10, capture_output=True)
        except subprocess.TimeoutExpired:
            raise RunError(504, "execute_timeout")
        except (subprocess.CalledProcessError, FileNotFoundError):
            raise RunError(500, "execute_failed")

    def _frontmost(self):
        if self.dry_run or sys.platform != "darwin":
            return "Finder"
        try:
            out = subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to name of first process whose frontmost is true'],
                capture_output=True, text=True, timeout=3)
            return out.stdout.strip() or "Finder"
        except (subprocess.SubprocessError, OSError):
            return "Finder"

    # --- context
    def tags(self, app):
        return ["browser"] if app in BROWSERS else []

    def active(self, app):
        tags = self.tags(app)
        out = []
        for c in COMMANDS:
            if c["scope"] == "app" and app not in c["apps"]:
                continue
            if c["scope"] == "tag" and not set(c["tags"]) & set(tags):
                continue
            out.append(c)
        return out

    @staticmethod
    def commands_rev(cmds):
        return hashlib.sha1("|".join(c["id"] for c in cmds).encode()).hexdigest()[:12]

    def state(self):
        app = self.frontmost()
        return {
            "host": self.name, "ts": time.time(), "rev": int(time.time() * 1000),
            "app": {"name": app, "bundle": ""},
            "window": {"title": "", "filename": "", "file_ext": ""},
            "modes": ["command"], "tags": self.tags(app), "language": "en",
            "commands_rev": self.commands_rev(self.active(app)),
        }

    def commands(self):
        cmds = self.active(self.frontmost())
        return self.commands_rev(cmds), {
            "commands_rev": self.commands_rev(cmds), "count": len(cmds),
            "commands": [{
                "id": c["id"], "rule": c["rule"], "kind": c["kind"],
                "slots": re.findall(r"[<{]([a-z_]+)[>}]", c["rule"]),
                "context": c["scope"], "lineno": c["lineno"], "shadowed": False,
                "scope": c["scope"], "apps": c["apps"], "tags": c["tags"],
            } for c in cmds]}

    # --- running
    def check_rate(self):
        now = time.monotonic()
        with self.rate_lock:
            self.recent = [t for t in self.recent if now - t < 1.0]
            if len(self.recent) >= RATE_LIMIT:
                raise RunError(429, "rate_limited", retry_after=1)
            self.recent.append(now)

    def match(self, phrase):
        app = self.frontmost()
        hits = [c for c in self.active(app) if c["regex"].match(phrase)]
        if not hits:
            raise RunError(422, "no_match")
        exact = [c for c in hits if not c["captures"]]
        if exact:
            hits = exact
        if len(hits) > 1:
            raise RunError(422, "not_single_command")
        return hits[0]

    def _argv(self, cmd, phrase):
        run = cmd["run"]
        m = cmd["regex"].match(phrase)
        if run[0] == "open":
            return ["open", "-a", run[1]]
        if run[0] == "osa":
            return ["osascript", "-e", run[1]]
        if run[0] == "open-capture":
            app = m.group("app").strip()
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 .+_-]{0,49}", app):
                raise RunError(422, "no_match")
            return ["open", "-a", app]
        if run[0] == "volume-capture":
            n = min(int(m.group("number")), 100)
            return ["osascript", "-e", "set volume output volume %d" % n]
        text = run[1] if run[0] == "type" else m.group("text")
        return ["osascript", "-e",
                'tell application "System Events" to keystroke ' + _applescript_str(text)]

    def run(self, phrase, cmd_id=None, dry_run=False, force=False):
        if not isinstance(phrase, str) or not phrase.strip() or len(phrase) > MAX_PHRASE \
                or not phrase.isprintable():
            raise RunError(422, "no_match")
        phrase = " ".join(phrase.split())
        if cmd_id is not None and not any(c["id"] == cmd_id for c in COMMANDS):
            raise RunError(404, "unknown_command")
        cmd = self.match(phrase)
        if cmd_id is not None and cmd["id"] != cmd_id and not force:
            raise RunError(409, "rule_mismatch", would_run={"rule": cmd["rule"]})
        argv = self._argv(cmd, phrase)
        entry = {"rule": cmd["rule"], "path": "demo-engine"}
        if not (dry_run or self.dry_run):
            self.runner(argv)
        return cmd, entry, argv


# ---------------------------------------------------------------------- HTTP


def make_handler(engine):
    class Handler(BaseHTTPRequestHandler):
        server_version = "PocketPaletteDemoEngine/1"

        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        def _send(self, status, body=None, headers=None):
            raw = b"" if body is None else json.dumps(body).encode()
            self.send_response(status)
            if body is not None:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if status != 304:
                self.wfile.write(raw)

        def _error(self, e):
            body = {"ok": False, "error": e.code}
            headers = {}
            if "retry_after" in e.extra:
                headers["Retry-After"] = str(e.extra["retry_after"])
            if "would_run" in e.extra:
                body["would_run"] = e.extra["would_run"]
            self._send(e.status, body, headers)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/state":
                return self._send(200, engine.state())
            if url.path == "/commands":
                rev, body = engine.commands()
                etag = '"%s"' % rev
                want = parse_qs(url.query).get("rev", [None])[0]
                inm = (self.headers.get("If-None-Match") or "").strip()
                if want == rev or inm == etag:
                    return self._send(304, None, {"ETag": etag})
                return self._send(200, body, {"ETag": etag})
            self._send(404, {"ok": False, "error": "not_found"})

        def do_POST(self):
            url = urlparse(self.path)
            if url.path not in ("/execute", "/inject"):
                return self._send(404, {"ok": False, "error": "not_found"})
            try:
                self._post(url)
            except RunError as e:
                self._error(e)

        def _post(self, url):
            length = self.headers.get("Content-Length")
            if length is None or not length.isdigit():
                raise RunError(411, "length_required")
            if int(length) > MAX_BODY:
                raise RunError(413, "body_too_large")
            engine.check_rate()
            try:
                data = json.loads(self.rfile.read(int(length)) or b"{}")
                if not isinstance(data, dict):
                    raise ValueError
            except ValueError:
                raise RunError(400, "bad_request")
            q = parse_qs(url.query)
            dry = q.get("dry_run", ["0"])[0] == "1"
            force = q.get("force", ["0"])[0] == "1"
            phrase = data.get("phrase")
            if url.path == "/execute":
                cmd, entry, _ = engine.run(phrase, data.get("id"), dry, force)
                return self._send(200, {"ok": True, "matched_rule": cmd["rule"],
                                        "path": entry["path"]})
            cmd, entry, _ = engine.run(phrase, None, dry, force)
            if dry:
                return self._send(200, {"ok": True, "dry_run": True, "phrase": phrase,
                                        "would_run": [entry]})
            self._send(200, {"ok": True, "phrase": phrase, "ran": [entry]})

    return Handler


def serve(engine, host, port):
    return ThreadingHTTPServer((host, port), make_handler(engine))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--host", default="127.0.0.1",
                   help="bind address (default loopback; use your tailnet IP to reach it from the phone)")
    p.add_argument("--port", type=int, default=7777)
    p.add_argument("--name", default="demo-engine", help="host name reported by /state")
    p.add_argument("--dry-run", action="store_true", help="match commands but never run anything")
    a = p.parse_args(argv)
    srv = serve(Engine(a.name, a.dry_run), a.host, a.port)
    print("demo engine on http://%s:%d%s" % (a.host, srv.server_address[1],
                                            " (dry run)" if a.dry_run else ""), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
