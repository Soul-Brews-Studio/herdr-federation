#!/usr/bin/env python3
"""Render this node's membership: invites, members, bans, and how each happened.

Lives here rather than in the justfile because `{{` is just's interpolation and a
line at column 0 ends a recipe body — both of which a Python table trips over.
"""
import json, sys, urllib.parse, urllib.request

C = {"ok": "\033[32m", "bad": "\033[31m", "warn": "\033[33m", "dim": "\033[90m", "off": "\033[0m"}


def paint(text, tone):
    return f"{C[tone]}{text}{C['off']}"


def steps(entry, indent="  "):
    for s in entry.get("steps", []):
        mark = paint("✓", "ok") if s.get("ok") else paint("✕", "bad")
        print(f"{indent}{mark} {s['label']}")
        if s.get("detail"):
            print(f"{indent}   {paint(s['detail'], 'dim')}")
        if s.get("wire"):
            print(f"{indent}   {paint(s['wire'], 'dim')}")


def show_invite(data):
    inv = data.get("invite", data)
    print(inv.get("url") or paint("this node has no address for a link — set FED_ADVERTISE", "warn"))
    cap = inv["maxUses"] if inv["maxUses"] is not None else "∞"
    print(paint(f"  id {inv['id']} · {inv['status']} · expires {inv['expiresAt'] or 'never'} · uses {inv['uses']}/{cap}", "dim"))


def show_members(state):
    print(f"{state['node']} · key {state['identity']['fingerprint']}")
    if state.get("legacyAllowed"):
        print(paint("  FED_ALLOW_LEGACY is on — requests with no token are still accepted", "warn"))

    print(f"\nfederated with {state['node']} ({len(state['members'])})")
    for m in state["members"] or []:
        tag = paint(" unverified", "warn") if m.get("legacy") else paint(f" {m['fingerprint']}", "dim")
        print(f"  {m['node']}{tag} {paint(m.get('url') or '', 'dim')}")
    if not state["members"]:
        print(paint("  nobody — create an invite with `just invite`", "dim"))

    mesh = {k: v for k, v in (state.get("meshMembers") or {}).items() if v}
    if mesh:
        print("\nelsewhere in the mesh (read-only)")
        for peer, list_ in mesh.items():
            print(f"  {peer} federates with {paint(', '.join(m['node'] for m in list_), 'dim')}")

    if state.get("bans"):
        print("\nbanned")
        for b in state["bans"]:
            print(f"  {paint(b['node'], 'bad')} {paint(b.get('reason') or '', 'dim')}")

    live = [i for i in state.get("invites", []) if i["status"] == "active"]
    print(f"\n{len(live)} live invite(s)")
    for i in live:
        cap = i["maxUses"] if i["maxUses"] is not None else "∞"
        print(f"  {i.get('url') or i['id']} " + paint(f"uses {i['uses']}/{cap}", "dim"))


def show_audit(data):
    for e in data.get("audit", []):
        tone = "bad" if e["action"] in ("member.ban", "redeem.reject") else "warn" if "kick" in e["action"] else "ok"
        print(f"{paint(e['at'][11:19], 'dim')} {paint(e['action'], tone)} {e['node']} {paint(e.get('reason') or '', 'dim')}")
        steps(e)


def show_steps(data):
    if "error" in data:
        print(paint(data["error"], "bad"))
        return
    e = data["entry"]
    print(f"{e['action']} {e['node']}")
    steps(e)


def redeem(link, own):
    """Split an invite link into the node that issued it and the secret it carries."""
    u = urllib.parse.urlparse(link)
    token = u.path.split("/join/", 1)[-1]
    if not token or token == u.path:
        sys.exit(paint("that is not an invite link — expected http://host:6750/join/<secret>", "bad"))
    body = json.dumps({"from": f"{u.scheme}://{u.netloc}", "token": urllib.parse.unquote(token)}).encode()
    req = urllib.request.Request(f"{own}/api/peers/redeem", data=body, headers={"content-type": "application/json"})
    try:
        out = json.load(urllib.request.urlopen(req, timeout=15))
    except urllib.error.HTTPError as err:
        sys.exit(paint(json.load(err).get("error", str(err)), "bad"))
    print(f"joined {paint(out['joined']['node'], 'ok')} at {out['joined']['url']}")
    steps(out["entry"])


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "members"
    if mode == "redeem":
        redeem(sys.argv[2], sys.argv[3])
    else:
        payload = json.load(sys.stdin)
        if "error" in payload and mode != "steps":
            sys.exit(paint(payload["error"], "bad"))
        {"invite": show_invite, "members": show_members, "audit": show_audit, "steps": show_steps}[mode](payload)
