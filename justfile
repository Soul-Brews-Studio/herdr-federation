# herdr federation — one node, one console, one socket.
#
#   just              what you can do
#   just up           build the console and run the node
#   just deploy god@white.local    put this node on another machine

set shell := ["bash", "-uc"]

port := env_var_or_default("FED_PORT", "6750")
# the address peers should use to reach this node; loopback-only without it
advertise := env_var_or_default("FED_ADVERTISE", "")

_default:
    @just --list --unsorted

# build the console
build:
    cd web && bun install --silent && bun run build

# run the node (rebuilds nothing — pair with `just build`, or use `just up`)
start:
    #!/usr/bin/env bash
    set -uo pipefail
    # One node per port. Bun will happily run several copies that share the
    # socket, and then your API calls and your websocket land on different
    # processes — which looks exactly like "the handler never fired".
    just stop
    FED_HOST="${FED_HOST:-0.0.0.0}" FED_ADVERTISE="{{ advertise }}" \
        nohup bun run src/server.ts > /tmp/fed-{{ port }}.log 2>&1 &
    disown
    sleep 2
    just status

# build, then run
up: build start

stop:
    @pkill -9 -f "bun run src/server.ts" 2>/dev/null || true
    @pkill -9 -f "bun src/server.ts" 2>/dev/null || true
    @sleep 1

# is exactly one node listening, and what does it see?
status:
    #!/usr/bin/env bash
    set -uo pipefail
    n=$(lsof -nP -iTCP:{{ port }} -sTCP:LISTEN 2>/dev/null | grep -c bun || true)
    echo "listeners on {{ port }}: $n"
    [ "$n" -gt 1 ] && echo "  more than one node on this port — run 'just stop' first"
    curl -s --max-time 3 "http://127.0.0.1:{{ port }}/api/status" | bin/status.py

logs:
    @tail -f /tmp/fed-{{ port }}.log

# join another node, the way you paste a Discord invite
join url:
    @curl -s -X POST "http://127.0.0.1:{{ port }}/api/peers/join" \
        -H 'content-type: application/json' -d '{"url":"{{ url }}"}' | python3 -m json.tool

leave name:
    @curl -s -X POST "http://127.0.0.1:{{ port }}/api/peers/leave" \
        -H 'content-type: application/json' -d '{"name":"{{ name }}"}' | python3 -m json.tool

# say something to the whole federation
hey text:
    @curl -s -X POST "http://127.0.0.1:{{ port }}/api/hey" \
        -H 'content-type: application/json' -d '{"to":"*","text":"{{ text }}"}' | python3 -m json.tool

# what this node has said to herdr, as commands you could have typed
calls limit="20":
    @curl -s "http://127.0.0.1:{{ port }}/api/calls?limit={{ limit }}" | bin/calls.py

# put this node on another machine (needs bun there; it gets its own peers.json)
deploy host:
    #!/usr/bin/env bash
    set -euo pipefail
    just build
    ssh {{ host }} 'mkdir -p ~/herdr-federation/src ~/herdr-federation/web'
    rsync -az src/ {{ host }}:~/herdr-federation/src/
    rsync -az --delete web/dist/ {{ host }}:~/herdr-federation/web/dist/
    rsync -az justfile {{ host }}:~/herdr-federation/justfile
    ssh {{ host }} 'test -f ~/herdr-federation/peers.json' \
        || echo "  no peers.json on {{ host }} yet — create one from peers.example.json"
    echo "  deployed. start it there with: ssh {{ host }} 'cd herdr-federation && just start'"

check:
    bun build src/server.ts --target=bun > /dev/null
    cd web && bunx tsc -b
