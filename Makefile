.PHONY: build test verify app probe

build:
	swift build

test:
	swift test

app:
	bash Tools/make-app.sh

verify: test app
	.build/Lumen.app/Contents/MacOS/Lumen --help >/dev/null 2>&1 & pid=$$!; sleep 2; kill -0 $$pid; kill $$pid
	@echo 'Build, integration tests, packaging and launch passed. Hardware capture/sync/performance checks remain separate.'

probe: build
	swift run --skip-build lumen-cli probe
