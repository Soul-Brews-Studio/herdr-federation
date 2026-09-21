// JSONStringify.swift — `JSON.stringify`, for every byte this node writes.
//
// Foundation's JSONEncoder cannot write what the Bun node writes: it keeps an
// object's members in a Dictionary, so keys come out in a per-process random
// order (measured on a live /api/calls body: entry[0] was {params,ms,method,
// cli,ok,at} and entry[2] was {at,method,error,cli,ok,ms,params}), and its
// pretty printer puts a space before the colon. JSON.stringify writes members
// in insertion order — for a Swift struct that is declaration order, the order
// every Contract type is declared in — and `"key": value` with two-space
// indent. This file walks the same Encodable tree JSONEncoder would and
// serialises it the way JavaScriptCore does, number formatting included.
//
// What it cannot fix: a Swift Dictionary encodes its members in Dictionary
// order, and JSONDecoder hands Dictionaries back, so a `Record<string, …>`
// field (peerMembers, peerUi, relayed, meshMembers, peerPanes, a call's params)
// keeps a random member order. Everything else is byte for byte what Bun
// would have written for the same values.

import Foundation

public enum JSONStringify {
    /// `JSON.stringify(value)` — or `JSON.stringify(value, null, 2)` when `pretty`.
    public static func string<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let root = JSNode()
        try value.encode(to: JSEncoderImpl(node: root, codingPath: []))
        guard !root.isPending else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
        }
        var out = ""
        out.reserveCapacity(256)
        write(root, into: &out, pretty: pretty, depth: 0)
        return out
    }

    public static func data<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        Data(try string(value, pretty: pretty).utf8)
    }

    // MARK: - serialising the tree

    private static func write(_ node: JSNode, into out: inout String, pretty: Bool, depth: Int) {
        switch node.kind {
        case .pending:
            // `undefined` — dropped from an object by the caller; `null` in an array
            out += "null"
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let text):
            out += text
        case .string(let s):
            writeString(s, into: &out)
        case .object:
            let members = node.members.filter { !$0.node.isPending }   // `{a: undefined}` → `{}`
            if members.isEmpty { out += "{}"; return }
            if pretty {
                let inner = String(repeating: " ", count: (depth + 1) * 2)
                out += "{\n"
                for (i, member) in members.enumerated() {
                    if i > 0 { out += ",\n" }
                    out += inner
                    writeString(member.key, into: &out)
                    out += ": "
                    write(member.node, into: &out, pretty: true, depth: depth + 1)
                }
                out += "\n" + String(repeating: " ", count: depth * 2) + "}"
            } else {
                out += "{"
                for (i, member) in members.enumerated() {
                    if i > 0 { out += "," }
                    writeString(member.key, into: &out)
                    out += ":"
                    write(member.node, into: &out, pretty: false, depth: depth + 1)
                }
                out += "}"
            }
        case .array:
            if node.items.isEmpty { out += "[]"; return }
            if pretty {
                let inner = String(repeating: " ", count: (depth + 1) * 2)
                out += "[\n"
                for (i, item) in node.items.enumerated() {
                    if i > 0 { out += ",\n" }
                    out += inner
                    write(item, into: &out, pretty: true, depth: depth + 1)
                }
                out += "\n" + String(repeating: " ", count: depth * 2) + "]"
            } else {
                out += "["
                for (i, item) in node.items.enumerated() {
                    if i > 0 { out += "," }
                    write(item, into: &out, pretty: false, depth: depth + 1)
                }
                out += "]"
            }
        }
    }

    /// The QuoteJSONString of ECMA-262: `"` `\` and the seven C0 short escapes,
    /// every other control character as `\u00xx`, and NOTHING else escaped —
    /// no `\/`, no ` `, non-ASCII written as itself.
    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: - Number::toString

    /// ECMA-262 Number::toString(10), from the shortest round-trip digits
    /// (which is also what Swift's `description` produces): plain digits up to
    /// 1e21, `0.000001` down to 1e-6, exponent form beyond, `-0` printed as `0`.
    /// Non-finite values are what JSON.stringify makes of them: `null`.
    static func numberText(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == 0 { return "0" }
        let negative = d < 0
        let (digits, n) = decimalDigits(abs(d))
        let k = digits.count
        var body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let i = digits.index(digits.startIndex, offsetBy: n)
            body = String(digits[..<i]) + "." + String(digits[i...])
        } else if -6 < n && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let sign = e < 0 ? "-" : "+"
            let mantissa = k == 1 ? digits : String(digits.first!) + "." + String(digits.dropFirst())
            body = mantissa + "e" + sign + String(abs(e))
        }
        return negative ? "-" + body : body
    }

    /// The shortest digit string `s` and exponent `n` with value = 0.s × 10^n —
    /// the (s, n) pair of the spec — parsed out of Swift's shortest description.
    private static func decimalDigits(_ v: Double) -> (String, Int) {
        let text = v.description   // "123.456", "1e-07", "1.2345678901234568e+20", "100000.0"
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = intPart + fracPart
        var n = intPart.count + exponent
        while digits.hasPrefix("0") { digits.removeFirst(); n -= 1 }
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.isEmpty { return ("0", 1) }
        return (digits, n)
    }
}

// MARK: - the tree

private final class JSNode {
    enum Kind {
        case pending
        case null
        case bool(Bool)
        case number(String)
        case string(String)
        case object
        case array
    }
    var kind: Kind = .pending
    /// insertion order, as a JS object keeps it
    var members: [(key: String, node: JSNode)] = []
    var items: [JSNode] = []

    var isPending: Bool { if case .pending = kind { return true }; return false }

