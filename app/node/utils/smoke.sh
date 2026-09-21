#!/usr/bin/env bash
# smoke.sh — build the Swift node and hit every route once, from a scratch
# state dir. Not conformance (that diffs Bun vs Swift byte-for-byte — a later
# phase writes it as conformance.ts); this only proves the binary answers.
#
# Run via `just swift smoke`, from the repo root (cwd matters: the console
# fallback and relative FED_* paths below all resolve against it).
set -euo pipefail

REPO_ROOT="$(pwd -P)"
SCRATCH="${REPO_ROOT}/.tmp/smoke"
BIN="${REPO_ROOT}/app/node/.build/debug/herdr-federation-node"
PORT=6761
BASE="http://127.0.0.1:${PORT}"
SERVER_PID=""

fail=0
step=""

log() { echo "[smoke] $*"; }

# The node must never end up running after this script exits, pass or fail —
# a leaked debug node on :6761 would make the NEXT smoke run's "wait for
# /api/status" pass instantly against the wrong process.
cleanup() {
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

fail_here() {
    echo "[smoke] FAIL: ${step}"
    echo "[smoke]   $*"
    exit 1
}

# assert_status METHOD PATH EXPECTED_CODE [JSON_BODY]
assert_status() {
    local method="$1" path="$2" expect="$3" body="${4:-}"
    step="${method} ${path} -> ${expect}"
    local out code
    if [ -n "${body}" ]; then
        out=$(curl -s -o /dev/null -w '%{http_code}' -X "${method}" \
            -H 'content-type: application/json' -d "${body}" "${BASE}${path}")
    else
        out=$(curl -s -o /dev/null -w '%{http_code}' -X "${method}" "${BASE}${path}")
    fi
    code="${out}"
    if [ "${code}" != "${expect}" ]; then
        fail_here "curl -X ${method} ${BASE}${path} ${body:+-d \'${body}\'} -> ${code}, wanted ${expect}"
    fi
    log "ok: ${step} (got ${code})"
}

# GET /api/status and check .node == "smoke" without ever printing the body
# (it may carry no secrets today, but the rule is never cat the identity —
# so this checks the field with jq/grep rather than echoing the JSON).
assert_status_node() {
    step="GET /api/status -> .node == smoke"
    local body
    body=$(curl -s "${BASE}/api/status")
    if ! printf '%s' "${body}" | grep -q '"node"[[:space:]]*:[[:space:]]*"smoke"'; then
        fail_here "GET ${BASE}/api/status did not report node=\"smoke\""
    fi
    log "ok: ${step}"
}

log "building debug binary..."
swift build --package-path "${REPO_ROOT}/app/node" >/dev/null

log "scratch state at ${SCRATCH}"
rm -rf "${SCRATCH}"
mkdir -p "${SCRATCH}"
cat > "${SCRATCH}/peers.json" <<'JSON'
{"node":"smoke","peers":[]}
JSON

export FED_CONFIG="${SCRATCH}/peers.json"
export FED_STATE="${SCRATCH}/.fed-state.json"
export FED_IDENTITY="${SCRATCH}/.fed-identity.json"
export FED_MEMBERS="${SCRATCH}/.fed-members.json"
export FED_PORT="${PORT}"
export FED_HOST="127.0.0.1"
export FED_LOG="access"

log "starting node on :${PORT} (FED_ALLOW_LEGACY default = on)..."
(cd "${REPO_ROOT}" && "${BIN}") &
SERVER_PID=$!

step="wait for /api/status"
waited=0
until curl -s -o /dev/null --max-time 1 "${BASE}/api/status"; do
    waited=$(( waited + 1 ))
    if [ "${waited}" -ge 30 ]; then
        fail_here "node never answered /api/status within 15s"
    fi
    sleep 0.5
done
log "node is up"

assert_status_node
assert_status GET  /api/invite         200
assert_status GET  /api/members        200
assert_status GET  /api/admin          200
assert_status GET  /api/fed/state      200
assert_status POST /api/fed/hey        400 '{}'
assert_status POST /api/fed/pane       400 '{"pane":"bad pane"}'
assert_status POST /api/fleet/hey      404 '{"node":"nope","to":"x","text":"y"}'
assert_status POST /api/hey            400 '{}'
assert_status GET  /ws/pane/w1:p1      426
assert_status GET  '/api/pane/bad%20pane' 400

log "restarting with FED_ALLOW_LEGACY=0..."
kill "${SERVER_PID}" 2>/dev/null || true
wait "${SERVER_PID}" 2>/dev/null || true
SERVER_PID=""

export FED_ALLOW_LEGACY=0
(cd "${REPO_ROOT}" && "${BIN}") &
SERVER_PID=$!

step="wait for /api/status (legacy off)"
waited=0
until curl -s -o /dev/null --max-time 1 "${BASE}/api/status"; do
    waited=$(( waited + 1 ))
    if [ "${waited}" -ge 30 ]; then
        fail_here "node never answered /api/status within 15s (legacy off)"
    fi
    sleep 0.5
done

assert_status GET /api/fed/state 401

log "all checks passed."
