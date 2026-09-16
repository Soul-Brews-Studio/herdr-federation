# 04 — herdr federation

A federation of Herdr machines with one console: watch any agent's pane, type into it,
message the whole fleet, and fan one message out to a squad of agents across machines.

**One dependency: the Herdr socket.** No Sheppard, no Collie, no ttyd — pane streaming,
input, and peer sync are all ours.

Running: **m5** ↔ **white.local**, over NetBird.

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

## Run it

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
| `HERDR_SOCKET_PATH` | `~/.config/herdr/herdr.sock` | the one dependency |

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

## Security

A console URL is a write path into real terminals — treat it as a root login. The server
binds loopback by default; anything wider belongs behind the mesh.

## Known gaps

- Peers are unauthenticated: reaching a node's port is enough to drive it. `maw pair`'s
  ephemeral-code/pubkey handshake is the model for hardening.
- `pane.read` returns plain text, so colour is dropped; an ANSI-preserving renderer is the
  next step.
- Federation messages are a flat log capped at 500 entries, no channels.
