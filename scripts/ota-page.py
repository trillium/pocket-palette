#!/usr/bin/env python3
"""Render the OTA install page and prune old builds (scripts/ota.sh). Stdlib only; generic, copy into other apps.

OTA_DIR/builds/<id>/ holds one published build: meta.json, manifest.plist and the .ipa. Only builds that passed the
ship gate are ever published there, so every entry is a known-working build. The newest is the install target;
older ones (at most --keep) are the Rollback list. Anything older is deleted.
"""
import argparse
import html
import json
import shutil
import sys
import urllib.parse
from pathlib import Path


def load_builds(builds_dir):
    out = []
    for meta in builds_dir.glob("*/meta.json"):
        try:
            data = json.loads(meta.read_text())
        except ValueError:
            continue
        if data.get("pass") is True and (meta.parent / "manifest.plist").exists():
            out.append(data)
    return sorted(out, key=lambda m: m["id"], reverse=True)


def install_link(base, build_id):
    manifest = "%s/builds/%s/manifest.plist" % (base, build_id)
    return "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest, safe="")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--keep", type=int, default=3, help="previous builds kept for rollback")
    args = ap.parse_args()

    root = Path(args.dir)
    builds = load_builds(root / "builds")
    if not builds:
        sys.exit("ota-page: no passed build in %s/builds" % root)
    for old in builds[args.keep + 1:]:
        shutil.rmtree(root / "builds" / old["id"], ignore_errors=True)
    builds = builds[:args.keep + 1]
    current, previous = builds[0], builds[1:]

    def label(m):
        return html.escape("%s (%s) &middot; build %s &middot; %s" % (m["version"], m["short"], m["id"], m["passed_at"]))

    rows = "".join(
        '<li>%s <a class="rollback" href="%s">Rollback to this build</a></li>\n'
        % (label(m), html.escape(install_link(args.base, m["id"]), quote=True))
        for m in previous
    )
    rollback = (
        "<h2>Rollback</h2>\n<p>Previous working builds, newest first. Each passed the ship gate.</p>\n<ul>\n%s</ul>" % rows
        if previous else "<p class=\"version\">No earlier working build to roll back to yet.</p>"
    )
    page = Path(args.template).read_text()
    for key, value in {
        "__TITLE__": html.escape(args.title),
        "__VERSION_LABEL__": html.escape("%s (%s)" % (current["version"], current["short"])),
        "__BUNDLE_VERSION__": html.escape(current["id"]),
        "__PASSED_AT__": html.escape(current["passed_at"]),
        "__INSTALL_URL__": html.escape(install_link(args.base, current["id"]), quote=True),
        "__ROLLBACK__": rollback,
    }.items():
        page = page.replace(key, value)
    (root / "index.html").write_text(page)
    print("page: current %s build %s, %d rollback build(s)" % (current["version"], current["id"], len(previous)))


if __name__ == "__main__":
    main()
