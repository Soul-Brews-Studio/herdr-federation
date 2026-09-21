# The Swift node: a second implementation of src/*.ts, macOS only, one
# binary, no Bun. Same wire, same FED_* env, same peers.json/.fed-*.json
# state — a Bun peer cannot tell which runtime answered it.

set working-directory := '..'

import '00-common.just'

default:
    @just --list swift

# compile (debug)
build:
    swift build --package-path app/node

# compile (release) — what install ships
release:
    swift build --package-path app/node -c release

# run the test suite
test:
    swift test --package-path app/node

# run the debug binary in the foreground, same env the Bun node reads
run:
    #!/usr/bin/env bash
    set -uo pipefail
    FED_PORT="{{ port }}" FED_HOST="${FED_HOST:-0.0.0.0}" FED_ADVERTISE="{{ advertise }}" \
        app/node/.build/debug/herdr-federation-node

# build + boot a scratch node in .tmp/, hit every route, tear it down
smoke:
    @app/node/utils/smoke.sh

# Bun and Swift, side by side, same requests. Written in a later phase —
# this recipe exists so `just --list swift` already shows the shape.
conformance:
    bun app/node/utils/conformance.ts

# put the release binary on PATH and load the LaunchAgent
install:
    #!/usr/bin/env bash
    set -euo pipefail
    just swift release
    mkdir -p ~/.local/bin ~/Library/Logs/herdr-federation ~/Library/LaunchAgents
    cp app/node/.build/release/herdr-federation-node ~/.local/bin/herdr-federation-node
    repo="$(pwd -P)"
    sed -e "s#__REPO__#${repo}#" \
        -e "s#__HOME__#${HOME}#" \
        -e "s#__FED_ADVERTISE__#{{ advertise }}#" \
        -e "s#__FED_ALLOW_LEGACY__#${FED_ALLOW_LEGACY:-1}#" \
        app/launchd/com.herdr-federation.node.plist \
        > ~/Library/LaunchAgents/com.herdr-federation.node.plist
    launchctl unload ~/Library/LaunchAgents/com.herdr-federation.node.plist 2>/dev/null || true
    launchctl load -w ~/Library/LaunchAgents/com.herdr-federation.node.plist
    echo "installed — logs: ~/Library/Logs/herdr-federation/"

# unload the LaunchAgent and remove the installed binary
uninstall:
    #!/usr/bin/env bash
    set -uo pipefail
    launchctl unload ~/Library/LaunchAgents/com.herdr-federation.node.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.herdr-federation.node.plist
    rm -f ~/.local/bin/herdr-federation-node
    echo "uninstalled"
