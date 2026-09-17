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

# Measured the hard way: a host rebooted and both nodes on it were simply
# gone. 6,862 failed syncs later nobody had noticed except the tray.

# install a systemd user unit so a reboot does not end federation
install-service port="6750" advertise="":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.config/herdr-federation ~/.config/systemd/user ~/.local/state
    cat > ~/.config/herdr-federation/node.env <<ENV
    FED_PORT={{ port }}
    FED_HOST=0.0.0.0
    FED_ADVERTISE={{ advertise }}
    FED_ALLOW_LEGACY=0
    ENV
    sed -i'' -e 's/^    //' ~/.config/herdr-federation/node.env
    cp app/systemd/herdr-federation.service ~/.config/systemd/user/
    systemctl --user daemon-reload
    # Free the port THIS node wants, not the one `just node stop` defaults to.
    # `port` defaults to 6750, and on a host where two users each run a node
    # (measured: god on :6750, nat on :6751) that default aims at the OTHER
    # user's process. It fails on permissions rather than doing damage, but it
    # also means the handover silently does nothing and systemd then dies on
    # EADDRINUSE — which is exactly what happened here.
    pids=$(ss -lntp 2>/dev/null | grep ":{{ port }} " | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -u || true)
    for p in ${pids:-}; do kill -9 "$p" 2>/dev/null || echo "  note: $p belongs to another user — not ours to stop"; done
    sleep 1
    systemctl --user enable --now herdr-federation
    loginctl enable-linger "$USER" 2>/dev/null || echo "  note: could not enable linger — the node stops when you log out"
    sleep 2
    systemctl --user --no-pager status herdr-federation | head -4

# typecheck the server and the console
check:
    bun build src/server.ts --target=bun > /dev/null
    cd web && bunx tsc -b
