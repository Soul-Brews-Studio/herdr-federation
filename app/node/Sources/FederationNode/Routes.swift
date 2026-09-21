// Routes.swift — src/server.ts's `handle()`, one Hummingbird router.
//
// server.ts dispatches with ONE if-chain over `url.pathname` and `req.method`,
// and whatever it does not match falls through to the static console. That is
// not a trie: several routes match by prefix, several match ANY method, and a
// wrong-method call to an API path serves index.html rather than 405. So the
// router here registers one catch-all per method and re-runs the Bun chain in
// order. The trie is used for nothing else, and Hummingbird's own 404 is
// unreachable except for a method we did not name (ConsoleFallbackMiddleware
// catches that one).
//
// `BUN:` marks behaviour that looks wrong and is ported anyway.

import Foundation
import HTTPTypes
import Hummingbird

// MARK: - the router

/// `BasicRequestContext` with Bun's body cap instead of Hummingbird's.
///
/// Hummingbird defaults `maxUploadSize` to 2 MiB; `Bun.serve` defaults
/// `maxRequestBodySize` to 128 MB and server.ts never sets it. A peer pushing
/// `mine.suffix(100)` messages whose texts total more than 2 MiB — one pasted
/// pane dump through `POST /api/hey` with `to:"*"` is enough — got a 500 for
/// every retry here, so the link stayed red forever and those messages never
/// arrived, while the Bun node ingested the same body.
public struct FedRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public init(source: ApplicationRequestContextSource) { self.coreContext = .init(source: source) }
    /// `Bun.serve`'s default `maxRequestBodySize`
    public var maxUploadSize: Int { 128 * 1024 * 1024 }
}

public func buildRouter(_ rt: NodeRuntime) -> Router<FedRequestContext> {
    let router = Router(context: FedRequestContext.self)

    // Middleware must be added BEFORE the routes: Router.on() bakes the current
    // middleware stack into each responder as it is registered.
    router.add(middleware: AccessLogMiddleware<FedRequestContext>(log: rt.log))
    router.add(middleware: ConsoleFallbackMiddleware<FedRequestContext>(runtime: rt))

    // Every method Bun's fetch() would have seen. "" is the root node of the
    // trie (path "/"), "**" is everything with at least one component.
    let methods: [HTTPRequest.Method] = [.get, .head, .post, .put, .delete, .patch, .options, .trace, .connect]
    for method in methods {
        router.on("", method: method) { request, context in
            await respond(rt, request, context)
        }
        router.on("**", method: method) { request, context in
            await respond(rt, request, context)
        }
    }
    return router
}

/// server.ts's `done()` wrapper: one log line per response, at the one exit
/// point, because the handler has ~30 returns and a log at each would miss some.
public struct AccessLogMiddleware<Context: RequestContext>: RouterMiddleware {
    let log: AccessLog
    public init(log: AccessLog) { self.log = log }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let started = DispatchTime.now().uptimeNanoseconds
        let response = try await next(request, context)
        let ms = Int((Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000).rounded())
        log.record(
            method: request.method.rawValue,
            path: normalizePath(request.uri.path),
            status: response.status.code,
            ms: ms,
            contentType: response.headers[.contentType]
        )
        return response
    }
}

/// A method we never registered reaches Hummingbird's NotFoundResponder. In the
/// Bun node there is no such thing — every request falls through to the console
/// block — so put it back.
public struct ConsoleFallbackMiddleware<Context: RequestContext>: RouterMiddleware {
    let runtime: NodeRuntime
    public init(runtime: NodeRuntime) { self.runtime = runtime }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPError where error.status == .notFound {
            return console(runtime, normalizePath(request.uri.path))
        }
    }
}

// MARK: - handle()

