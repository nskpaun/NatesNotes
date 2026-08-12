import Foundation

/// UUIDv7 — 48-bit big-endian Unix milliseconds, then randomness, with the
/// version and variant bits pinned. The protocol asks for v7 specifically for
/// installation IDs, node IDs, mutation IDs and idempotency keys; the ordering
/// property is what makes them pleasant as database keys on the server side.
public enum UUIDv7 {

    public static func generate(date: Date = Date()) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)

        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        bytes[0] = UInt8((millis >> 40) & 0xFF)
        bytes[1] = UInt8((millis >> 32) & 0xFF)
        bytes[2] = UInt8((millis >> 24) & 0xFF)
        bytes[3] = UInt8((millis >> 16) & 0xFF)
        bytes[4] = UInt8((millis >> 8) & 0xFF)
        bytes[5] = UInt8(millis & 0xFF)

        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }

        bytes[6] = (bytes[6] & 0x0F) | 0x70          // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80          // RFC 4122 variant

        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Lowercase string form, which is what the wire format uses.
    public static func string(date: Date = Date()) -> String {
        generate(date: date).uuidString.lowercased()
    }

    public static func isV7(_ uuid: UUID) -> Bool {
        let b = uuid.uuid
        return (b.6 & 0xF0) == 0x70 && (b.8 & 0xC0) == 0x80
    }

    /// Timestamp encoded in the first 48 bits, for ordering and diagnostics.
    public static func timestamp(of uuid: UUID) -> Date {
        let b = uuid.uuid
        let millis = (UInt64(b.0) << 40) | (UInt64(b.1) << 32) | (UInt64(b.2) << 24)
            | (UInt64(b.3) << 16) | (UInt64(b.4) << 8) | UInt64(b.5)
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
