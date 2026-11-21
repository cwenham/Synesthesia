import Foundation
import MeepClient

/// Checks a tool's input against its JSON Schema before the sidebar runs it. Input streams in without the API checking
/// it, so it can be cut short or not match; such input isn't run, and Claude is told what was wrong.
///
/// It knows the parts of JSON Schema the tools' schemas use: `type`, `properties`, `required`, `additionalProperties`,
/// `enum`, `const`, `items`, `minItems`, `maxItems`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
/// `minLength`, `maxLength` and `anyOf`. Anything else is let through.
public enum SchemaCheck {
    /// The first thing wrong with `value`, with where it is, or nil if it fits.
    public static func problem(with value: JSONValue, against schema: JSONValue, at path: String = "input") -> String? {
        guard case .object = schema else { return nil }
        if let options = schema["anyOf"]?.array, !options.isEmpty,
           options.allSatisfy({ problem(with: value, against: $0, at: path) != nil }) {
            return "\(path) doesn't match any of the forms it can take."
        }
        if let allowed = schema["enum"]?.array, !allowed.contains(where: { same($0, value) }) {
            let names = allowed.map { $0.string ?? $0.text() }.joined(separator: ", ")
            return "\(path) is \(describe(value)), but must be one of: \(names)."
        }
        if let constant = schema["const"], !same(constant, value) {
            return "\(path) must be \(constant.text())."
        }
        if let types = expectedTypes(schema), !types.contains(where: { fits(value, $0) }) {
            return "\(path) should be \(types.map(article).joined(separator: " or ")), not \(describe(value))."
        }
        switch value {
        case .object(let object):
            var properties: [String: JSONValue] = [:]
            if case .object(let declared)? = schema["properties"] { properties = declared }
            for name in schema["required"]?.array?.compactMap(\.string) ?? [] where object[name] == nil {
                return "\(path) is missing \(name)."
            }
            for (name, item) in object.sorted(by: { $0.key < $1.key }) {
                if let property = properties[name] {
                    if let found = problem(with: item, against: property, at: "\(path).\(name)") { return found }
                } else if schema["additionalProperties"] == false {
                    return "\(path) has \(name), which isn't one of its properties (\(properties.keys.sorted().joined(separator: ", ")))."
                } else if let extra = schema["additionalProperties"], case .object = extra,
                          let found = problem(with: item, against: extra, at: "\(path).\(name)") {
                    return found
                }
            }
        case .array(let items):
            if let least = schema["minItems"]?.number, Double(items.count) < least {
                return "\(path) needs at least \(Int(least)) item\(least == 1 ? "" : "s")."
            }
            if let most = schema["maxItems"]?.number, Double(items.count) > most {
                return "\(path) can have at most \(Int(most)) items."
            }
            if let item = schema["items"] {
                for (index, element) in items.enumerated() {
                    if let found = problem(with: element, against: item, at: "\(path)[\(index)]") { return found }
                }
            }
        case .number(let number):
            if let least = schema["minimum"]?.number, number < least { return "\(path) is \(format(number)), below its least, \(format(least))." }
            if let most = schema["maximum"]?.number, number > most { return "\(path) is \(format(number)), above its most, \(format(most))." }
            if let above = schema["exclusiveMinimum"]?.number, number <= above { return "\(path) must be more than \(format(above))." }
            if let below = schema["exclusiveMaximum"]?.number, number >= below { return "\(path) must be less than \(format(below))." }
        case .string(let text):
            if let least = schema["minLength"]?.number, Double(text.count) < least { return "\(path) is too short." }
            if let most = schema["maxLength"]?.number, Double(text.count) > most { return "\(path) is too long." }
        default:
            break
        }
        return nil
    }

    private static func expectedTypes(_ schema: JSONValue) -> [String]? {
        if let one = schema["type"]?.string { return [one] }
        if let many = schema["type"]?.array?.compactMap(\.string), !many.isEmpty { return many }
        return nil
    }

    private static func fits(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number): true
        case ("integer", .number(let number)): number.rounded() == number
        default: false
        }
    }

    /// Numbers compare by value; everything else as JSON.
    private static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if case .number(let x) = a, case .number(let y) = b { return x == y }
        return a == b
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): "\(flag)"
        case .number(let number): format(number)
        case .string(let text): "\"\(text.count > 40 ? String(text.prefix(40)) + "…" : text)\""
        case .array: "an array"
        case .object: "an object"
        }
    }

    private static func article(_ type: String) -> String {
        switch type {
        case "object", "array", "integer": "an \(type)"
        case "null": "null"
        default: "a \(type)"
        }
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}