private func respond(_ rt: NodeRuntime, _ request: Request, _ context: FedRequestContext) async -> Response {
    // `new URL(req.url).pathname` — the WHATWG parser has already removed dot
    // segments, including their percent-encoded spellings, before any of the
    // comparisons below run.
    let path = normalizePath(request.uri.path)
    let method = request.method
    let query = request.uri.queryParameters

    // ── live pane stream ────────────────────────────────────────────
    if path.hasPrefix("/ws/pane/") {
        guard let paneId = String(path.dropFirst("/ws/pane/".count)).removingPercentEncoding else {
            return internalError()  // decodeURIComponent() threw
        }
        if !validPane(paneId) { return textResponse("bad pane", 400) }
        // The upgrade itself is the WebSocket router's; anything that reaches
        // the HTTP router was not an upgrade.
        return textResponse("expected a websocket", 426)
    }

    // ── federation (peer to peer, no hub) ───────────────────────────
    if path == "/api/fed/state" {
        let who = await rt.member(request)
        if !who.ok { return unauthorized() }
        let peers = await rt.fed.peers().map { p -> PeerView in
            var v = PeerView(name: p.name, url: p.url)
            v.via = p.via
            return v
        }
        return jsonResponse(FedState(
            node: rt.config.node,
            identity: rt.ident.identity,
            messages: await rt.fed.messages(),
            members: rt.members,
            peers: peers,
            federated: await rt.fedMembers.members(),
            kicks: await rt.fedMembers.publishedKicks(),
            relayed: await rt.relayedFor(who.node)
        ))
    }

    if path == "/api/fed/ingest", method == .post {
        if !(await rt.member(request).ok) { return unauthorized() }
        guard let data = await bodyData(request, context), isJSON(data) else { return internalError() }
        // `fed.ingest(body.messages ?? [], body.from)` with NO validation:
        // federation.ts accepts each message on a truthy `id` alone. A strict
        // decode of the whole request dropped the entire batch — and the `from`
        // introduction with it, so the sender never landed in `known` — because
        // one message was missing one field. Both halves are read independently.
        let body = (try? JSONCoding.decode(LenientIngestRequest.self, from: data)) ?? LenientIngestRequest()
        let added = await rt.fed.ingest(body.messages, from: body.from)
        return jsonResponse(IngestResponse(added: added, node: rt.config.node))
    }

    if path == "/api/fed/hey", method == .post {
        if !(await rt.member(request).ok) { return unauthorized() }
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let to = body["to"]?.stringValue
        let text = body["text"]?.stringValue
        guard let to, !to.isEmpty, let text, !jsTrim(text).isEmpty else {
            return errorJSON("need to and text", 400)
        }
        do {
            let target = try await rt.deliverLocal(to, jsTrim(text))
            return jsonResponse(HeyResponse(delivered: "pane", to: target.handle, pane: target.pane))
        } catch {
            return errorJSON(errorText(error), 404)
        }
    }

    if path == "/api/fed/pane", method == .post {
        if !(await rt.member(request).ok) { return unauthorized() }
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let pane = body["pane"]?.stringValue
        guard let pane, !pane.isEmpty, validPane(pane) else { return errorJSON("bad pane id", 400) }
        do {
            let n = paneLines(body["lines"])
            // `visible` is not configurable: a `recent` read drives the pane's
            // own mouse-scroll, so a poll would scroll the operator's terminal.
            let read = try await rt.herdr.readPane(pane, source: "visible", lines: .number(Double(n)), format: nil)
            // `String(read?.text ?? "")`
            return jsonResponse(FedPaneResponse(node: rt.config.node, pane: pane, text: read.text ?? "", lines: n))
        } catch {
            return errorJSON(errorText(error), 502)
        }
    }

    if path == "/api/fed/pane-relay", method == .post {
        if !(await rt.member(request).ok) { return unauthorized() }
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let node = body["node"]?.stringValue
        let pane = body["pane"]?.stringValue
        guard let node, !node.isEmpty, let pane, !pane.isEmpty else {
            return errorJSON("need node and pane", 400)
        }
        guard await rt.fed.peer(node) != nil else {
            return errorJSON("\(node) is not a direct peer of \(rt.config.node) — no route", 404)
        }
        do {
            let reply = try await rt.fed.call(
                node, path: "/api/fed/pane", method: "POST",
                body: forwardBody(["pane": .string(pane)], passing: body, keys: ["lines"])
            )
            return try passthrough(reply, node: node)
        } catch {
            return errorJSON(errorText(error), 502)
        }
    }

    if path == "/api/fleet/hey", method == .post {
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let node = body["node"]?.stringValue
        let to = body["to"]?.stringValue
        let text = body["text"]?.stringValue
        guard let node, !node.isEmpty, let to, !to.isEmpty, let text, !jsTrim(text).isEmpty else {
            return errorJSON("need node, to and text", 400)
        }
        let trimmed = jsTrim(text)
        do {
            if node == rt.config.node {
                let target = try await rt.deliverLocal(to, trimmed)
                return jsonResponse(HeyResponse(delivered: "pane", to: target.handle, pane: target.pane))
            }
            let reply: PeerReply
            if await rt.fed.peer(node) != nil {
                reply = try await rt.fed.call(
                    node, path: "/api/fed/hey", method: "POST",
                    body: jsonBody(["to": .string(to), "text": .string(trimmed)])
                )
            } else if let relay = (await rt.fed.relayed())[node] {
                reply = try await rt.fed.call(
                    relay.via, path: "/api/fed/relay", method: "POST",
                    body: jsonBody(["node": .string(node), "to": .string(to), "text": .string(trimmed)])
                )
            } else {
                return errorJSON("no route to \(node) — not a peer, and no hub relays it", 404)
            }
            return try passthrough(reply, node: node)
        } catch {
            return errorJSON(errorText(error), 502)
        }
    }

    if path == "/api/fleet/pane", method == .post {
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let node = body["node"]?.stringValue
        let pane = body["pane"]?.stringValue
        guard let node, !node.isEmpty, let pane, !pane.isEmpty else {
            return errorJSON("need node and pane", 400)
        }
        do {
            if node == rt.config.node {
                guard validPane(pane) else { return errorJSON("bad pane id", 400) }
                let n = paneLines(body["lines"])
                let read = try await rt.herdr.readPane(pane, source: "visible", lines: .number(Double(n)), format: nil)
                return jsonResponse(FedPaneResponse(node: node, pane: pane, text: read.text ?? "", lines: n))
            }
            let reply: PeerReply
            if await rt.fed.peer(node) != nil {
                reply = try await rt.fed.call(
                    node, path: "/api/fed/pane", method: "POST",
                    body: forwardBody(["pane": .string(pane)], passing: body, keys: ["lines"])
                )
            } else if let relay = (await rt.fed.relayed())[node] {
                reply = try await rt.fed.call(
                    relay.via, path: "/api/fed/pane-relay", method: "POST",
                    body: forwardBody(["node": .string(node), "pane": .string(pane)], passing: body, keys: ["lines"])
                )
            } else {
                return errorJSON("no route to \(node) — not a peer, and no hub relays it", 404)
            }
            return try passthrough(reply, node: node)
        } catch {
            return errorJSON(errorText(error), 502)
        }
    }

    if path == "/api/fed/relay", method == .post {
        if !(await rt.member(request).ok) { return unauthorized() }
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let node = body["node"]?.stringValue
        let to = body["to"]?.stringValue
        let text = body["text"]?.stringValue
        guard let node, !node.isEmpty, let to, !to.isEmpty, let text, !jsTrim(text).isEmpty else {
            return errorJSON("need node, to and text", 400)
        }
        guard await rt.fed.peer(node) != nil else {
            return errorJSON("\(node) is not a direct peer of \(rt.config.node) — no route", 404)
        }
        do {
            let reply = try await rt.fed.call(
                node, path: "/api/fed/hey", method: "POST",
                body: jsonBody(["to": .string(to), "text": .string(jsTrim(text))])
            )
            return try passthrough(reply, node: node)
        } catch {
            return errorJSON(errorText(error), 502)
        }
    }

    // The one federation endpoint with no token check — the invite secret IS
    // the credential, and it is spent here.
    if path == "/api/fed/redeem", method == .post {
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let req = FedRedeemRequest(
            token: body["token"]?.stringValue ?? "",
            node: body["node"]?.stringValue ?? "",
            pubkey: body["pubkey"]?.stringValue ?? "",
            url: body["url"]?.stringValue,
            offerToken: body["offerToken"]?.stringValue ?? "",
            at: body["at"]?.stringValue ?? "",
            sig: body["sig"]?.stringValue ?? "",
            // members.ts:201 records the rejection under `req.node ?? "unknown"`:
            // an ABSENT key reads "unknown", an explicit "" stays "".
            nodePresent: body["node"] != nil
        )
        do {
            let (memberToken, _) = try await rt.fedMembers.redeem(req)
            await rt.fed.addPeer(name: req.node, url: req.url ?? "")
            await rt.saveConfig()
            let fed = rt.fed
            Task.detached { await fed.pullAll() }
            return jsonResponse(FedRedeemResponse(
                node: rt.config.node,
                pubkey: rt.ident.pubkey,
                url: rt.env.publicBase(),
                memberToken: memberToken
            ))
        } catch let error as RedeemError {
            return errorJSON("\(error.code.rawValue): \(error.message)", error.code == .banned ? 403 : 400)
        } catch {
            return errorJSON("error: \(errorText(error))", 400)
        }
    }

    if path == "/api/invite" { return jsonResponse(rt.invite()) }

    if path == "/api/calls" {
        let limit = jsNumber(query["limit"].map(String.init), default: Double(Const.callsDefaultLimit))
        return jsonResponse(CallsResponse(calls: jsSliceHead(await rt.herdr.calls(), limit)))
    }

    if path == "/api/peers/join", method == .post {
        // the pre-invite way in. Only reachable while legacy peers are tolerated.
        if !rt.env.allowLegacy { return errorJSON("this node only accepts invite links", 403) }
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let peerUrl = body["url"]?.stringValue
        guard let peerUrl, !jsTrim(peerUrl).isEmpty else { return errorJSON("no address", 400) }
        do {
            // BUN: the RAW url is joined, not the trimmed one that was tested.
            let joined = try await rt.fed.join(url: peerUrl)
            await rt.saveConfig()
            return jsonResponse(JoinResponse(joined: joined))
        } catch {
            return errorJSON(errorText(error), 400)
        }
    }

    if path == "/api/peers/leave", method == .post {
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let name = body["name"]?.stringValue
        guard let name, !name.isEmpty else { return errorJSON("no peer", 400) }
        await rt.fed.leave(name)
        await rt.saveConfig()
        return jsonResponse(LeaveResponse(left: name))
    }

    // ── membership: invites, members, bans, audit ───────────────────
    if path == "/api/invites", method == .post {
        let data = await bodyData(request, context)
        // `await req.json().catch(() => ({}))` — the catch fires only for an
        // UNPARSEABLE body. members.ts then destructures `{ hours = 24, uses =
        // null, note }` with no type check at all, so each key is read on its
        // own: decoding the body as one struct meant a single odd field (a
        // fractional `hours`, a numeric string, a non-string `note`) reverted
        // EVERY field to its default, and an invite asked to live 30 minutes
        // lived 24 hours.
        let body = data.flatMap { try? JSONCoding.decode(JSONValue.self, from: $0) }
        let hours = jsNullable(body?["hours"])
        guard inviteHoursAreRepresentable(hours) else { return internalError() }
        let req = CreateInviteRequest(
            hours: hours,
            uses: jsNullable(body?["uses"]),
            // `note` is stored and printed, never parsed — `String(x)` of whatever came
            note: body?["note"].map { $0 == .null ? "null" : jsString($0) }
        )
        return jsonResponse(CreateInviteResponse(invite: await rt.fedMembers.createInvite(req)))
    }
    if path == "/api/invites", method == .get {
        return jsonResponse(InvitesResponse(invites: await rt.fedMembers.invites()))
    }

    if path.hasPrefix("/api/invites/"), method == .delete {
        // BUN: the id is NOT percent-decoded here, unlike every other path segment.
        let id = String(path.dropFirst("/api/invites/".count))
        guard let revoked = await rt.fedMembers.revokeInvite(id) else {
            return errorJSON("no such invite", 404)
        }
        // BUN: revoking an invite rewrites peers.json, which holds no invites.
        await rt.saveConfig()
        return jsonResponse(CreateInviteResponse(invite: revoked))
    }

    // The only cross-origin-readable endpoint in the node: the joiner's own
    // console has to render it, and whoever holds the token already holds it.
    if path.hasPrefix("/api/invite-preview/") {
        guard let token = String(path.dropFirst("/api/invite-preview/".count)).removingPercentEncoding else {
            return internalError()
        }
        guard let found = await rt.fedMembers.preview(token: token) else {
            return errorJSON("that invite does not exist on this node", 404, cors: true)
        }
        return jsonResponse(InvitePreview(
            node: rt.config.node,
            fingerprint: rt.ident.identity.fingerprint,
            url: rt.env.publicBase(),
            expiresAt: found.invite.expiresAt,
            createdBy: found.invite.createdBy,
            note: found.invite.note,
            status: found.status,
            members: (await rt.fedMembers.members()).count
        ), cors: true)
    }

    if path == "/api/peers/redeem", method == .post {
        return await redeemAtPeer(rt, request, context)
    }

    if path == "/api/members" {
        return jsonResponse(MembersResponse(members: await rt.fedMembers.members(), bans: await rt.fedMembers.bans()))
    }
    if path == "/api/audit" {
        let limit = jsNumber(query["limit"].map(String.init), default: Double(Const.auditDefaultLimit))
        return jsonResponse(AuditResponse(audit: jsSliceHead(await rt.fedMembers.audit(), limit)))
    }

    if let act = memberAction(path), method == .post {
        guard let node = act.node.removingPercentEncoding else { return internalError() }
        let data = await bodyData(request, context)
        let reason = data
            .flatMap { try? JSONCoding.decode(JSONValue.self, from: $0) }
            .flatMap { $0["reason"]?.stringValue }
        if node == rt.config.node { return errorJSON("a node cannot kick itself", 400) }

        if act.verb == "unban" {
            guard let entry = await rt.fedMembers.unban(node: node) else {
                return errorJSON("\(node) is not banned here", 404)
            }
            // BUN: an unban does not touch peers.json — nothing was added to it.
            return jsonResponse(KickResponse(entry: entry))
        }
        let entry = act.verb == "ban"
            ? await rt.fedMembers.ban(node: node, reason: reason)
            : await rt.fedMembers.kick(node: node, reason: reason, adopted: nil)
        guard let entry else { return errorJSON("\(node) is not a member of this node", 404) }
        await rt.fed.leave(node)
        await rt.saveConfig()
        return jsonResponse(KickResponse(entry: entry))
    }

    if path == "/api/audit/adopt", method == .post {
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let node = body["node"]?.stringValue
        let from = body["from"]?.stringValue
        let reason = body["reason"]?.stringValue
        guard let node, !node.isEmpty, let from, !from.isEmpty else {
            return errorJSON("need the node and who kicked it", 400)
        }
        guard let entry = await rt.fedMembers.adoptKick(node: node, from: from, reason: reason) else {
            return errorJSON("\(node) is not a member of this node", 404)
        }
        await rt.fed.leave(node)
        await rt.saveConfig()
        return jsonResponse(KickResponse(entry: entry))
    }

    if path == "/api/admin" { return await adminState(rt) }
    if path == "/api/status" { return await statusState(rt) }

    if path.hasPrefix("/api/pane/") {
        guard let paneId = String(path.dropFirst("/api/pane/".count)).removingPercentEncoding else {
            return internalError()
        }
        guard validPane(paneId) else { return errorJSON("bad pane id", 400) }
        do {
            let source = query["source"].map(String.init) ?? Const.herdrDefaultSource
            let lines = jsNumber(query["lines"].map(String.init), default: Double(Const.paneStreamLines))
            // `Number(url.searchParams.get("lines") ?? 200)` — a non-numeric
            // value is NaN, and herdr.ts's `opts.lines ?? 200` is NULLISH, so NaN
            // survives it: the wire carries `"lines":null` and the cli line reads
            // `--lines NaN`. Collapsing NaN to the 200 default sent a request Bun
            // never sends.
            let read = try await rt.herdr.readPane(paneId, source: source, lines: .number(lines), format: nil)
            return jsonResponse(read)
        } catch {
            // BUN: `String(err)` — this one keeps the "Error: " prefix that every
            // other handler strips.
            return errorJSON(errorString(error), 502)
        }
    }

    // ── sending ─────────────────────────────────────────────────────
    if path == "/api/hey", method == .post {
        guard let body = await bodyJSON(request, context) else { return internalError() }
        let to = body["to"]?.stringValue
        let text = body["text"]?.stringValue
        guard let text, !jsTrim(text).isEmpty else { return errorJSON("empty message", 400) }
        do {
            if let to, !to.isEmpty, to != "*" {
                let target = try await rt.deliverLocal(to, jsTrim(text))
                return jsonResponse(HeyResponse(delivered: "pane", to: target.handle, pane: target.pane))
            }
            let msg = await rt.fed.post(from: rt.config.node, text: jsTrim(text))
            return jsonResponse(HeyResponse(delivered: "channel", id: msg.id))
        } catch {
            // BUN: prefixed, like /api/pane and unlike /api/fed/hey.
            return errorJSON(errorString(error), 500)
        }
    }

    if path == "/api/broadcast", method == .post {
        return await broadcast(rt, request, context)
    }

    // ── the console ─────────────────────────────────────────────────
    // BUN: this is also what a wrong-method API call gets — GET /api/fed/ingest
    // has no ".", so it is served index.html with a 200.
    return console(rt, path)
}

