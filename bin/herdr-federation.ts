#!/usr/bin/env bun
/**
 * One-command entry point: `bunx herdr-federation`.
 *
 * The package directory is read-only in practice — bunx caches it, and an npm
 * install lands it under node_modules — so none of the four state files may live
 * beside the source the way they do in a checkout. This resolves a writable home
 * first, seeds a config there on first run, and only then hands off to the
 * server, which already takes every path from the environment.
 *
 * A checkout is unaffected: `bun run src/server.ts` still reads ./peers.json.
 */
import { existsSync, mkdirSync } from "node:fs";
import { hostname } from "node:os";
import { join } from "node:path";

const HOME =
  process.env.HERDR_FED_HOME ??
  join(process.env.XDG_STATE_HOME ?? join(process.env.HOME ?? ".", ".local", "state"), "herdr-federation");

mkdirSync(HOME, { recursive: true });

// Every one of these is read from the environment by src/server.ts, so pointing
// them at HOME is the whole of the relocation — no server-side branch on "am I
// installed or checked out".
process.env.FED_CONFIG ??= join(HOME, "peers.json");
process.env.FED_STATE ??= join(HOME, ".fed-state.json");
process.env.FED_IDENTITY ??= join(HOME, ".fed-identity.json");
process.env.FED_MEMBERS ??= join(HOME, ".fed-members.json");

// A first run with no config used to throw inside the server's top-level
// `Bun.file(CONFIG_PATH).json()`, which reads as a crash rather than as "you have
// not configured anything yet". Seed it instead: a node with its own name and no
// peers is a valid, useful federation of one — you join others with an invite.
if (!existsSync(process.env.FED_CONFIG)) {
  const node = process.env.FED_NODE ?? hostname().split(".")[0] ?? "node";
  await Bun.write(process.env.FED_CONFIG, JSON.stringify({ node, gossip: true, peers: [] }, null, 2) + "\n");
  console.log(`[fed] first run — wrote ${process.env.FED_CONFIG} as node "${node}"`);
  console.log(`[fed] join a federation: open the console and paste an invite link`);
}

// Default to loopback here as well as in the server: an installed binary is more
// likely to be run casually than a checkout, and this console is a write path
// into real terminals.
process.env.FED_HOST ??= "127.0.0.1";

await import("../src/server.ts");