    func becomeObject() { if case .object = kind { return }; kind = .object }
    func becomeArray() { if case .array = kind { return }; kind = .array }

    /// `obj[key] = …` — a key already present keeps its position and takes the new value.
    func member(_ key: String) -> JSNode {
        becomeObject()
        if let i = members.firstIndex(where: { $0.key == key }) {
            let fresh = JSNode()
            members[i] = (key, fresh)
            return fresh
        }
        let fresh = JSNode()
        members.append((key, fresh))
        return fresh
    }

    func append() -> JSNode {
        becomeArray()
        let fresh = JSNode()
        items.append(fresh)
        return fresh
    }
}

private struct JSKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
}

// MARK: - the Encoder

private struct JSEncoderImpl: Encoder {
    let node: JSNode
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.becomeObject()
        return KeyedEncodingContainer(JSKeyedContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        node.becomeArray()
        return JSUnkeyedContainer(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        JSSingleValueContainer(node: node, codingPath: codingPath)
    }
}

private func store(_ value: Double, in node: JSNode) { node.kind = .number(JSONStringify.numberText(value)) }
private func store<I: BinaryInteger>(_ value: I, in node: JSNode) { node.kind = .number(String(value)) }

private struct JSKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: JSNode
    let codingPath: [CodingKey]

    private func child(_ key: Key) -> JSNode { node.member(key.stringValue) }

    mutating func encodeNil(forKey key: Key) throws { child(key).kind = .null }
    mutating func encode(_ value: Bool, forKey key: Key) throws { child(key).kind = .bool(value) }
    mutating func encode(_ value: String, forKey key: Key) throws { child(key).kind = .string(value) }
    mutating func encode(_ value: Double, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { store(Double(value), in: child(key)) }
    mutating func encode(_ value: Int, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { store(value, in: child(key)) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { store(value, in: child(key)) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try value.encode(to: JSEncoderImpl(node: child(key), codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let n = child(key)
        n.becomeObject()
        return KeyedEncodingContainer(JSKeyedContainer<NestedKey>(node: n, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let n = child(key)
        n.becomeArray()
        return JSUnkeyedContainer(node: n, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder {
        let key = JSKey("super")
        return JSEncoderImpl(node: node.member(key.stringValue), codingPath: codingPath + [key])
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        JSEncoderImpl(node: child(key), codingPath: codingPath + [key])
    }
}

private struct JSUnkeyedContainer: UnkeyedEncodingContainer {
    let node: JSNode
    let codingPath: [CodingKey]

    var count: Int { node.items.count }

    private func next() -> (JSNode, [CodingKey]) {
        let path = codingPath + [JSKey(intValue: node.items.count)!]
        return (node.append(), path)
    }

    mutating func encodeNil() throws { next().0.kind = .null }
    mutating func encode(_ value: Bool) throws { next().0.kind = .bool(value) }
    mutating func encode(_ value: String) throws { next().0.kind = .string(value) }
    mutating func encode(_ value: Double) throws { store(value, in: next().0) }
    mutating func encode(_ value: Float) throws { store(Double(value), in: next().0) }
    mutating func encode(_ value: Int) throws { store(value, in: next().0) }
    mutating func encode(_ value: Int8) throws { store(value, in: next().0) }
    mutating func encode(_ value: Int16) throws { store(value, in: next().0) }
    mutating func encode(_ value: Int32) throws { store(value, in: next().0) }
    mutating func encode(_ value: Int64) throws { store(value, in: next().0) }
    mutating func encode(_ value: UInt) throws { store(value, in: next().0) }
    mutating func encode(_ value: UInt8) throws { store(value, in: next().0) }
    mutating func encode(_ value: UInt16) throws { store(value, in: next().0) }
    mutating func encode(_ value: UInt32) throws { store(value, in: next().0) }
    mutating func encode(_ value: UInt64) throws { store(value, in: next().0) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let (n, path) = next()
        try value.encode(to: JSEncoderImpl(node: n, codingPath: path))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let (n, path) = next()
        n.becomeObject()
        return KeyedEncodingContainer(JSKeyedContainer<NestedKey>(node: n, codingPath: path))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let (n, path) = next()
        n.becomeArray()
        return JSUnkeyedContainer(node: n, codingPath: path)
    }

    mutating func superEncoder() -> Encoder {
        let (n, path) = next()
        return JSEncoderImpl(node: n, codingPath: path)
    }
}

private struct JSSingleValueContainer: SingleValueEncodingContainer {
    let node: JSNode
    let codingPath: [CodingKey]

    mutating func encodeNil() throws { node.kind = .null }
    mutating func encode(_ value: Bool) throws { node.kind = .bool(value) }
    mutating func encode(_ value: String) throws { node.kind = .string(value) }
    mutating func encode(_ value: Double) throws { store(value, in: node) }
    mutating func encode(_ value: Float) throws { store(Double(value), in: node) }
    mutating func encode(_ value: Int) throws { store(value, in: node) }
    mutating func encode(_ value: Int8) throws { store(value, in: node) }
    mutating func encode(_ value: Int16) throws { store(value, in: node) }
    mutating func encode(_ value: Int32) throws { store(value, in: node) }
    mutating func encode(_ value: Int64) throws { store(value, in: node) }
    mutating func encode(_ value: UInt) throws { store(value, in: node) }
    mutating func encode(_ value: UInt8) throws { store(value, in: node) }
    mutating func encode(_ value: UInt16) throws { store(value, in: node) }
    mutating func encode(_ value: UInt32) throws { store(value, in: node) }
    mutating func encode(_ value: UInt64) throws { store(value, in: node) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: JSEncoderImpl(node: node, codingPath: codingPath))
    }
}