// MARK: - /api/peers/redeem

/// Our own console telling this node to go redeem an invite somewhere.
private func redeemAtPeer(_ rt: NodeRuntime, _ request: Request, _ context: FedRequestContext) async -> Response {
    guard let body = await bodyJSON(request, context) else { return internalError() }
    let from = body["from"]?.stringValue
    let token = body["token"]?.stringValue
    guard let from, !jsTrim(from).isEmpty, let token, !jsTrim(token).isEmpty else {
        return errorJSON("need both an address and an invite token", 400)
    }
    let target = trimTrailingSlashes(jsTrim(from))
    let invite = jsTrim(token)
    let offerToken = secret()
    let at = Stamp.iso()
    let payload = FedRedeemRequest(
        token: invite,
        node: rt.config.node,
        pubkey: rt.ident.pubkey,
        url: rt.env.publicBase(),
        offerToken: offerToken,
        at: at,
        sig: rt.ident.sign(redeemMessage(token: invite, node: rt.config.node, at: at))
    )
    var steps: [AuditStep] = [
        // BUN: six characters of the invite secret go into the audit log here.
        AuditStep(n: 1, label: "read the invite link", ok: true, detail: "\(target) · token \(String(invite.prefix(6)))…"),
        AuditStep(n: 2, label: "mint the token we will issue them", ok: true, detail: "one round trip authenticates both directions"),
        AuditStep(n: 3, label: "sign the request with this node's key", ok: true, detail: "ed25519 · \(rt.ident.identity.fingerprint)"),
    ]
    let wire = "POST \(target)/api/fed/redeem"
    do {
        // No x-fed-token: there is no relationship yet, the invite is the proof.
        let sent = try JSONCoding.encode(payload)
        let reply = try await postJSON("\(target)/api/fed/redeem", body: sent, timeoutMs: Const.redeemTimeoutMs)
        let parsed = try peerJSON(reply)
        if !reply.ok || isTruthy(parsed["error"]) {
            let e = parsed["error"]
            throw NodeError((e != nil && e! != .null) ? jsString(e!) : "\(reply.status)")
        }
        let out = try JSONCoding.decode(FedRedeemResponse.self, from: reply.body)
        steps.append(AuditStep(
            n: 4, label: "they verified it and issued us a token", wire: wire, ok: true,
            detail: "\(out.node) · \(String(out.pubkey.prefix(16)))"
        ))
        let url = out.url ?? target
        let entry = await rt.fedMembers.adopt(
            AdoptedPeer(node: out.node, pubkey: out.pubkey, url: url, ourToken: offerToken, theirToken: out.memberToken),
            steps: steps + [AuditStep(
                n: 5, label: "store the membership and start syncing", ok: true,
                detail: "\(out.node) is now a member of \(rt.config.node)"
            )],
            summary: "we joined them at \(target) · their invite \(String(invite.prefix(8)))…"
        )
        await rt.fed.addPeer(name: out.node, url: url)
        await rt.saveConfig()
        let fed = rt.fed
        Task.detached { await fed.pullAll() }
        return jsonResponse(RedeemResponse(joined: JoinedNode(node: out.node, url: url), entry: entry))
    } catch {
        let detail = errorText(error)
        steps.append(AuditStep(n: 4, label: "present the invite", wire: wire, ok: false, detail: detail))
        _ = await rt.fedMembers.record(.redeemReject, node: target, steps: steps, reason: detail, summary: "at \(target)")
        return errorJSON(detail, 400)
    }
}

