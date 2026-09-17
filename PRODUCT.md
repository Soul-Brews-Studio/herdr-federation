# herdr-federation

## What it is

One console over every Herdr pane on a fleet of machines. Watch any agent's pane
live, type into it, message the whole federation, and fan one message out to a
squad of agents across machines. Its only dependency is the Herdr Unix socket.

## The unique mechanism

Most fleet tools put a server above the machines. This one refuses to. Every node
runs its own copy, holds its own door, and federates peer-to-peer: membership is
mutual and **enforcement is local-only** — a kick binds the node that issued it,
and peers adopt it by choice or not at all. There is no authority above the mesh,
so the UI's hardest job is never lying about who can act on whom.

## Who uses it, and the real scene

One operator (Nat) with 20-30 AI coding agents running at once across 4 machines,
at a desk, usually at night, usually with a terminal already filling the screen.
The console is opened *beside* work, not instead of it. Sessions are seconds long
and frequent: "is anything stuck", "what did that agent just say", "send this to
all of them".

## Measured truth, 2026-09-17

- 4 federated nodes: m5 (29 panes, 22 agents), white/god (1), nat-white (1), black (0).
- 22 workspaces on m5 across 7 repos, 13 of them linked git worktrees.
- A pane carries `agent_status`: working · idle · blocked · done · unknown.
- `kind` is the detected agent (claude, codex, omp) or `"shell"` when herdr found
  none. 22 agents across 29 panes — shells are panes, not agents.
- Two machine addresses can be the same host under different Unix users
  (`white` and `nat-white` are both white.local).
- Peer health is `consecutive` failures since the last success, not a lifetime total.

## Constraints that bind the design

- **A read must not mutate.** Pane previews use `source: visible`; `recent` makes
  the operator's real terminal scroll and snap back (13.8s vs 0.1s, measured).
- **Two lists that must never merge**: who federates with *this* node (actionable)
  and what the mesh reports about itself (read-only, and stale while a link is down).
- **Destructive actions name what they change** before changing it.
- React 19 · Tailwind v4 (`@theme`) · TypeScript · Vite · Bun. No new dependencies
  beyond xterm.js, which already ships.
- Serves from the node itself on :6750; must stay fast on a laptop beside 30 agents.

## What exists today

Console (`/`), squads (`/teams`), admin (`/admin`: overview · map · members ·
invites · bans · audit), a join landing (`/join`), and a macOS menu-bar app.

## Assumptions (inferred from the brief, not interviewed)

- The existing dark terminal-adjacent world stays; this is an **additional** world
  the operator can switch to, not a replacement of the shipped one.
- "Same features" means feature parity with the current console, not with ARRA Office.
