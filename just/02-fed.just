# Membership: who federates with this node, and how that was decided.
#
# Read-only above the banner. The three recipes that change who can reach this
# node live below it and refuse without CONFIRM=yes.

set working-directory := '..'

import '00-common.just'

default:
    @just --list fed

# who federates here, what the mesh reports, who is banned
members:
    @curl -s "{{ api }}/api/admin" | bin/members.py members

# every membership decision this node made, with the steps it took
audit limit="20":
    @curl -s "{{ api }}/api/audit?limit={{ limit }}" | bin/members.py audit

# create an invite link — `uses` is null for unlimited, or a number
invite hours="24" uses="null":
    @curl -s -X POST "{{ api }}/api/invites" -H 'content-type: application/json' \
        -d '{"hours":{{ hours }},"uses":{{ uses }}}' | bin/members.py invite

# redeem someone else's invite link (paste the whole link)
redeem link:
    @bin/members.py redeem "{{ link }}" "{{ api }}"

# what this node has said to herdr, as commands you could have typed
calls limit="20":
    @curl -s "{{ api }}/api/calls?limit={{ limit }}" | bin/calls.py

# say something to the whole federation
hey text:
    @curl -s -X POST "{{ api }}/api/hey" -H 'content-type: application/json' \
        -d '{"to":"*","text":"{{ text }}"}' | python3 -m json.tool

# ── writing recipes — all three refuse without CONFIRM ─────────────
#
# A kick deletes a membership: their token stops authenticating, so their next
# call to /api/fed/* answers 401. It is enforced on THIS node only — peers see
# it published and adopt it by their own choice, never automatically.

# kick a member. Requires: just fed kick <node> CONFIRM=yes
kick node CONFIRM="no":
    #!/usr/bin/env bash
    set -uo pipefail
    CONFIRM="{{ CONFIRM }}"
    # `just fed kick white CONFIRM=yes` passes the whole token "CONFIRM=yes" as
    # the value: NAME=value only means a variable override BEFORE the recipe
    # name, and after it, it is positional. Measured on just 1.56. Accept both
    # that spelling and a bare `yes`, or the documented invocation never opens
    # the gate — which is how the upstream pattern this was copied from refuses
    # its own deploy command.
    if [ "${CONFIRM#CONFIRM=}" != "yes" ]; then
      echo "refusing: this removes {{ node }}'s access to this node."
      echo "  their token stops authenticating immediately, and this node stops"
      echo "  pushing and pulling with them. They CAN return through any invite"
      echo "  that is still valid — use 'ban' if that is not what you want."
      echo
      echo "  on record:"
      curl -s "{{ api }}/api/admin" | bin/members.py member {{ node }}
      echo
      echo "  meaning it:  just fed kick {{ node }} CONFIRM=yes"
      exit 1
    fi
    curl -s -X POST "{{ api }}/api/members/{{ node }}/kick" \
        -H 'content-type: application/json' -d '{"reason":"via just"}' | bin/members.py steps

# ban a member: a kick, plus their key is pinned so no invite lets them back
ban node CONFIRM="no":
    #!/usr/bin/env bash
    set -uo pipefail
    CONFIRM="{{ CONFIRM }}"
    # `just fed kick white CONFIRM=yes` passes the whole token "CONFIRM=yes" as
    # the value: NAME=value only means a variable override BEFORE the recipe
    # name, and after it, it is positional. Measured on just 1.56. Accept both
    # that spelling and a bare `yes`, or the documented invocation never opens
    # the gate — which is how the upstream pattern this was copied from refuses
    # its own deploy command.
    if [ "${CONFIRM#CONFIRM=}" != "yes" ]; then
      echo "refusing: a ban is a kick that outlives every future invite."
      echo "  it pins {{ node }}'s public key, so redeeming any invite is refused"
      echo "  until you 'just fed unban {{ node }}'."
      echo
      echo "  kick instead (they can come back):  just fed kick {{ node }} CONFIRM=yes"
      echo "  meaning it:                         just fed ban  {{ node }} CONFIRM=yes"
      exit 1
    fi
    curl -s -X POST "{{ api }}/api/members/{{ node }}/ban" \
        -H 'content-type: application/json' -d '{"reason":"via just"}' | bin/members.py steps

# unpin a banned key. They still need a valid invite to return.
unban node CONFIRM="no":
    #!/usr/bin/env bash
    set -uo pipefail
    CONFIRM="{{ CONFIRM }}"
    # `just fed kick white CONFIRM=yes` passes the whole token "CONFIRM=yes" as
    # the value: NAME=value only means a variable override BEFORE the recipe
    # name, and after it, it is positional. Measured on just 1.56. Accept both
    # that spelling and a bare `yes`, or the documented invocation never opens
    # the gate — which is how the upstream pattern this was copied from refuses
    # its own deploy command.
    if [ "${CONFIRM#CONFIRM=}" != "yes" ]; then
      echo "refusing: this lets {{ node }} redeem invites again."
      echo "  currently banned here:"
      curl -s "{{ api }}/api/admin" | bin/members.py bans
      echo "  meaning it:  just fed unban {{ node }} CONFIRM=yes"
      exit 1
    fi
    curl -s -X POST "{{ api }}/api/members/{{ node }}/unban" \
        -H 'content-type: application/json' -d '{}' | bin/members.py steps

# ── the pre-invite way in — works only while FED_ALLOW_LEGACY is on ─

# join by bare address, exchanging no secret
join url:
    @curl -s -X POST "{{ api }}/api/peers/join" -H 'content-type: application/json' \
        -d '{"url":"{{ url }}"}' | python3 -m json.tool

# drop a peer from our list. Does NOT revoke their access — use `kick`.
leave name:
    @curl -s -X POST "{{ api }}/api/peers/leave" -H 'content-type: application/json' \
        -d '{"name":"{{ name }}"}' | python3 -m json.tool