// MARK: - /api/broadcast

private func broadcast(_ rt: NodeRuntime, _ request: Request, _ context: FedRequestContext) async -> Response {
    guard let body = await bodyJSON(request, context) else { return internalError() }
    let text = body["text"]?.stringValue
    guard let text, !jsTrim(text).isEmpty else { return errorJSON("empty message", 400) }
    let targets = body["targets"]?.arrayValue ?? []
    guard !targets.isEmpty else { return errorJSON("no targets", 400) }
    let trimmed = jsTrim(text)
    let us = rt.config.node

    let results: [BroadcastResult] = await withTaskGroup(of: (Int, BroadcastResult).self) { group in
        for (i, t) in targets.enumerated() {
            group.addTask {
                let handle = t["handle"]?.stringValue
                let node = t["node"]?.stringValue
                // `t.pane ?? t.handle` — nullish, so an empty pane string wins.
                let to = t["pane"].flatMap { $0 == .null ? nil : $0.stringValue } ?? handle
                do {
                    if let node, !node.isEmpty, node != us {
                        // Routed by NODE, never by the `base` a client sent.
                        let reply: PeerReply
                        if await rt.fed.peer(node) != nil {
                            reply = try await rt.fed.call(
                                node, path: "/api/fed/hey", method: "POST",
                                body: jsonBody(optional: ["to": to.map(JSONValue.string), "text": .string(trimmed)])
                            )
                        } else if let relay = (await rt.fed.relayed())[node] {
                            reply = try await rt.fed.call(
                                relay.via, path: "/api/fed/relay", method: "POST",
                                body: jsonBody(optional: [
                                    "node": .string(node), "to": to.map(JSONValue.string), "text": .string(trimmed),
                                ])
                            )
                        } else {
                            throw NodeError("no route to \(node) — not a peer, and no hub relays it")
                        }
                        let out = try peerJSON(reply)
                        if !reply.ok || isTruthy(out["error"]) {
                            throw NodeError(peerErrorMessage(out, reply, node: node))
                        }
                        return (i, BroadcastResult(handle: handle, node: node, ok: true, via: "peer"))
                    }
                    try await rt.deliverLocal(to ?? "undefined", trimmed)
                    return (i, BroadcastResult(handle: handle, node: node ?? us, ok: true, via: "local"))
                } catch {
                    return (i, BroadcastResult(handle: handle, node: node, ok: false, error: errorText(error)))
                }
            }
        }
        var collected: [(Int, BroadcastResult)] = []
        for await item in group { collected.append(item) }
        return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
    return jsonResponse(BroadcastResponse(results: results))
}

// MARK: - /api/admin and /api/status

private func adminState(_ rt: NodeRuntime) async -> Response {
    let records = await rt.fedMembers.members()
    let mine = Set(records.map { $0.node })

    // One row per node: a peer that kicked the same node three times is still
    // one decision to make.
    var latest: [String: AuditEntry] = [:]
    // `Object.entries(fed.peerKicks)` — insertion order, so `adoptable` below
    // comes out in the order peers first answered a pull, as it does on Bun.
    var latestOrder: [String] = []
    for (from, entries) in await rt.fed.peerKicksList() {
        for entry in entries {
            guard entry.action == .memberKick, mine.contains(entry.node), entry.node != rt.config.node else { continue }
            if let seen = latest[entry.node] {
                guard let a = Stamp.parse(entry.at), let b = Stamp.parse(seen.at), a > b else { continue }
            }
            var copy = entry
            copy.from = from
            if latest[entry.node] == nil { latestOrder.append(entry.node) }
            latest[entry.node] = copy
        }
    }

    let peers = await rt.fed.peers()
    let health = await rt.fed.health()
    let rosters = await rt.fed.peerMembers()
    let federated = await rt.fed.peerFederated()
    let edges = peers.map { p -> FedEdge in
        let h = health[p.name] ?? PeerHealth()
        // `stale` is the important half: a cached membership keeps answering
        // while every pull returns 401.
        let stale = h.consecutive > 0
        let ours = mine.contains(p.name)
        let theirs = (federated[p.name] ?? []).contains { $0.node == rt.config.node }
        return FedEdge(
            peer: p.name, url: p.url, ours: ours, theirs: theirs,
            mutual: ours && theirs && !stale, stale: stale,
            // agents, not panes — the map's list filters the same way
            panes: (rosters[p.name] ?? []).filter { !$0.kind.isEmpty && $0.kind != "shell" }.count,
            ok: h.ok, consecutive: h.consecutive,
            lastSeen: h.lastSeen, lastOkAt: h.lastOkAt, lastError: h.lastError
        )
    }
    let heard = (await rt.fed.knownList()).filter { k in !peers.contains { $0.name == k.node } }

    return jsonResponse(AdminState(
        node: rt.config.node,
        identity: rt.ident.identity,
        legacyAllowed: rt.env.allowLegacy,
        members: records,
        invites: await rt.fedMembers.invites(),
        bans: await rt.fedMembers.bans(),
        audit: Array((await rt.fedMembers.audit()).prefix(Const.adminAuditLimit)),
        meshMembers: federated,
        adoptable: latestOrder.compactMap { latest[$0] },
        edges: edges,
        panes: rt.members,
        peerPanes: await rt.allPeerMembers(),
        heard: heard,
        relayed: (await rt.fed.relayed()).mapValues { $0.asRelayedPeer }
    ))
}

/// `...fed.health[p.name]` spreads EVERY health field onto the row, including
/// `lastOkUrl`, which `PeerView` in wire.ts does not declare. The Bun node
/// sends it; so does this one.
private struct StatusPeerRow: Encodable {
    var name: String
    var url: String
    var via: String?
    // `#mark` seeds a record with `{ consecutive: 0 }` and spreads the rest over
    // it, so `consecutive` is first and `ok` second. The success branch writes
    // `lastError: undefined, lastErrorAt: undefined` BEFORE `lastOkUrl`, so a
    // healthy link drops those two keys (JSON.stringify omits undefined) while
    // still holding their slots — and the first failure fills the slots where
    // they already sit, ahead of lastOkUrl. Measured by the conformance harness,
    // which is why lastOkUrl is declared last and not beside lastOkAt.
    // NOT reproduced: a link whose FIRST mark was a failure never ran the
    // success branch, so Bun seeds it `consecutive, ok, lastError, lastErrorAt`
    // and appends `lastSeen, lastOkAt, lastOkUrl` on its first success — one
    // struct cannot carry both orders. Order only; no parser sees a difference.
    var consecutive: Int?
    var ok: Bool?
    var lastSeen: String?
    var lastOkAt: String?
    var lastError: String?
    var lastErrorAt: String?
    var lastOkUrl: String?
}

/// `StatusResponse`, with the peers array widened to what the spread actually
/// produces. Field for field and in order otherwise.
private struct StatusBody: Encodable {
    var node: String
    var identity: Identity
    var legacyAllowed: Bool
    @NullIfNil var session: String?
    var invite: Invite
    var topology: Topology
    var gossip: Bool
    var stats: Stats
    var members: [Member]
    var messages: [FedMessage]
    var peers: [StatusPeerRow]
    var peerMembers: [String: [Member]]
    var peerUi: [String: String]
    var known: [KnownNode]
    var relayed: [String: RelayedPeer]?
}

private func statusState(_ rt: NodeRuntime) async -> Response {
    let health = await rt.fed.health()
    // direct links first, then what hubs let us see
    var rows = await rt.fed.peers().map { p -> StatusPeerRow in
        var row = StatusPeerRow(name: p.name, url: p.url)
        row.via = p.via
        if let h = health[p.name] {
            row.ok = h.ok
            row.lastError = h.lastError
            row.lastErrorAt = h.lastErrorAt
            row.lastSeen = h.lastSeen
            row.lastOkAt = h.lastOkAt
            row.consecutive = h.consecutive
            row.lastOkUrl = h.lastOkUrl
        }
        return row
    }
    for view in await rt.relayedViews() {
        var row = StatusPeerRow(name: view.name, url: view.url)
        row.via = view.via
        row.ok = view.ok
        row.lastOkAt = view.lastOkAt
        row.consecutive = view.consecutive
        rows.append(row)
    }

    let messages = await rt.fed.messages()
    return jsonResponse(StatusBody(
        node: rt.config.node,
        identity: rt.ident.identity,
        legacyAllowed: rt.env.allowLegacy,
        session: rt.env.herdrSession,
        invite: rt.invite(),
        topology: rt.topology,
        gossip: rt.config.gossip == true,
        stats: await rt.fed.stats(),
        members: rt.members,
        messages: Array(messages.suffix(Const.statusMessages).reversed()),
        peers: rows,
        peerMembers: await rt.allPeerMembers(),
        peerUi: await rt.allPeerUi(),
        known: await rt.fed.knownList(),
        relayed: (await rt.fed.relayed()).mapValues { $0.asRelayedPeer }
    ))
}

// MARK: - the static console

/// The last block of handle(): serve web/dist, or say which build is missing.
private func console(_ rt: NodeRuntime, _ path: String) -> Response {
    let fm = FileManager.default
    if fm.fileExists(atPath: rt.env.dist) {
        let rel = (path == "/" || !path.contains(".")) ? "index.html" : String(path.dropFirst())
        if !rel.hasPrefix("../"), !rel.contains("/../"), !rel.hasPrefix("/") {
            let file = rt.env.dist + "/" + rel
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue,
               let data = fm.contents(atPath: file) {
                return response(200, contentType(forPath: rel), ByteBuffer(bytes: data))
            }
        }
    }
    // The API is fully up at this point — only the static console is missing,
    // and the fix depends on how this node was started.
    let installed = !rt.env.dist.hasPrefix(fm.currentDirectoryPath)
    let lines = [
        "the console is not built — the API on this port is working.",
        "",
        installed
            ? "  this node is running from an installed package, so build output was not shipped with it:"
            : "  from a checkout:",
        installed
            ? "    bunx herdr-federation            (npm release ships the built console)"
            : "    cd web && bun install && bun run build",
        "",
        "  looked in: \(rt.env.dist)",
    ]
    // BUN: this header is exactly "text/plain" — no charset, unlike every other
    // text body in the node, which Bun stamps "text/plain;charset=utf-8".
    return textResponse(lines.joined(separator: "\n"), 503, contentType: "text/plain")
}

/// What Bun guesses from the extension when it answers with a `Bun.file`.
private func contentType(forPath rel: String) -> String {
    let ext = (rel as NSString).pathExtension.lowercased()
    switch ext {
    case "html", "htm": return "text/html;charset=utf-8"
    case "js", "mjs": return "text/javascript;charset=utf-8"
    case "css": return "text/css;charset=utf-8"
    case "json", "map": return "application/json;charset=utf-8"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "ico": return "image/vnd.microsoft.icon"
    case "woff2": return "font/woff2"
    case "woff": return "font/woff"
    case "ttf": return "font/ttf"
    case "txt": return "text/plain;charset=utf-8"
    case "wasm": return "application/wasm"
    default: return "application/octet-stream"
    }
}

// MARK: - responses

private let kJSONType = "application/json;charset=utf-8"
private let kTextType = "text/plain;charset=utf-8"

private func response(_ status: Int, _ contentType: String, _ buffer: ByteBuffer, cors: Bool = false) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = contentType
    if cors, let name = HTTPField.Name("access-control-allow-origin") { headers[name] = "*" }
    return Response(status: .init(code: status), headers: headers, body: .init(byteBuffer: buffer))
}

