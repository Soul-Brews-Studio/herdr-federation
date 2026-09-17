# The macOS menu-bar app. Status, join, invite, kick — the admin page's verbs
# without a browser.

set working-directory := '..'

import '00-common.just'

default:
    @just --list tray

# compile only
build:
    swift build --package-path app/tray

# compile release and wrap it in a .app (no install)
bundle:
    @app/scripts/bundle-tray.sh

# ...and put it in /Applications, replacing any running copy
install:
    @app/scripts/bundle-tray.sh install

# run it straight from the build tree, logging to this terminal
run: build
    @app/tray/.build/debug/FederationTray

# what the tray will show, without opening it
config:
    @cat ~/.config/herdr-federation/tray.json
