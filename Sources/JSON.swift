import Foundation

/// A tiny order-preserving JSON model. Chase Scene edits other apps' settings files,
/// so it keeps their key order and number formatting intact instead of reshuffling them.
struct JSONMember: Equatable {
    var key: String
    var value: JSONValue
}

indirect enum JSONValue: Equatable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(JSONMember(key: key, value: newValue))
            }
            self = .object(members)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var isObject: Bool { if case .object = self { return true }; return false }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.failure("Unexpected text after JSON value") }
        return value
    }

    static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    // MARK: Writing (two-space indentation, like most editors and JSON.stringify(_, null, 2))

    func serialized() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, member) in members.enumerated() {
                out += pad + JSONValue.quote(member.key) + ": "
                member.value.write(into: &out, indent: indent + 1)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .string(let s): out += JSONValue.quote(s)
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) {
        // Tolerate a UTF-8 byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { self.bytes = Array(bytes.dropFirst(3)) } else { self.bytes = bytes }
    }

    func failure(_ message: String) -> ControlError {
        ControlError.invalid("\(message) at byte \(index).")
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw failure("Expected \(literal)")
        }
        index += expected.count
    }

    mutating func value() throws -> JSONValue {
        guard index < bytes.count else { throw failure("Unexpected end of JSON") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try number()
        }
    }

    mutating func object() throws -> JSONValue {
        depth += 1
        guard depth < 200 else { throw failure("JSON nested too deeply") }
        defer { depth -= 1 }
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure("Expected a quoted key") }
            let key = try string()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            members.append(JSONMember(key: key, value: try value()))
            skipWhitespace()
            guard index < bytes.count else { throw failure("Unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            throw failure("Expected , or }")
        }
    }

    mutating func array() throws -> JSONValue {
        depth += 1
        guard depth < 200 else { throw failure("JSON nested too deeply") }
        defer { depth -= 1 }
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw failure("Unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw failure("Expected , or ]")
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw failure("Invalid \\u escape")
        }
        index += 4
        return value
    }

    mutating func string() throws -> String {
        index += 1
        var raw: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let text = String(bytes: raw, encoding: .utf8) else { throw failure("Invalid UTF-8") }
                return text
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw failure("Unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): raw.append(0x22)
                case UInt8(ascii: "\\"): raw.append(0x5C)
                case UInt8(ascii: "/"): raw.append(0x2F)
                case UInt8(ascii: "b"): raw.append(0x08)
                case UInt8(ascii: "f"): raw.append(0x0C)
                case UInt8(ascii: "n"): raw.append(0x0A)
                case UInt8(ascii: "r"): raw.append(0x0D)
                case UInt8(ascii: "t"): raw.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw failure("Invalid surrogate pair") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw failure("Invalid unicode escape") }
                    raw.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw failure("Invalid escape")
                }
            default:
                guard byte >= 0x20 else { throw failure("Control character in string") }
                raw.append(byte)
            }
        }
        throw failure("Unterminated string")
    }

    mutating func number() throws -> JSONValue {
        let start = index
        let allowed = Set("-+.eE0123456789".utf8)
        while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !text.isEmpty, Double(text) != nil, text.first != "+" else {
            index = start
            throw failure("Invalid value")
        }
        return .number(text)
    }
}