private func jsonResponse(_ value: some Encodable, _ status: Int = 200, cors: Bool = false) -> Response {
    guard let data = try? JSONCoding.encode(value) else { return internalError() }
    return response(status, kJSONType, ByteBuffer(bytes: data), cors: cors)
}

/// A peer's body handed back untouched. Bun re-stringifies the parsed object;
/// forwarding the bytes keeps the key order that would have survived anyway.
private func rawJSON(_ data: Data, _ status: Int = 200) -> Response {
    response(status, kJSONType, ByteBuffer(bytes: data))
}

private func textResponse(_ body: String, _ status: Int = 200, contentType: String = kTextType) -> Response {
    response(status, contentType, ByteBuffer(string: body))
}

private func errorJSON(_ message: String, _ status: Int, cors: Bool = false) -> Response {
    jsonResponse(ErrorResponse(message), status, cors: cors)
}

private func errorJSON(_ value: JSONValue, _ status: Int) -> Response {
    jsonResponse(["error": value], status)
}

private func unauthorized() -> Response {
    errorJSON("not a member of this node — redeem an invite", 401)
}

/// What Bun answers when `await req.json()` rejects inside the handler.
private func internalError() -> Response {
    textResponse("Internal Server Error", 500)
}

// MARK: - peer replies

/// `if (!res.ok || out.error) return json({error: out.error ?? ...}, res.ok ? 502 : res.status); return json(out)`
private func passthrough(_ reply: PeerReply, node: String) throws -> Response {
    let out = try peerJSON(reply)
    if !reply.ok || isTruthy(out["error"]) {
        let e = out["error"]
        // `??` is nullish: a literal `false` or `0` error is forwarded as-is.
        let value: JSONValue = (e != nil && e! != .null) ? e! : .string("\(node) answered \(reply.status)")
        return errorJSON(value, reply.ok ? 502 : reply.status)
    }
    return rawJSON(reply.body)
}

