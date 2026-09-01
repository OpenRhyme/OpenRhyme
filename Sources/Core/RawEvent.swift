import Foundation

public enum EngineVersion {
    public static let string = "0.1.0"
}

/// One row of the `events` table. Field names in JSON are the column names.
public struct RawEvent: Codable, Sendable, Equatable {
    public var id: Int64?
    public var ts: Double
    public var kind: EventKind
    public var pid: Int32?
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var document: String?
    public var url: String?
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var elementTitle: String?
    public var value: String?
    public var selectedText: String?
    public var extra: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, ts, kind, pid
        case bundleID = "bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case document, url, role, subrole, identifier
        case elementTitle = "element_title"
        case value
        case selectedText = "selected_text"
        case extra
    }

    public init(
        id: Int64? = nil, ts: Double, kind: EventKind, pid: Int32? = nil,
        bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil,
        document: String? = nil, url: String? = nil, role: String? = nil,
        subrole: String? = nil, identifier: String? = nil, elementTitle: String? = nil,
        value: String? = nil, selectedText: String? = nil, extra: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.ts = ts
        self.kind = kind
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.document = document
        self.url = url
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.elementTitle = elementTitle
        self.value = value
        self.selectedText = selectedText
        self.extra = extra
    }
}
