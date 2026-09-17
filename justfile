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

# Kill by LISTENER, never by command-line pattern. `pkill -f "bun src/server.ts"`
# also matches the shell running THIS recipe, so `just start` killed its own
# invocation: on Linux stop died with signal 9 and the replacement server then
# hit EADDRINUSE against the instance it was supposed to have replaced.
stop:
    #!/usr/bin/env bash
    set -uo pipefail
    pids=$(lsof -nP -iTCP:{{ port }} -sTCP:LISTEN -t 2>/dev/null || true)
    if [ -z "${pids:-}" ]; then
        pids=$(ss -lntp 2>/dev/null | grep -E "[:.]{{ port }}[[:space:]]" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)
    fi
    [ -n "${pids:-}" ] && kill -9 $pids 2>/dev/null
    sleep 1
    exit 0

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

# create an invite link — hand it to another node, the way you hand out a Discord invite
# `uses` is null for unlimited, or a number for a link that is spent that many times
invite hours="24" uses="null":
    @curl -s -X POST "http://127.0.0.1:{{ port }}/api/invites" \
        -H 'content-type: application/json' \
        -d '{"hours":{{ hours }},"uses":{{ uses }}}' | bin/members.py invite

# redeem someone else's invite link (paste the whole link)
redeem link:
    @bin/members.py redeem "{{ link }}" "http://127.0.0.1:{{ port }}"

# who federates with this node, who the mesh federates with, and who is banned
members:
    @curl -s "http://127.0.0.1:{{ port }}/api/admin" | bin/members.py members

# kick: their token dies here. They can return through any invite still valid.
kick node reason="":
    @curl -s -X POST "http://127.0.0.1:{{ port }}/api/members/{{ node }}/kick" \
        -H 'content-type: application/json' -d '{"reason":"{{ reason }}"}' | bin/members.py steps

# ban: a kick, plus their key is pinned so no invite lets them back
ban node reason="":
    @curl -s -X POST "http://127.0.0.1:{{ port }}/api/members/{{ node }}/ban" \
        -H 'content-type: application/json' -d '{"reason":"{{ reason }}"}' | bin/members.py steps

# every membership decision this node made, with the steps it took
audit limit="20":
    @curl -s "http://127.0.0.1:{{ port }}/api/audit?limit={{ limit }}" | bin/members.py audit

# the pre-invite way in — works only while FED_ALLOW_LEGACY is on
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
    ssh {{ host }} 'mkdir -p ~/herdr-federation/src ~/herdr-federation/web ~/herdr-federation/bin'
    rsync -az src/ {{ host }}:~/herdr-federation/src/
    rsync -az --delete web/dist/ {{ host }}:~/herdr-federation/web/dist/
    # the justfile shells out to these — deploying without them breaks every recipe there
    rsync -az bin/ {{ host }}:~/herdr-federation/bin/
    rsync -az justfile {{ host }}:~/herdr-federation/justfile
    ssh {{ host }} 'test -f ~/herdr-federation/peers.json' \
        || echo "  no peers.json on {{ host }} yet — create one from peers.example.json"
    echo "  deployed. start it there with: ssh {{ host }} 'cd herdr-federation && just start'"

check:
    bun build src/server.ts --target=bun > /dev/null
    cd web && bunx tsc -b
