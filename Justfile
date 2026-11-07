set dotenv-load

derived_data := ".build/xcode-derived"
configuration := "Release"
app_bundle := derived_data / "Build/Products" / configuration / "Canoe.app"

lint:
    swiftlint lint Sources/Canoe

lint-fix:
    swiftlint lint --fix Sources/Canoe

format:
    swift format --recursive --in-place Sources/Canoe

format-check:
    swift format lint --recursive Sources/Canoe

build:
    @if [ ! -d Sources/Oxfmt/lib/liboxfmt_shim.xcframework ]; then \
        echo 'Sources/Oxfmt/lib/liboxfmt_shim.xcframework missing - building oxfmt' >&2; \
        sh Sources/Oxfmt/build.sh; \
    fi
    xcodebuild -project Canoe.xcodeproj \
        -scheme Canoe \
        -configuration '{{ configuration }}' \
        -derivedDataPath '{{ derived_data }}' \
        "CODE_SIGN_STYLE=${CODE_SIGN_STYLE:-Manual}" \
        "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:--}" \
        "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}" \
        ONLY_ACTIVE_ARCH=YES build

build-cli:
    cd Sources/CanoeCLI && swift build -c release

clean:
    rm -rf .build

run: build
    @osascript -e 'quit app "Canoe"' 2>/dev/null || true
    @n=0; while pgrep -x Canoe >/dev/null 2>&1 && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
    @touch '{{ app_bundle }}'
    @'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister' -f '{{ app_bundle }}'
    @open '{{ app_bundle }}'

install: build build-cli
    @rm -rf ~/Applications/Canoe.app
    @cp -R '{{ app_bundle }}' ~/Applications/Canoe.app
    @echo 'Installed to ~/Applications/Canoe.app'
    @mkdir -p ~/.local/bin
    @cp Sources/CanoeCLI/.build/release/canoe ~/.local/bin/canoe
    @chmod +x ~/.local/bin/canoe
    @echo 'Installed CLI to ~/.local/bin/canoe'

uninstall:
    @osascript -e 'quit app "Canoe"' 2>/dev/null || true
    @n=0; while pgrep -x Canoe >/dev/null 2>&1 && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
    @rm -rf ~/Applications/Canoe.app
    @rm -f ~/.local/bin/canoe
    @echo 'Uninstalled ~/Applications/Canoe.app and ~/.local/bin/canoe'
