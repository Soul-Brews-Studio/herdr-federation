# Put this node on another machine. Writes to a box, so it names itself.

set working-directory := '..'

import '00-common.just'

default:
    @just --list deploy

# ship src, the built console, bin/ and the justfiles. Requires CONFIRM=yes.
host target CONFIRM="no":
    #!/usr/bin/env bash
    set -euo pipefail
    CONFIRM="{{ CONFIRM }}"
    # `just fed kick white CONFIRM=yes` passes the whole token "CONFIRM=yes" as
    # the value: NAME=value only means a variable override BEFORE the recipe
    # name, and after it, it is positional. Measured on just 1.56. Accept both
    # that spelling and a bare `yes`, or the documented invocation never opens
    # the gate — which is how the upstream pattern this was copied from refuses
    # its own deploy command.
    if [ "${CONFIRM#CONFIRM=}" != "yes" ]; then
      echo "refusing: this overwrites ~/herdr-federation on {{ target }}."
      echo "  it replaces src/, web/dist/, bin/ and the justfiles there, and"
      echo "  web/dist is rsynced with --delete. It does NOT touch that node's"
      echo "  peers.json, .fed-identity.json or .fed-members.json — its identity"
      echo "  and its memberships survive."
      echo
      echo "  what is there now:"
      ssh {{ target }} 'cd ~/herdr-federation 2>/dev/null && ls -d src web/dist bin justfile just 2>/dev/null | sed "s/^/    /" || echo "    (nothing yet)"'
      echo
      echo "  meaning it:  just deploy host {{ target }} CONFIRM=yes"
      exit 1
    fi
    just node build
    ssh {{ target }} 'mkdir -p ~/herdr-federation/src ~/herdr-federation/web ~/herdr-federation/bin ~/herdr-federation/just'
    rsync -az src/ {{ target }}:~/herdr-federation/src/
    rsync -az --delete web/dist/ {{ target }}:~/herdr-federation/web/dist/
    # the justfiles shell out to these — deploying without them breaks every recipe there
    rsync -az bin/ {{ target }}:~/herdr-federation/bin/
    rsync -az --delete just/ {{ target }}:~/herdr-federation/just/
    rsync -az justfile {{ target }}:~/herdr-federation/justfile
    ssh {{ target }} 'test -f ~/herdr-federation/peers.json' \
        || echo "  no peers.json on {{ target }} yet — create one from peers.example.json"
    echo "  deployed. start it there with: ssh {{ target }} 'cd herdr-federation && just node start'"

# what is running there
status target:
    @ssh {{ target }} 'cd ~/herdr-federation && just node status'

# membership there
members target:
    @ssh {{ target }} 'cd ~/herdr-federation && just fed members'
