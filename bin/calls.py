#!/usr/bin/env python3
"""Every socket call this node made, as the command line you could have typed."""
import json, sys

for c in json.load(sys.stdin)["calls"]:
    print("%5dms  %s  %s" % (c["ms"], "ok " if c["ok"] else "ERR", c["cli"] or c["method"]))
