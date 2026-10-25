SHELL := /bin/bash
# One line per beta / stable-install, tab-separated: time, device, bundle id, commit, build, gate pass (yes|no).
LEDGER ?= $(HOME)/.ios-install-ledger.tsv
SCRIPT_FILES := $(wildcard scripts/*.sh) $(wildcard .githooks/*)

.PHONY: help doctor generate build device-compile test beta-test ship-gate-test unmerged-test unmerged ship-gate phone-session-test phone-session beta stable-install archive archive-unsigned upload version release test-version check lint shell secrets hooks clean
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

doctor: ## check Xcode, tools, identity, signing prerequisites (SIGNING=1 makes signing items fatal)
	scripts/doctor.sh $(if $(SIGNING),--signing)
generate: ## generate the .xcodeproj from project.yml
	scripts/version.sh --write
	xcodegen generate
build: ## simulator build, no signing
	scripts/build.sh
device-compile: ## iphoneos-SDK compile check, signing disabled
	scripts/build.sh --device
test: ## unit tests on an iOS simulator
	scripts/test.sh
version: ## print the version derived from git tags
	@scripts/version.sh --full; scripts/version.sh
release: ## cut a release: make release LEVEL=major|minor|patch (see docs/versioning.md)
	scripts/release.sh $(LEVEL)
test-version: ## unit tests for scripts/version.sh
	scripts/test-version.sh
beta-test: ## the beta configuration resolves to the .beta id (app and widget), name, icon, App Group and BETA condition
	scripts/test-beta.sh
ship-gate-test: ## ship gate refusals and stable-install/beta with stubbed xcodebuild and devicectl
	scripts/test-ship-gate.sh
unmerged-test: ## unit tests for scripts/unmerged-branches.sh
	scripts/test-unmerged-branches.sh
phone-session-test: ## the phone-session wrapper: lock, restore check, unreachable marker, timeout (xcrun stubbed, temp HOME)
	scripts/test-phone-session.sh
unmerged: ## list fm/*, macbook/*, macbook-wip/* branches with commits not on main (UNMERGED_ARGS=--all scans every app repo); exit 1 if any
	scripts/unmerged-branches.sh $(UNMERGED_ARGS)
ship-gate: ## prove an integrated head: unmerged-free, HEAD = main tip, clean tree, make check, built-app smoke; writes build/ship-pass/<sha>.json
	scripts/ship-gate.sh
beta: ## build the "PocketPalette Beta" scheme (app + widget) and install it on DEVICE_ID with devicectl; no gate; appends to LEDGER
	INSTALL_LEDGER=$(LEDGER) scripts/install.sh beta
stable-install: ## install the stable app on DEVICE_ID; REFUSES without a ship-gate pass for HEAD; appends to LEDGER
	INSTALL_LEDGER=$(LEDGER) scripts/install.sh stable
phone-session: ## run CMD under the phone lock; afterwards restore the stable app if it changed (README: Phone sessions)
	@test -n "$$CMD" || { echo "usage: make phone-session CMD='...'" >&2; exit 2; }
	INSTALL_LEDGER=$(LEDGER) scripts/phone-session.sh bash -c "$$CMD"
archive: ## signed release archive (needs Apple signing; see docs/signing.md)
	scripts/archive.sh
archive-unsigned: ## unsigned archive: proves it compiles, cannot be uploaded
	SIGNING=none scripts/archive.sh
upload: ## TestFlight upload; DRY RUN unless CONFIRM=1
	CONFIRM_UPLOAD=$(if $(CONFIRM),1,0) scripts/upload.sh

check: shell lint secrets test-version beta-test ship-gate-test unmerged-test phone-session-test demo-engine-test test ## the single green gate; must pass at every commit
shell: ## syntax + shellcheck
	@for f in $(SCRIPT_FILES); do bash -n "$$f" || exit 1; done
	shellcheck -x $(SCRIPT_FILES)
lint: ## swiftlint, warnings are errors
	swiftlint lint --strict --quiet
secrets: ## block signing material and credentials in tracked files
	scripts/check-secrets.sh --tracked
demo-engine: ## run the reference Mac engine (HOST=<tailnet ip> PORT=7777 DRY_RUN=1); see tools/demo-engine/README.md
	python3 tools/demo-engine/engine.py --host $(or $(HOST),127.0.0.1) --port $(or $(PORT),7777) $(if $(DRY_RUN),--dry-run)
demo-engine-test: ## unit tests for the reference engine
	python3 -m unittest discover -s tools/demo-engine -q
hooks: ## enable .githooks for this clone
	git config core.hooksPath .githooks
clean:
	rm -rf build *.xcodeproj
