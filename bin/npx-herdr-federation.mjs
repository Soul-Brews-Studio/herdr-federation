#!/usr/bin/env node
/**
 * `npx herdr-federation` — the Node-compatible entry point.
 *
 * This is a LAUNCHER, not a Node port. The server is Bun-native (Bun.serve plus
 * its WebSocket upgrade, Bun.file, Bun.write), and Node has no built-in
 * WebSocket server, so running it under Node would mean maintaining a second
 * implementation of the part this project exists for — live pane streaming.
 * Instead this finds Bun and hands over.
 *
 * Bun is declared as an OPTIONAL dependency: npm installs it automatically on
 * supported platforms, and on anything else the install still succeeds and this
 * falls back to a Bun already on the machine. An optional dep that fails is a
 * warning; a required one that fails is a broken install.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const entry = join(here, "herdr-federation.ts");

/** Every place a Bun might be, nearest first. */
function findBun() {
  // 1. the optional dependency, resolved through this package's own tree
  try {
    const require = createRequire(import.meta.url);
    const pkg = require.resolve("bun/package.json");
    const bin = join(dirname(pkg), "bin", process.platform === "win32" ? "bun.exe" : "bun");
    if (existsSync(bin)) return bin;
  } catch {
    // not installed — normal on an unsupported platform
  }
  // 2. a Bun the user installed themselves
  const home = process.env.HOME ?? process.env.USERPROFILE ?? "";
  const candidates = [join(home, ".bun", "bin", "bun"), "/usr/local/bin/bun", "/opt/homebrew/bin/bun"];
  for (const c of candidates) if (c && existsSync(c)) return c;
  // 3. anything on PATH
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    if (!dir) continue;
    const c = join(dir, process.platform === "win32" ? "bun.exe" : "bun");
    if (existsSync(c)) return c;
  }
  return null;
}

const bun = findBun();
if (!bun) {
  console.error(
    [
      "herdr-federation needs Bun, and none was found.",
      "",
      "  The server uses Bun's HTTP + WebSocket server directly; Node has no",
      "  built-in WebSocket server, so there is nothing here for node to run.",
      "",
      "  Install Bun:  curl -fsSL https://bun.sh/install | bash",
      "  Then:         bunx herdr-federation",
      "",
      "  (npm should have installed Bun as an optional dependency — if it did not,",
      "   this platform is one Bun does not publish a binary for.)",
    ].join("\n"),
  );
  process.exit(127);
}

// stdio inherit so the node's own logs are the output, and the exit code is the
// server's: a supervisor watching `npx herdr-federation` must see the truth.
const child = spawn(bun, ["run", entry, ...process.argv.slice(2)], { stdio: "inherit" });
// Forward signals rather than dying first and orphaning the server.
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => child.kill(sig));
child.on("exit", (code, signal) => process.exit(signal ? 1 : (code ?? 0)));
