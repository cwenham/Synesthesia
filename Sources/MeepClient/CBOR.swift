import Foundation

/// Reads CBOR (RFC 8949), as a subscription sends it when asked for `cbor`, back into JSON text, so it's decoded the
/// same way as JSON. The daemon's CBOR has the same keys and shapes as its JSON: maps, arrays, text, whole numbers as
/// integers and others as the smallest float that holds them exactly.
public enum CBOR {
    public enum Problem: Error, Equatable, LocalizedError {
        case truncated
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .truncated: "A CBOR frame ended part way through a value."
            case .unsupported(let what): "A CBOR frame had \(what), which Synesthesia doesn't read."
            }
        }
    }

    /// The JSON text for one CBOR value.
    public static func json(from data: Data) throws -> Data {
        var reader = Reader(bytes: [UInt8](data))
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 2)
        try reader.value(into: &out)
        return Data(out)
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        mutating func byte() throws -> UInt8 {
            guard at < bytes.count else { throw Problem.truncated }
            defer { at += 1 }
            return bytes[at]
        }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, at + count <= bytes.count else { throw Problem.truncated }
            defer { at += count }
            return bytes[at..<(at + count)]
        }

        /// The argument that follows a head's major type: a number, a length or a simple value. Nil for indefinite.
        mutating func argument(_ info: UInt8) throws -> UInt64? {
            switch info {
            case 0..<24: return UInt64(info)
            case 24: return UInt64(try byte())
            case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
            case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
            case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
            case 31: return nil
            default: throw Problem.unsupported("a reserved length")
            }
        }

        mutating func isBreak() throws -> Bool {
            guard at < bytes.count else { throw Problem.truncated }
            if bytes[at] == 0xFF {
                at += 1
                return true
            }
            return false
        }

        mutating func value(into out: inout [UInt8]) throws {
            let head = try byte()
            let major = head >> 5
            let info = head & 0x1F
            switch major {
            case 0:
                guard let n = try argument(info) else { throw Problem.unsupported("an indefinite number") }
                out += Array(String(n).utf8)
            case 1:
                guard let n = try argument(info) else { throw Problem.unsupported("an indefinite number") }
                out += Array((n < UInt64(Int64.max) ? String(-1 - Int64(n)) : "-" + String(n &+ 1)).utf8)
            case 2:
                // Bytes have no JSON form; base64, as JSON-minded encoders write them.
                var raw: [UInt8] = []
                try chunks(info, major: 2) { raw += $0 }
                out += Array("\"\(Data(raw).base64EncodedString())\"".utf8)
            case 3:
                var raw: [UInt8] = []
                try chunks(info, major: 3) { raw += $0 }
                Self.writeString(raw, into: &out)
            case 4:
                out.append(UInt8(ascii: "["))
                var first = true
                if let count = try argument(info) {
                    for _ in 0..<count {
                        if !first { out.append(UInt8(ascii: ",")) }
                        first = false
                        try value(into: &out)
                    }
                } else {
                    while try !isBreak() {
                        if !first { out.append(UInt8(ascii: ",")) }
                        first = false
                        try value(into: &out)
                    }
                }
                out.append(UInt8(ascii: "]"))
            case 5:
                out.append(UInt8(ascii: "{"))
                var first = true
                func pair(_ reader: inout Reader) throws {
                    if !first { out.append(UInt8(ascii: ",")) }
                    first = false
                    try reader.key(into: &out)
                    out.append(UInt8(ascii: ":"))
                    try reader.value(into: &out)
                }
                if let count = try argument(info) {
                    for _ in 0..<count { try pair(&self) }
                } else {
                    while try !isBreak() { try pair(&self) }
                }
                out.append(UInt8(ascii: "}"))
            case 6:
                // A tag says what its content means; the content is what's wanted.
                _ = try argument(info)
                try value(into: &out)
            default:
                try simple(info, into: &out)
            }
        }

        /// A map's key, as JSON text: text as it is, anything else written as text.
        mutating func key(into out: inout [UInt8]) throws {
            guard at < bytes.count else { throw Problem.truncated }
            if bytes[at] >> 5 == 3 {
                try value(into: &out)
            } else {
                var inner: [UInt8] = []
                try value(into: &inner)
                Self.writeString(inner.first == UInt8(ascii: "\"") ? Array(inner.dropFirst().dropLast()) : inner, into: &out)
            }
        }

        mutating func chunks(_ info: UInt8, major: UInt8, _ take: ([UInt8]) -> Void) throws {
            if let count = try argument(info) {
                take(Array(try self.take(Int(count))))
                return
            }
            while try !isBreak() {
                let head = try byte()
                guard head >> 5 == major, let count = try argument(head & 0x1F) else {
                    throw Problem.unsupported("a broken indefinite string")
                }
                take(Array(try self.take(Int(count))))
            }
        }

        mutating func simple(_ info: UInt8, into out: inout [UInt8]) throws {
            switch info {
            case 20: out += Array("false".utf8)
            case 21: out += Array("true".utf8)
            case 22, 23: out += Array("null".utf8)
            case 24:
                _ = try byte()
                out += Array("null".utf8)
            case 25:
                // Half precision, worked out by hand: Float16 isn't available on Intel Macs.
                let bits = Int(try take(2).reduce(0) { $0 << 8 | UInt64($1) })
                let exponent = (bits >> 10) & 0x1F
                let mantissa = Double(bits & 0x3FF)
                let magnitude = exponent == 0 ? mantissa * pow(2, -24)
                    : exponent == 31 ? (mantissa == 0 ? .infinity : .nan)
                    : (1 + mantissa / 1024) * pow(2, Double(exponent - 15))
                Self.writeNumber(bits & 0x8000 != 0 ? -magnitude : magnitude, into: &out)
            case 26:
                let bits = UInt32(try take(4).reduce(0) { $0 << 8 | UInt64($1) })
                Self.writeNumber(Double(Float(bitPattern: bits)), into: &out)
            case 27:
                let bits = try take(8).reduce(0) { $0 << 8 | UInt64($1) }
                Self.writeNumber(Double(bitPattern: bits), into: &out)
            case 31: throw Problem.unsupported("a break outside an indefinite value")
            default: out += Array("null".utf8)
            }
        }

        static func writeNumber(_ value: Double, into out: inout [UInt8]) {
            guard value.isFinite else {
                out += Array("null".utf8)
                return
            }
            if value == value.rounded(), abs(value) < 9e15 {
                out += Array(String(Int64(value)).utf8)
            } else {
                out += Array("\(value)".utf8)
            }
        }

        static func writeString(_ utf8: [UInt8], into out: inout [UInt8]) {
            out.append(UInt8(ascii: "\""))
            for byte in utf8 {
                switch byte {
                case UInt8(ascii: "\""): out += [UInt8(ascii: "\\"), UInt8(ascii: "\"")]
                case UInt8(ascii: "\\"): out += [UInt8(ascii: "\\"), UInt8(ascii: "\\")]
                case 0x0A: out += [UInt8(ascii: "\\"), UInt8(ascii: "n")]
                case 0x0D: out += [UInt8(ascii: "\\"), UInt8(ascii: "r")]
                case 0x09: out += [UInt8(ascii: "\\"), UInt8(ascii: "t")]
                case 0..<0x20: out += Array(String(format: "\\u%04x", byte).utf8)
                default: out.append(byte)
                }
            }
            out.append(UInt8(ascii: "\""))
        }
    }
}