/// `await res.json()` on a peer's reply — a body that is not JSON is
/// `SyntaxError: Failed to parse JSON`, which every caller's catch then prints whole.
private func peerJSON(_ reply: PeerReply) throws -> JSONValue {
    guard let out = try? JSONCoding.decode(JSONValue.self, from: reply.body) else {
        throw FederationError("Failed to parse JSON", name: "SyntaxError")
    }
    return out
}

private func peerErrorMessage(_ out: JSONValue, _ reply: PeerReply, node: String) -> String {
    if let e = out["error"], e != .null { return jsString(e) }
    return "\(node) answered \(reply.status)"
}

private func postJSON(_ url: String, body: Data, timeoutMs: Int) async throws -> PeerReply {
    guard let parsed = URL(string: url) else { throw NodeError("Failed to parse URL from \(url)") }
    var request = URLRequest(url: parsed, timeoutInterval: Double(timeoutMs) / 1000)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = body
    do {
        // a wall-clock deadline, not URLRequest's idle timer — see fetchWithDeadline
        let (data, response) = try await fetchWithDeadline(request, timeoutMs: timeoutMs)
        return PeerReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    } catch {
        // Bun's fetch wording, never URLSession's — see bunFetchError
        throw bunFetchError(error)
    }
}

// MARK: - request bodies

