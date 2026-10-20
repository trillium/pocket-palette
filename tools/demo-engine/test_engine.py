import http.client
import json
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import engine  # noqa: E402


class Base(unittest.TestCase):
    app = "Finder"

    @classmethod
    def setUpClass(cls):
        cls.ran = []
        cls.eng = engine.Engine("test-host", runner=cls.ran.append,
                                frontmost=lambda: cls.app)
        cls.srv = engine.serve(cls.eng, "127.0.0.1", 0)
        cls.port = cls.srv.server_address[1]
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        type(self).app = "Finder"
        self.ran.clear()
        self.eng.recent.clear()

    def call(self, method, path, body=None, headers=None, raw=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = dict(headers or {})
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        text = r.read()
        c.close()
        return r.status, r, (json.loads(text) if text else None)


class TestState(Base):
    def test_state_shape(self):
        s, _, b = self.call("GET", "/state")
        self.assertEqual(s, 200)
        for k in ("host", "ts", "rev", "app", "window", "modes", "tags", "language", "commands_rev"):
            self.assertIn(k, b)
        self.assertEqual(b["host"], "test-host")
        self.assertEqual(b["app"]["name"], "Finder")
        self.assertEqual(b["commands_rev"], self.call("GET", "/commands")[2]["commands_rev"])


class TestCommands(Base):
    def test_list_and_etag(self):
        s, r, b = self.call("GET", "/commands")
        self.assertEqual(s, 200)
        self.assertEqual(r.getheader("ETag"), '"%s"' % b["commands_rev"])
        self.assertEqual(b["count"], len(b["commands"]))
        self.assertGreaterEqual(b["count"], 25)
        c = b["commands"][0]
        for k in ("id", "rule", "kind", "slots", "context", "lineno", "shadowed", "scope", "apps", "tags"):
            self.assertIn(k, c)

    def test_304_by_query_and_header(self):
        _, r, b = self.call("GET", "/commands")
        s, _, body = self.call("GET", "/commands?rev=" + b["commands_rev"])
        self.assertEqual((s, body), (304, None))
        s, _, body = self.call("GET", "/commands", headers={"If-None-Match": r.getheader("ETag")})
        self.assertEqual((s, body), (304, None))
        self.assertEqual(self.call("GET", "/commands?rev=stale")[0], 200)

    def test_scope_follows_context(self):
        rules = lambda: {c["rule"]: c for c in self.call("GET", "/commands")[2]["commands"]}
        base = self.call("GET", "/commands")[2]["commands_rev"]
        self.assertNotIn("new tab", rules())
        type(self).app = "Safari"
        r = rules()
        self.assertEqual(r["new tab"]["scope"], "app")
        self.assertEqual(r["new tab"]["apps"], ["Safari"])
        self.assertEqual(r["go back"]["scope"], "tag")
        self.assertEqual(r["go back"]["tags"], ["browser"])
        self.assertNotEqual(self.call("GET", "/commands")[2]["commands_rev"], base)
        self.assertEqual(self.call("GET", "/state")[2]["tags"], ["browser"])


class TestExecute(Base):
    def test_execute_runs(self):
        s, _, b = self.call("POST", "/execute", {"phrase": "open safari"})
        self.assertEqual(s, 200)
        self.assertTrue(b["ok"])
        self.assertEqual(b["matched_rule"], "open safari")
        self.assertEqual(self.ran, [["open", "-a", "Safari"]])

    def test_execute_dry_run(self):
        s, _, b = self.call("POST", "/execute?dry_run=1", {"phrase": "volume up"})
        self.assertEqual(s, 200)
        self.assertEqual(self.ran, [])

    def test_execute_with_id_and_mismatch(self):
        cmds = {c["rule"]: c["id"] for c in self.call("GET", "/commands")[2]["commands"]}
        self.assertEqual(self.call("POST", "/execute", {"phrase": "volume up", "id": cmds["volume up"]})[0], 200)
        s, _, b = self.call("POST", "/execute", {"phrase": "volume up", "id": cmds["volume down"]})
        self.assertEqual(s, 409)
        self.assertEqual(b["error"], "rule_mismatch")
        self.assertEqual(b["would_run"]["rule"], "volume up")
        s, _, _ = self.call("POST", "/execute?force=1", {"phrase": "volume up", "id": cmds["volume down"]})
        self.assertEqual(s, 200)

    def test_unknown_id(self):
        s, _, b = self.call("POST", "/execute", {"phrase": "volume up", "id": "nope"})
        self.assertEqual((s, b["error"]), (404, "unknown_command"))

    def test_no_match(self):
        s, _, b = self.call("POST", "/execute", {"phrase": "make me a sandwich"})
        self.assertEqual((s, b["error"]), (422, "no_match"))

    def test_out_of_context_is_no_match(self):
        s, _, b = self.call("POST", "/execute", {"phrase": "new tab"})
        self.assertEqual((s, b["error"]), (422, "no_match"))
        type(self).app = "Safari"
        self.assertEqual(self.call("POST", "/execute", {"phrase": "new tab"})[0], 200)


class TestInject(Base):
    def test_inject_runs(self):
        s, _, b = self.call("POST", "/inject", {"phrase": "volume mute"})
        self.assertEqual(s, 200)
        self.assertEqual(b["phrase"], "volume mute")
        self.assertEqual(b["ran"][0]["rule"], "volume mute")
        self.assertEqual(len(self.ran), 1)

    def test_inject_dry_run(self):
        s, _, b = self.call("POST", "/inject?dry_run=1", {"phrase": "open notes"})
        self.assertEqual(s, 200)
        self.assertTrue(b["dry_run"])
        self.assertEqual(b["would_run"][0]["rule"], "open notes")
        self.assertEqual(self.ran, [])

    def test_captures(self):
        self.assertEqual(self.call("POST", "/inject", {"phrase": "open Preview"})[0], 200)
        self.assertEqual(self.ran[-1], ["open", "-a", "Preview"])
        self.assertEqual(self.call("POST", "/inject", {"phrase": "volume set 30"})[0], 200)
        self.assertEqual(self.ran[-1][-1], "set volume output volume 30")
        self.assertEqual(self.call("POST", "/inject", {"phrase": 'type say "hi"'})[0], 200)
        self.assertIn('say \\"hi\\"', self.ran[-1][-1])

    def test_capture_rejects_injection(self):
        s, _, b = self.call("POST", "/inject", {"phrase": "open x; rm -rf ~"})
        self.assertEqual((s, b["error"]), (422, "no_match"))
        self.assertEqual(self.ran, [])

    def test_exact_rule_beats_capture(self):
        self.call("POST", "/inject", {"phrase": "open safari"})
        self.assertEqual(self.ran, [["open", "-a", "Safari"]])

    def test_snippet_types_text(self):
        self.call("POST", "/inject", {"phrase": "snippet meeting link"})
        self.assertIn("https://meet.example.com/demo", self.ran[0][-1])


class TestLimitsAndErrors(Base):
    def test_phrase_too_long(self):
        s, _, b = self.call("POST", "/inject", {"phrase": "a" * 201})
        self.assertEqual((s, b["error"]), (422, "no_match"))

    def test_body_too_large(self):
        s, _, b = self.call("POST", "/execute", raw=b'{"phrase":"' + b"a" * 5000 + b'"}')
        self.assertEqual((s, b["error"]), (413, "body_too_large"))

    def test_content_length_required(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.putrequest("POST", "/execute")
        c.endheaders()
        r = c.getresponse()
        self.assertEqual(r.status, 411)
        c.close()

    def test_bad_json(self):
        s, _, b = self.call("POST", "/execute", raw=b"not json")
        self.assertEqual((s, b["error"]), (400, "bad_request"))

    def test_rate_limit(self):
        codes = [self.call("POST", "/inject?dry_run=1", {"phrase": "volume up"})[0] for _ in range(7)]
        self.assertEqual(codes[:5], [200] * 5)
        s, r, b = self.call("POST", "/inject?dry_run=1", {"phrase": "volume up"})
        self.assertEqual((s, b["error"]), (429, "rate_limited"))
        self.assertEqual(r.getheader("Retry-After"), "1")

    def test_not_found(self):
        self.assertEqual(self.call("GET", "/nope")[0], 404)
        self.assertEqual(self.call("POST", "/nope", {})[0], 404)


class TestRules(unittest.TestCase):
    def test_speak(self):
        self.assertEqual(engine.speak("open (finder|files)"), "open finder")
        self.assertEqual(engine.speak("(next|switch) app [please]"), "next app")

    def test_every_plain_rule_matches_its_spoken_form(self):
        for c in engine.COMMANDS:
            if not c["captures"]:
                self.assertTrue(c["regex"].match(engine.speak(c["rule"])), c["rule"])

    def test_dry_run_engine_never_runs(self):
        calls = []
        e = engine.Engine(dry_run=True, runner=calls.append, frontmost=lambda: "Finder")
        e.run("open safari")
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
