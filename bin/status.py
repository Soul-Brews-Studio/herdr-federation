#!/usr/bin/env python3
"""Print what this node sees: its own panes, its peers, and how to be joined."""
import json, sys

try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit("  node is not answering")

print("  node %s · %d panes · %d workspaces" % (s["node"], len(s["members"]), len(s["topology"]["workspaces"])))
for p in s["peers"]:
    seen = len(s["peerMembers"].get(p["name"], []))
    print("  peer %-12s %-11s %d panes  %s" % (p["name"], "ok" if p.get("ok") else "unreachable", seen, p["url"]))
print("  invite: %s" % (s["invite"]["url"] or s["invite"]["hint"]))