private func bodyData(_ request: Request, _ context: some RequestContext) async -> Data? {
    guard let buffer = try? await request.body.collect(upTo: context.maxUploadSize) else { return nil }
    return Data(buffer.readableBytesView)
}

/// `await req.json()` — nil means it threw, which Bun answers 500 for.
private func bodyJSON(_ request: Request, _ context: some RequestContext) async -> JSONValue? {
    guard let data = await bodyData(request, context) else { return nil }
    return try? JSONCoding.decode(JSONValue.self, from: data)
}

private func isJSON(_ data: Data) -> Bool {
    (try? JSONCoding.decode(JSONValue.self, from: data)) != nil
}

private func jsonBody(_ object: [String: JSONValue]) -> Data {
    (try? JSONCoding.encode(object)) ?? Data("{}".utf8)
}

/// `JSON.stringify({...})` drops keys whose value is `undefined`.
private func jsonBody(optional object: [String: JSONValue?]) -> Data {
    jsonBody(object.compactMapValues { $0 })
}

/// Forward a key only if the caller sent it — `JSON.stringify({pane, lines})`
/// omits `lines` when it was absent and keeps it when it was an explicit null.
private func forwardBody(_ base: [String: JSONValue], passing body: JSONValue, keys: [String]) -> Data {
    var out = base
    for key in keys { if let v = body[key] { out[key] = v } }
    return jsonBody(out)
}

// MARK: - path and pane helpers

