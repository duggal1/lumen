.PHONY: build test verify app probe hooks capture-e2e

build:
	swift build

test:
	swift test

app:
	bash Tools/make-app.sh

hooks:
	git config core.hooksPath Tools/hooks

verify: test app
	.build/Lumen.app/Contents/MacOS/Lumen --help >/dev/null 2>&1 & pid=$$!; sleep 2; kill -0 $$pid; kill $$pid
	@echo 'Build, integration tests, packaging and launch passed. Hardware capture/sync/performance checks remain separate.'

probe: build
	swift run --skip-build lumen-cli probe

capture-e2e: build
	swift run --skip-build lumen-cli capture-matrix --check-gate
