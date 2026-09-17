// One place that talks to a node, so a timeout or a shape change is fixed once.
//
// Everything is fire-and-forget with a main-thread completion: a menu rebuild
// must never block on a peer that has gone away, and on this fleet one direction
// of the link is routinely unreachable by design (m5 runs NetBird in userspace
// mode, which blackholes inbound to its overlay IP). A 4-second timeout is
// deliberate — long enough for a LAN round trip, short enough that a dead node
// does not freeze the menu behind it.

import Foundation

/// A message a human can act on. String cannot conform to Error, and the menu
/// only ever wants the sentence, so the wrapper carries nothing else.
struct ApiError: Error { let message: String }

enum Api {
    static let timeout: TimeInterval = 4

    private static func request(_ base: String, _ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Decode `T`, or hand back a message a human can act on. An `{error}` body
    /// wins over a decode failure, because the server's own words are always
    /// more useful than "dataCorrupted".
    static func fetch<T: Decodable>(_ type: T.Type, _ base: String, _ path: String,
                                    method: String = "GET", body: [String: Any]? = nil,
                                    done: @escaping (Result<T, ApiError>) -> Void) {
        guard let req = request(base, path, method: method, body: body) else {
            DispatchQueue.main.async { done(.failure(ApiError(message: "bad url"))) }
            return
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let finish: (Result<T, ApiError>) -> Void = { r in DispatchQueue.main.async { done(r) } }
            if let err { return finish(.failure(ApiError(message: Self.short(err)))) }
            guard let data else { return finish(.failure(ApiError(message: "empty reply"))) }
            if let e = try? JSONDecoder().decode(ErrorReply.self, from: data), let msg = e.error {
                return finish(.failure(ApiError(message: msg)))
            }
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                return finish(.failure(ApiError(message: "HTTP \(code)")))
            }
            do { finish(.success(try JSONDecoder().decode(T.self, from: data))) }
            catch { finish(.failure(ApiError(message: "unreadable reply"))) }
        }.resume()
    }

    /// POST/DELETE where only success matters.
    static func call(_ base: String, _ path: String, method: String, body: [String: Any]? = nil,
                     done: @escaping (String?) -> Void) {
        guard let req = request(base, path, method: method, body: body) else {
            DispatchQueue.main.async { done("bad url") }
            return
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let finish: (String?) -> Void = { r in DispatchQueue.main.async { done(r) } }
            if let err { return finish(Self.short(err)) }
            if let data, let e = try? JSONDecoder().decode(ErrorReply.self, from: data), let msg = e.error {
                return finish(msg)
            }
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { return finish("HTTP \(code)") }
            finish(nil)
        }.resume()
    }

    /// URLError's own descriptions are long and end in a period; a menu row has
    /// no space for "Could not connect to the server.".
    static func short(_ e: Error) -> String {
        switch (e as? URLError)?.code {
        case .some(.cannotConnectToHost), .some(.cannotFindHost): return "unreachable"
        case .some(.timedOut): return "timed out"
        case .some(.networkConnectionLost): return "connection lost"
        default: return e.localizedDescription.replacingOccurrences(of: ".", with: "")
        }
    }
}
