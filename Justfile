set dotenv-load

derived_data := ".build/xcode-derived"
configuration := "Release"
app_bundle := derived_data / "Build/Products" / configuration / "Canoe.app"

lint:
    swiftlint lint Sources

lint-fix:
    swiftlint lint --fix Sources

format:
    swift format --recursive --in-place Sources

format-check:
    swift format lint --recursive Sources

build:
    xcodebuild -project Canoe.xcodeproj \
        -scheme Canoe \
        -configuration '{{ configuration }}' \
        -derivedDataPath '{{ derived_data }}' \
        -allowProvisioningUpdates \
        "CODE_SIGN_STYLE=${CODE_SIGN_STYLE:-Automatic}" \
        "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:--}" \
        "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}" \
        ONLY_ACTIVE_ARCH=YES build

run: build
    #!/usr/bin/env bash
    set -euo pipefail
    # Quit the running instance first - otherwise `open` merely activates the
    # stale process and the freshly built binary never gets launched. Graceful
    # quit first (flushes pending edits via applicationShouldTerminate), then
    # force-kill as a fallback if it hangs.
    if pgrep -x Canoe >/dev/null 2>&1; then
        osascript -e 'tell application "Canoe" to quit' >/dev/null 2>&1 || true
        for _ in {1..30}; do
            pgrep -x Canoe >/dev/null 2>&1 || break
            sleep 0.1
        done
        pkill -x Canoe 2>/dev/null || true
        sleep 0.2
    fi
    open '{{ app_bundle }}'

install: build
    @rm -rf ~/Applications/Canoe.app
    @cp -R '{{ app_bundle }}' ~/Applications/Canoe.app
    @echo 'Installed to ~/Applications/Canoe.app'

clean:
    rm -rf .build
