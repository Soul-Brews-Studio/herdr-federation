# 04 — herdr federation

A federation of Herdr machines with one console: watch any agent's pane, type into it,
message the whole fleet, and fan one message out to a squad of agents across machines.

**One dependency: the Herdr socket.** No Sheppard, no Collie, no ttyd — pane streaming,
input, and peer sync are all ours.

Built and run across four nodes on a private NetBird mesh — two of them the same
host under different Unix users, which is why a node is addressed by name, never
by host.

> **Alpha — `v26.9.18-alpha.17`.** This runs a real fleet every day, and it is
> still early software with the sharp edges written down rather than smoothed
> over. Read [Known gaps](#known-gaps) before you point it at anything you care
> about: the console has **no authentication**, so whoever reaches the port is
> that node's admin, and `FED_ALLOW_LEGACY` still defaults to on. Bind it to
> loopback or a private mesh, never to the internet.
>
> Versioning is CalVer — `v{yy}.{m}.{d}-alpha.{HMM}`, where `HMM` is the
> wall-clock hour and minute as one integer (00:11 → `11`, 09:37 → `937`), in
> Asia/Bangkok. No two cuts in a minute, so tags never collide on merge order.

## Shape

```
src/herdr.ts      the socket client — newline-delimited JSON over $HERDR_SOCKET_PATH
src/federation.ts our own message log + peer sync (push and pull, both outbound)
src/server.ts     HTTP + WebSocket + static, the whole node
web/              React + TypeScript + Tailwind console (Vite)
```

## Why the transport is outbound-only

NetBird reports `Connected / P2P` in both directions between m5 and white, but traffic only
flows m5 → white; white → m5 is blackholed at the IP layer (ICMP fails too) because m5 runs
NetBird in **userspace** mode, where inbound to the overlay IP never reaches a kernel socket.
Rebinding to `0.0.0.0` does not help — it is below the app layer.

So a node never relies on being reachable: it **pushes** its own messages to each peer *and*
**pulls** each peer's. One reachable direction is enough, and NAT'd nodes participate fully.
Messages carry an origin id (`node:seq`), so dedup is exact and echo is impossible.

## The socket contract, as used

| call | used for |
|---|---|
| `agent.list` | the roster — every agent, its pane, cwd, status |
| `pane.read {pane_id, source, lines, format}` | pane content, with a `revision` to diff against |
| `pane.send_text {pane_id, text}` | typing — raw bytes, no bracketed paste, no Enter |
| `pane.send_keys {pane_id, keys}` | `Enter`, `Escape`, `ctrl+c`, … herdr's grammar, **not** tmux's (`C-c` is rejected) |

RPC is one-shot — the server closes after a single reply, so every call opens its own
connection. Requests are capped at 1 MiB.

Panes stream over our own WebSocket (`/ws/pane/<pane_id>`): the server polls `pane.read` with
`source: "visible"` and ships a frame only when the **text** changes. Many viewers can watch one
pane — `terminal attach` could not, since it demands exclusive input ownership and refuses a
second client.

**A background poll must use `source: "visible"`.** `recent` asks for scrollback, and on an idle
agent herdr collects it by driving the pane's own mouse-scroll: the operator watches their real
terminal scroll up and snap back, once per read. It is slow too — a 400-line `recent` text read
measures ~13.8s against ~0.1s for `visible`. `visible` is the rendered viewport, clamped however
large `lines` is, and immune by construction.

The catch that makes `visible` look broken: its `revision` never moves (it is always `0`), so a
stream that only ships when the revision changes shows a permanently frozen pane. Diff the text.

## Install and run

```sh
npx  herdr-federation                # one command — seeds config, mints identity, starts
bunx herdr-federation                # same, if you already have Bun
```

**The server is Bun-native** (`Bun.serve` and its WebSocket upgrade, `Bun.file`,
`Bun.write`), and Node has no built-in WebSocket server, so `npx` runs a launcher, not
a Node port: it finds Bun and hands over. Bun is an *optional* dependency, so npm
installs it automatically on supported platforms and the launcher falls back to one
already on the machine; with none at all it says exactly that and how to get one
(`curl -fsSL https://bun.sh/install | bash`).

Installed, state lives in `$XDG_STATE_HOME/herdr-federation` (override with
`$HERDR_FED_HOME`), not beside the package — a bunx cache is not writable and an
npm install belongs to `node_modules`. First run writes a `peers.json` naming this
host and joins nothing; you federate by pasting an invite link into the console.

Straight from source, no registry:

```sh
bunx github:Soul-Brews-Studio/herdr-federation
```

This works today and serves the **API only**: build output is gitignored, so the
GitHub tarball carries no `web/dist` and `/` answers 503 with which case you are in.
The npm release ships the built console.

From a checkout, unchanged — state stays in the repo directory:

```sh
cp peers.example.json peers.json     # node name + peers
cd web && bun install && bun run build
cd .. && bun run src/server.ts       # http://127.0.0.1:6750
```

| env | default | meaning |
|---|---|---|
| `FED_CONFIG` | `./peers.json` | node + peer list |
| `FED_HOST` / `FED_PORT` | `127.0.0.1` / `6750` | bind |
| `FED_SYNC_MS` | `2000` | peer sync interval |
| `FED_PANE_MS` | `700` | pane poll interval |
| `FED_ADVERTISE` | — | the address peers should use; without it this node cannot issue a working invite |
| `FED_ALLOW_LEGACY` | `1` | accept peers that have no member token — **turn this off once every peer is re-invited** |
| `FED_LOG` | `access` | one line per request: time, status, method, path, ms. `debug` adds content-type and every WebSocket open/close; `off` silences it |
| `HERDR_FED_HOME` | `$XDG_STATE_HOME/herdr-federation` | where an *installed* node keeps its four state files; a checkout uses its own directory |
| `FED_IDENTITY` / `FED_MEMBERS` | `./.fed-identity.json` / `./.fed-members.json` | private key, and the membership store (both gitignored) |
| `HERDR_SOCKET_PATH` | `~/.config/herdr/herdr.sock` | the one dependency |

A node **refuses to start when its port already answers**. Bun shares the socket rather
than failing on a second bind, so two nodes on `:6750` both accept and every call lands
on whichever got there first — measured: a second node started from a bunx cache
reported `peers: 0` while the real node beside it held three healthy links. Use
`FED_PORT` for a second node, or stop the first.

## Watching

```sh
bun bin/watch.ts                                   # every 15s, this node
bun bin/watch.ts --every 30 --peek white:w4:p1     # slower, and dump that pane on any change
HERDR_FED_URL=http://host:6750 bun bin/watch.ts    # watch another node
```

Prints only what **changed** — an agent's status, one appearing or vanishing, a link
going down or recovering. A poll that reprints the roster every tick buries the one
line that matters; quiet here means nothing happened.

When the node itself goes unreachable it says so once and keeps the last known good
snapshot, so the diff printed on recovery is the report you actually want rather than
every agent re-appearing from nothing.

## For an AI agent

`skills/herdr-federation/SKILL.md` is a [SKILL.md](https://code.claude.com/docs/en/skills)
an agent can load to drive a node without being told the shape of the API. Install it
by symlink so it tracks the checkout:

```sh
ln -s "$PWD/skills/herdr-federation" ~/.claude/skills/herdr-federation
# Codex and other SKILL.md-compatible agents:
ln -s "$PWD/skills/herdr-federation" "${CODEX_HOME:-$HOME/.codex}/skills/herdr-federation"
```

It covers reading the fleet, peeking a pane anywhere in the mesh, sending to an agent
through a hub, and joining with an invite — plus the parts that reliably mislead a
first reader: `stats.errors` is a lifetime total and not health, `pulled: 0` is normal,
a `via` row's health belongs to the hub and not to you, and a peer's reported
membership is only as fresh as the last successful pull.

It also states what an agent must not do on its own: kick, ban and deploy all refuse
without `CONFIRM=yes`, a restart destroys the peer-health evidence you were about to
read, and `.fed-identity.json` is a private key that must never be printed — 200 bytes
of it is the whole key.

## The console

Both pages share one `MachinesTree` component — machine → repo → agents, the shape Herdr's
own sidebar uses, with repo derived from each agent's cwd.

- **console** (`/`) — tabs of live panes. `/t/<node>/<pane>/<ro|rw>` is a real route, so a
  reload restores the view and back walks the tabs. Watching never sends a byte; typing is
  opt-in per tab. Pane type size is adjustable and remembered.
- **squads** (`/teams`) — drag agents from any machine into a squad; every member shows its
  live pane, and one message fans out to all of them in a single click. Squad members are
  re-resolved against the live roster each tick, so a restarted agent's new pane id heals
  itself.

## Joining and kicking

Membership works the way a Discord server does, adapted to a mesh with no server above the
nodes. `/admin` shows all of it, and draws each process from the steps the node actually
recorded rather than from a description of them.

**Joining** — five steps, and step 3 is the one people trip over:

```
A = the node that invites        B = the node that joins
1. A  creates an invite       POST /api/invites        → http://A:6750/join/<secret>
2. B  opens the link          GET  /join/<secret>      → A's invite page
3. B  clicks "join as my node" → http://B:6750/join?from=A&t=<secret>
4. B  confirms on its own console, then presents the invite to A:
      POST A/api/fed/redeem {token, node, pubkey, url, offerToken, at, sig}
      A checks: invite known? still active? key not banned? request fresh? signature valid?
      A replies with the token B must present from now on; B's `offerToken` is A's.
5. both store the membership, and sync starts — every call carries `x-fed-token`.
```

Step 3 exists because **a browser cannot join anything — a node can**. Opening an invite
link proves only that you can open a link, so the page hands off to the console running on
your own machine, the way a Discord invite hands off to the app. That console always asks
before joining: a link anyone can send you must not federate your machine on its own.

**Kicking** deletes the membership. Their token stops authenticating, so their next call to
`/api/fed/*` answers 401 — that is the whole difference from the old `leave`, which only
stopped *us* calling *them* and left their door into us open. They can return through any
invite that is still valid. **Banning** additionally pins their ed25519 public key, so no
invite helps.

### The hub model — join one node, see everyone it sees

Membership is pairwise, but **visibility is not**. A node republishes the rosters of
its direct peers, so joining one node shows you every agent that node can see:

```
● black                         ← holds exactly one link, to m5
└─ ⇄ ● m5  34 panes
     ├─ ◌ ● white      1 pane · via m5
     └─ ◌ ● nat-white  1 pane · via m5
```

`⇄` is an edge this node holds, judged for reciprocity. `◌` is something it can only
*see*. Four rules keep the difference honest:

- **Strictly one hop.** A node republishes only what it pulled directly, never what it
  was itself relayed, so a ring of nodes cannot echo state around forever.
- **A direct link beats a relayed one**, and a node never relays itself back to itself.
- **Rebuilt from scratch on every pull.** When a hub kicks a node, it is gone from every
  spoke on the next sync — one kick at the hub, gone everywhere, with no adopt step. It
  does *not* kick that node off the spokes: a spoke that holds its own membership keeps
  it, because enforcement stays local.
- **Relayed health is the hub's health**, and is labelled as such. A hub failing to reach
  a third machine is not your link being down.

Acting through a hub is authenticated on both legs — `/api/fed/hey` and `/api/fed/pane`
for a peer holding your token, `/api/fed/relay` and `/api/fed/pane-relay` for a spoke,
both of which refuse to relay a relay. What a hub **cannot** give you is a live pane
stream: `/ws/pane/<id>` on the hub would open the hub's own pane of that id. Through a
hub you get *see and send*, not *watch*.

With the [`herdr` maw plugin](https://github.com/Soul-Brews-Studio/maw-herdr-plugin):

```sh
maw herdr federation          # the mesh, with relayed nodes under their hub
maw herdr ls --federation     # every agent on every reachable node
maw herdr peek <node>:<pane>  # read a pane anywhere in the federation
```

**A kick is enforced on this node only**, and that is the honest answer rather than a
shortcut. There is no server above these nodes, so a mesh-wide kick would mean every node
obeying any other node — and one compromised node could then empty the mesh with nobody
entitled to refuse. Kicks are published instead; a peer sees them on its admin page and
adopts them with a click, the way a Matrix homeserver keeps its own ACL.

The justfile is split one module per concern — `node`, `fed`, `deploy` — with
reads free and every write refusing until it is confirmed:

```sh
just                        # modules and top-level recipes
just up                     # build the console, run the node
just overview               # the process and the federation in one screen

just fed invite             # 24h, unlimited uses · just fed invite 24 1 → single use
just fed redeem <link>      # tell this node to go join theirs
just fed members            # who federates here, what the mesh reports, who is banned
just fed audit              # every decision, with the steps it took

just fed kick <node>        # REFUSES, and prints who it would remove
just fed kick <node> CONFIRM=yes
just fed ban  <node> CONFIRM=yes
just deploy host <target> CONFIRM=yes
```

A bare `just fed kick white` prints the member on record — key, join time, which
invite they came in through — and the command that would mean it. Nothing
changes. The same shape guards `ban`, `unban` and `deploy host`.

Two things about `just` that cost real time here, written down so they do not
again:

- **A `mod` recipe runs with its cwd set to the module file's directory.**
  `justfile_directory()` stays at the root, but `pwd` does not, so `bun run
  src/server.ts` in a module looks inside `just/`. `set working-directory := '..'`
  at the top of each module fixes it once; `import` does not move the cwd at all.
- **`NAME=value` after a recipe name is positional, not a variable override.**
  `just fed kick white CONFIRM=yes` passes the literal string `CONFIRM=yes` as
  the parameter, so a naive `[ "$CONFIRM" != "yes" ]` guard never opens and the
  documented command always refuses. These recipes strip the prefix, so both
  `CONFIRM=yes` and a bare `yes` work.

## Security

A console URL is a write path into real terminals — treat it as a root login. The server
binds loopback by default; anything wider belongs behind the mesh.

Between nodes, identity is an ed25519 keypair minted on first boot (`.fed-identity.json`)
and the credential is a random token issued at redemption. The key is signed with exactly
once, when an invite is redeemed, because a ban has to outlive a token: tokens are handed
out and revoked, the public key is the stable thing a ban can pin to.

That token travels in a plain HTTP header. Over NetBird the transport is already encrypted;
over a flat LAN it is not, so anyone who can capture traffic there can capture the token.
This raises the node from *no authentication at all* to a bearer token on a private mesh —
it is not end-to-end. Signing every request would close that, and the identity module is
already there for it.

## Known gaps

- `FED_ALLOW_LEGACY` defaults to **on**, so a peer with no token is still accepted and a
  kick does not yet fully close the door. It exists so an already-federated pair does not go
  dark on deploy; re-invite every peer, then restart with `FED_ALLOW_LEGACY=0`.
- The member token is a bearer credential in a header, not a per-request signature, so a LAN
  attacker who can read traffic can replay it.
- The console itself is unauthenticated: whoever reaches the port is the node's admin.
- `pane.read` returns plain text, so colour is dropped; an ANSI-preserving renderer is the
  next step.
- Federation messages are a flat log capped at 500 entries, no channels.
- Anything that reads `status.peers` as "links this node keeps" now also gets relayed
  rows and must filter on `via`. The three readers in this repo do; a fourth would get
  it wrong silently, which argues for renaming the field.
- Throughput in the tray counts request and response **bodies** only — no headers, no
  TLS — so it is payload rate, not what a network interface would report.
