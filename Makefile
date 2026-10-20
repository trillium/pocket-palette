SHELL := /bin/bash
SCRIPT_FILES := $(wildcard scripts/*.sh) $(wildcard .githooks/*)

.PHONY: help doctor generate build device-compile test archive archive-unsigned upload bump check lint shell secrets hooks clean
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

doctor: ## check Xcode, tools, identity, signing prerequisites (SIGNING=1 makes signing items fatal)
	scripts/doctor.sh $(if $(SIGNING),--signing)
generate: ## generate the .xcodeproj from project.yml
	xcodegen generate
build: ## simulator build, no signing
	scripts/build.sh
device-compile: ## iphoneos-SDK compile check, signing disabled
	scripts/build.sh --device
test: ## unit tests on an iOS simulator
	scripts/test.sh
bump: ## increment the build number (BUILD=N sets it)
	scripts/bump-build.sh $(if $(BUILD),--set $(BUILD))
archive: ## signed release archive (needs Apple signing; see docs/signing.md)
	scripts/archive.sh
archive-unsigned: ## unsigned archive: proves it compiles, cannot be uploaded
	SIGNING=none scripts/archive.sh
upload: ## TestFlight upload; DRY RUN unless CONFIRM=1
	CONFIRM_UPLOAD=$(if $(CONFIRM),1,0) scripts/upload.sh

check: shell lint secrets demo-engine-test test ## the single green gate; must pass at every commit
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
