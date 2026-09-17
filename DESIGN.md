# Design

Two worlds ship over the same data. Neither is a skin of the other.

| route | world | when |
|---|---|---|
| `/`, `/teams`, `/admin`, `/join` | **Console** — dark terminal-adjacent, Neo blue | the shipped default; reading panes and running admin |
| `/bridge` | **Engine room** — iron, brass, bone dials | watching a whole fleet at a glance and ringing orders |

## Console (incumbent)

Tokens in `web/src/index.css` under `@theme`. Ground `#0d0f14`, panel `#12151c`,
accent `#64b5f6`, with `ok` / `warn` / `bad` / `live` carrying status. Monospace
throughout, 13px base, tabular numerals. Status is a glyph (`●`/`○`) so it reads
without colour. This world is documented as built; it is not re-litigated here.

## Engine room (`/bridge`)

Tokens in `web/src/bridge.css`. Applied by adding `.bridge` to `<body>` on mount
and removing it on unmount, so the two worlds never fight over `body`.

**Why it exists.** A federation edge has two halves — what this node ordered and
what the far end answered — because enforcement is local-only and a kick binds
whichever node issued it. A grid of equal cards flattens that asymmetry. An
engine-order telegraph is the instrument that has always had two needles.

### Palette

Three ground values, one metal, two signals, and that is the whole system.

| role | token | value |
|---|---|---|
| hull | `--color-iron` / `iron-deep` / `plate` | `#14161a` · `#0c0e11` · `#1c2026` |
| seam | `--color-seam` | `#2a3039` |
| metal | `--color-brass` / `brass-lit` / `brass-dim` | `#b8934e` · `#e2bd76` · `#6d5730` |
| dial face | `--color-bone` / `bone-dim` | `#e8e2d4` · `#a39c8c` |
| **order** — what we rang | `--color-order` | `#d98e3a` |
| **answer** — what came back | `--color-answer` | `#6fae8e` |
| alarm | `--color-alarm` | `#d1554f` |

Order and answer mean exactly one thing each and are never used decoratively.
Dark is chosen from the scene, not the category: one operator, at night, this
panel open beside a terminal that already fills the screen. The bone dial face is
the only light on the page, which is why it is the thing the eye lands on.

### Type

- **Engraved plate labels**: Archivo Narrow 600, `0.14em` tracking, uppercase,
  brass, with a 1px black text-shadow so the label sits *in* the plate. Self-hosted
  from `web/public/fonts/` (OFL-1.1, Omnibus-Type) — three weights, `woff2`, ~42 KB.
- **Everything measured**: the system monospace stack, tabular numerals. Mono is
  used for data and identifiers only, never as a costume for "technical".

### Instruments

- **Telegraph** (`bridge/Telegraph.tsx`) — one per peer, 120px, never shrunk to an
  icon. Order needle in front (thick, ours); answer needle behind (thinner,
  theirs). The answer needle goes **dashed and 55% opacity when the link is
  failing**, because what the far side reports only arrived on the last successful
  pull. Mutual reads as the needles agreeing.
- **Watch board** (`bridge/WatchBoard.tsx`) — stations grouped by machine under
  sticky engraved headers. Lamps are drawn SVG with a bloom and a filament
  highlight, never a glyph: a `●` cannot carry a bloom and renders differently on
  every platform.
- **Shells are filtered out.** `kind === "shell"` is a pane herdr found no agent
  in; a watch board of empty stations reads as a fleet twice its real size.

### Surfaces most systems leave to the browser

Themed from the palette in `bridge.css`: selection, caret, scrollbar track and
thumb (square, brass on hover), focus ring (1px `brass-lit`, 2px offset),
underline offset. No radius on any instrument — bezels and detents are drawn.

### Motion

One authored moment: a 150ms colour transition on station and control hover.
Needles settle by CSS transition on their endpoints, damped, single axis, no
overshoot. Nothing else animates; a poll must not feel like an event.

## Reuse over reinvention

The bridge adds no data layer. It reads `useStatus()`, `api.admin()`,
`allMembers()`, `byMachine()` and `PaneView` exactly as the console does, and
`AdminState.edges` — computed once on the node — is what both worlds draw, so
the two can never disagree about who holds whom.
