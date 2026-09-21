// Placeholder entry point so the package links before the modules exist.
// The Integrate phase replaces this with the real boot sequence (server.ts
// lines 45–62 and 857–869): read peers.json, open the identity, load members
// and state, adopt legacy peers, port guard, serve, sync every SYNC_MS.

import FederationNode
import Foundation

let env = NodeEnv(root: FileManager.default.currentDirectoryPath)
print("[fed] herdr-federation-node scaffold — port \(env.port), socket \(env.socketPath)")