/// The dot-segment removal `new URL()` has already done by the time server.ts
/// reads `url.pathname`, percent-encoded spellings included.
private func normalizePath(_ path: String) -> String {
    guard path.hasPrefix("/"), path.contains(".") || path.contains("%") else { return path }
    var out: [Substring] = []
    var trailing = false
    for (i, segment) in path.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
        if i == 0 { continue }  // the empty piece before the leading slash
        switch segment.lowercased() {
        case ".", "%2e":
            trailing = true
        case "..", ".%2e", "%2e.", "%2e%2e":
            if !out.isEmpty { out.removeLast() }
            trailing = true
        default:
            out.append(segment)
            trailing = false
        }
    }
    var result = "/" + out.joined(separator: "/")
    if trailing, !result.hasSuffix("/") { result += "/" }
    return result
}

/// `/^[A-Za-z0-9_:-]+$/` — panes are addressed as `wD:p4`.
private func validPane(_ id: String) -> Bool {
    guard !id.isEmpty else { return false }
    for c in id.unicodeScalars {
        let ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
            || c == "_" || c == ":" || c == "-"
        if !ok { return false }
    }
    return true
}

/// `/^\/api\/members\/([^/]+)\/(kick|ban|unban)$/`
private func memberAction(_ path: String) -> (node: String, verb: String)? {
    guard path.hasPrefix("/api/members/") else { return nil }
    let parts = path.dropFirst("/api/members/".count).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty else { return nil }
    let verb = String(parts[1])
    guard verb == "kick" || verb == "ban" || verb == "unban" else { return nil }
    return (String(parts[0]), verb)
}

private func trimTrailingSlashes(_ s: String) -> String {
    var out = Substring(s)
    while out.hasSuffix("/") { out = out.dropLast() }
    return String(out)
}

// MARK: - JavaScript semantics

/// `String.prototype.trim()`
private func jsTrim(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// `String(err)` — the prefixed form. `errorText()` in Contract.swift strips it.
private func errorString(_ error: Error) -> String {
    (error as CustomStringConvertible).description
}

private func isTruthy(_ value: JSONValue?) -> Bool {
    guard let value else { return false }
    switch value {
    case .null: return false
    case .bool(let b): return b
    case .number(let n): return n != 0 && !n.isNaN
    case .string(let s): return !s.isEmpty
    case .array, .object: return true
    }
}

/// `String(value)` for the few places a non-string lands in a message.
private func jsString(_ value: JSONValue) -> String {
    switch value {
    case .string(let s): return s
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    case .array(let a): return a.map(jsString).joined(separator: ",")
    case .object: return "[object Object]"
    }
}

/// `Number(x)`, enough of it for the values this node reads.
private func jsNumber(_ value: JSONValue?) -> Double {
    guard let value else { return .nan }  // undefined
    switch value {
    case .null: return 0
    case .bool(let b): return b ? 1 : 0
    case .number(let n): return n
    case .string(let s): return jsNumber(string: s)
    case .array(let a):
        if a.isEmpty { return 0 }
        return a.count == 1 ? jsNumber(a[0]) : .nan
    case .object: return .nan
    }
}

private func jsNumber(string: String) -> Double {
    let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return 0 }
    return Double(t) ?? .nan
}

/// `Number(searchParams.get(k) ?? fallback)` — an absent key uses the fallback,
/// a present but unparseable one is NaN.
private func jsNumber(_ raw: String?, default fallback: Double) -> Double {
    guard let raw else { return fallback }
    return jsNumber(string: raw)
}

/// `POST /api/fed/ingest`'s body, read the way federation.ts reads it: the
/// messages are decoded one at a time and the ones that will not parse are
/// skipped, and `from` is decoded independently so a bad `messages` array cannot
/// also cost the peer introduction.
private struct LenientIngestRequest: Decodable {
    var messages: [FedMessage] = []
    var from: IngestFrom?
    enum CodingKeys: String, CodingKey { case messages, from }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = c.decodeLenientArrayIfPresent(FedMessage.self, forKey: .messages) ?? []
        from = (try? c.decodeIfPresent(IngestFrom.self, forKey: .from)) ?? nil
    }
}

/// `{ hours = 24, uses = null }` destructured off a loose JSON body: an ABSENT
/// key takes the default, an explicit null stays null, and anything else goes
/// through JS numeric coercion — which is what `hours * 3600_000` applies.
private func jsNullable(_ value: JSONValue?) -> Nullable<Double> {
    guard let value else { return .absent }
    if value == .null { return .null }
    return .value(jsNumber(value))
}

/// `new Date(Date.now() + hours * 3600_000).toISOString()` throws RangeError on a
/// non-finite or out-of-range instant, and server.ts catches nothing around
/// `createInvite`, so Bun answers 500. `{"hours":"abc"}` is the reachable case.
private func inviteHoursAreRepresentable(_ hours: Nullable<Double>) -> Bool {
    guard case .value(let h) = hours else { return true }
    let ms = Double(Stamp.nowMs()) + h * 3_600_000
    return ms.isFinite && abs(ms) <= 8.64e15
}

/// `Math.min(Math.max(Number(lines) || 40, 1), 400)`. BUN: `|| 40` means 0,
/// null, "" and an unparseable string all become 40 before the clamp.
private func paneLines(_ value: JSONValue?) -> Int {
    let n = jsNumber(value)
    let base = (n.isNaN || n == 0) ? Double(Const.paneLinesDefault) : n
    return Int(min(max(base, Double(Const.paneLinesMin)), Double(Const.paneLinesMax)))
}

/// `array.slice(0, end)` with ToIntegerOrInfinity — NaN is 0, so `?limit=abc`
/// answers with an empty list.
private func jsSliceHead<T>(_ array: [T], _ end: Double) -> [T] {
    if end.isNaN { return [] }
    let length = array.count
    let truncated = end < 0 ? end.rounded(.up) : end.rounded(.down)
    let final: Int
    if truncated < 0 {
        final = truncated <= -Double(length) ? 0 : max(length + Int(truncated), 0)
    } else {
        final = truncated >= Double(length) ? length : min(Int(truncated), length)
    }
    return Array(array.prefix(final))
}
