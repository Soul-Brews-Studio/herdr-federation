# The process: build it, run it, see it, stop it.
#
# `set working-directory` is load-bearing. A `mod` recipe runs with its cwd set
# to the MODULE FILE's directory, so `bun run src/server.ts` here would look for
# src/ inside just/. `import` does not move the cwd; `mod` does.

set working-directory := '..'

import '00-common.just'

default:
    @just --list node

# build the console
build:
    cd web && bun install --silent && bun run build

# run the node (rebuilds nothing — pair with `just node build`, or use `just up`)
start:
    #!/usr/bin/env bash
    set -uo pipefail
    # One node per port. Bun will happily run several copies that share the
    # socket, and then your API calls and your websocket land on different
    # processes — which looks exactly like "the handler never fired".
    just node stop
    FED_HOST="${FED_HOST:-0.0.0.0}" FED_ADVERTISE="{{ advertise }}" \
        nohup bun run src/server.ts > /tmp/fed-{{ port }}.log 2>&1 &
    disown
    sleep 2
    just node status

# Kill by LISTENER, never by command-line pattern. `pkill -f "bun src/server.ts"`
# also matches the shell running THIS recipe, so `just start` killed its own
# invocation: on Linux stop died with signal 9 and the replacement server then
# hit EADDRINUSE against the instance it was supposed to have replaced.

# stop whatever is listening on the port
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
    [ "$n" -gt 1 ] && echo "  more than one node on this port — run 'just node stop' first"
    curl -s --max-time 3 "{{ api }}/api/status" | bin/status.py

logs:
    @tail -f /tmp/fed-{{ port }}.log

# typecheck the server and the console
check:
    bun build src/server.ts --target=bun > /dev/null
    cd web && bunx tsc -b
