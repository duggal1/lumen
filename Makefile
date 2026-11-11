.PHONY: build test verify app probe hooks capture-e2e

build:
	swift build

# An interrupted SwiftPM test run leaves swiftpm-testing-helper parented to
# launchd; it keeps .build/.lock and makes the next build/push look hung.
# Reap only those orphans, then run the suite the same way CI does.
test:
	@for pid in $$(pgrep -f 'swiftpm-testing-helper.*LumenTests' || true); do \
		[ "$$(ps -o ppid= -p $$pid | tr -d ' ')" = "1" ] && kill -9 $$pid || true; \
	done
	swift test --no-parallel

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
