---
name: herdr-federation
description: Run and drive a herdr-federation node — list agents across every federated machine, read a pane anywhere in the mesh, send a message to one agent or a squad, and join or leave a federation with invite links. Use for "what is running on the fleet", "peek at that agent", "tell <agent> to ...", "join this federation". Not for starting Herdr itself, and not a generic SSH or tmux tool.
---

# herdr-federation

A node exposes every Herdr agent pane on its machine over HTTP, and federates with
other nodes so one console covers the fleet. You talk to **one** node; it routes.

Default node: `http://127.0.0.1:6750`. Override with `HERDR_FED_URL`.

## Start a node

```bash
bunx herdr-federation            # seeds config + identity on first run, binds loopback
```

Bun only — `npx` cannot run it. Already running? `curl -s localhost:6750/api/status`
answers, and starting a second on the same port is the common self-inflicted bug:
Bun will happily bind twice and your calls land on different processes.

## See what is running

Prefer the CLI when the [`herdr` maw plugin](https://github.com/Soul-Brews-Studio/maw-herdr-plugin)
is installed — it is built for reading:

```bash
maw herdr ls --federation          # every agent on every reachable node, grouped
maw herdr ls --federation --agents # drop bare shells
maw herdr federation               # the mesh: who we hold, who relays what
```

Otherwise the API, which is the same data:

```bash
curl -s localhost:6750/api/status | jq '{node, peers: [.peers[].name], mine: (.members|length)}'
```

Read `/api/status` this way:

- `members` — agent panes on **this** node.
- `peerMembers` — keyed by node, the panes on every node we can see.
- `peers[].via` — **set means we hold no link to that node**; we see it through the
  named hub. Its `ok`/`consecutive` describe the *hub's* link, not ours. Anything
  that treats `peers` as "links this node keeps" must filter on `via`.
- `known` — heard from, never joined. Not reachable; do not try to act on it.

## Read a pane

```bash
maw herdr peek <pane>                 # a pane on this machine
maw herdr peek <node>:<pane>          # a pane anywhere in the federation
maw herdr peek <node>:<pane> --lines 80
```

The colon is a node address only when the part before it names a known node — Herdr
pane ids are colon-shaped too (`w2V:p1`).

Via API, which routes by node so you never need to know direct-vs-relayed:

```bash
curl -s -X POST localhost:6750/api/fleet/pane -H 'content-type: application/json' \
  -d '{"node":"white","pane":"w4:p1","lines":40}' | jq -r .text
```

**Reads are always the rendered viewport, never scrollback.** This is not
configurable, and you should not look for a flag: herdr serves scrollback by driving
the pane's own mouse-scroll, so the operator watches their real terminal scroll and
snap back — and it takes ~13.8s against ~0.1s. A read that moves the thing being read
is not a read.

## Send a message

Sending types into a **real terminal a human is using**. Confirm the target with the
user before sending anything they did not dictate, and read it back afterwards.

```bash
maw herdr hey <target> "message"          # one agent on this machine
maw herdr hey <target> --dry-run "…"      # resolve and show, send nothing
```

Across the federation, by node — a direct peer or through its hub, authenticated
either way:

```bash
curl -s -X POST localhost:6750/api/broadcast -H 'content-type: application/json' \
  -d '{"targets":[{"handle":"god-oracle","node":"white"}],"text":"…"}' | jq '.results'
```

Each result carries `ok` and, on failure, the reason from the node that refused —
`no agent X on white` means white itself answered. Report that verbatim; do not retry
a different target because one failed.

## Join and leave

Membership is pairwise; **visibility is not**. Joining one node shows you every agent
that node can see, so a new machine needs exactly one invite, not one per peer.

```bash
just fed invite                 # on the inviting node: 24h, unlimited uses
just fed invite 24 1            # single use
just fed redeem "<link>"        # on the joining node — paste the whole link
just fed members                # who federates here, and what the mesh reports
```

The invite secret **is** the credential until it is spent. Treat a link like a
password: never paste one into a shared channel, a commit, an issue, or a log.

## Things that will mislead you

| reading | what it actually means |
|---|---|
| `stats.errors` climbing | lifetime total since boot; never decays. For health read `peers[].consecutive`. |
| `stats.pulled: 0` | no *messages* to ingest. Requests are `pullOk`. Not a failure. |
| `peers[].ok` on a `via` row | the hub's link to that node, not yours |
| a peer's reported membership | arrived on the last **successful** pull; if the link is failing it is stale, and `edges[].stale` says so |
| console 503 | the API is fine; only the static console is missing |

## Refuse to do

- **Kick, ban and deploy without the user asking.** Each refuses without `CONFIRM=yes`
  and prints what it would do — show the user that output and stop.
- **Restart a node to "fix" something** before reading `/api/status`. A restart clears
  the in-memory peer health and the tray's window, destroying the evidence.
- **Send to `*`** unless the user explicitly asked to message the whole federation.

## Security boundaries

The console has **no authentication**: whoever reaches the port is that node's admin,
and that port is a write path into real terminals. It binds loopback by default —
never suggest widening it beyond a private mesh.

`.fed-identity.json` holds the node's ed25519 **private key**. Never print it, never
`cat` it, never include it in a report; a 200-byte excerpt is the whole key. To check
identity use `/api/status | jq .identity` — public key and fingerprint only.
