import Foundation

/// A lossless JSON tree.
///
/// The sync protocol asks clients to "preserve unknown JSON fields when
/// practical", which rules out decoding straight into fixed structs. Everything
/// that crosses the wire is held as one of these so a newer server field
/// survives an older client rewriting the record.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int(d)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unrepresentable JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Canonical serialisation

/// Deterministic JSON bytes.
///
/// Content is addressed by SHA-256, so the same logical record has to produce
/// byte-identical output every time or the server sees a "new" blob on every
/// save. Foundation's `.sortedKeys` gets most of the way there, but writing the
/// serialiser outright also pins number formatting and string escaping, which
/// `JSONSerialization` does not promise to keep stable.
public enum CanonicalJSON {

    public static func encode(_ value: JSONValue) -> Data {
        var out = String()
        out.reserveCapacity(512)
        write(value, into: &out)
        return Data(out.utf8)
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            // Swift's default description is the shortest round-trippable form.
            if d.isFinite {
                out += d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
            } else {
                out += "null"   // JSON has no NaN/Infinity
            }
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let dict):
            out += "{"
            // Sorted by Unicode scalar order for a stable, portable ordering.
            for (i, key) in dict.keys.sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }).enumerated() {
                if i > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(dict[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Timestamps

public enum SyncTime {
    /// The wire format used throughout the protocol: RFC 3339, milliseconds, UTC.
    public static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func string(_ date: Date) -> String { formatter.string(from: date) }

    public static func date(_ string: String) -> Date? {
        if let d = formatter.date(from: string) { return d }
        // Tolerate timestamps without fractional seconds.
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }
}
