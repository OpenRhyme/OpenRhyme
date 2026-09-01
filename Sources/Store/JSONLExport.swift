import Core
import Foundation

/// One event per line, keys in `events` column order (spec §7.3). Hand-written so the order
/// is the column order rather than `JSONEncoder`'s alphabetical order.
public enum JSONLExport {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func line(for event: RawEvent) throws -> String {
        var fields: [(String, String)] = []
        if let id = event.id { fields.append(("id", String(id))) }
        fields.append(("ts", number(event.ts)))
        fields.append(("kind", quoted(event.kind.rawValue)))
        if let pid = event.pid { fields.append(("pid", String(pid))) }
        let strings: [(String, String?)] = [
            ("bundle_id", event.bundleID), ("app_name", event.appName),
            ("window_title", event.windowTitle), ("document", event.document),
            ("url", event.url), ("role", event.role), ("subrole", event.subrole),
            ("identifier", event.identifier), ("element_title", event.elementTitle),
            ("value", event.value), ("selected_text", event.selectedText),
        ]
        for (key, value) in strings {
            if let value { fields.append((key, quoted(value))) }
        }
        if let extra = event.extra {
            fields.append(("extra", String(decoding: try encoder.encode(extra), as: UTF8.self)))
        }
        return "{" + fields.map { "\"\($0)\":\($1)" }.joined(separator: ",") + "}"
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// JSON string literal with the escapes RFC 8259 requires. Slashes are left alone.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case ..<" ": out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
