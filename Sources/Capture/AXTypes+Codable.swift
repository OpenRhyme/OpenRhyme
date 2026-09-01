// Manual Codable: automatic synthesis requires the conformance to live in the same file as
// the type declaration, and these types are declared in AXTypes.swift.

import Foundation

extension AppInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case pid
        case bundleID = "bundle_id"
        case name
        case bundleURL = "bundle_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pid: try container.decode(Int32.self, forKey: .pid),
            bundleID: try container.decodeIfPresent(String.self, forKey: .bundleID),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            bundleURL: try container.decodeIfPresent(URL.self, forKey: .bundleURL))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encodeIfPresent(bundleID, forKey: .bundleID)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(bundleURL, forKey: .bundleURL)
    }
}

extension WindowInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case title, document, url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title),
            document: try container.decodeIfPresent(String.self, forKey: .document),
            url: try container.decodeIfPresent(String.self, forKey: .url))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(document, forKey: .document)
        try container.encodeIfPresent(url, forKey: .url)
    }
}

extension TextRange: Codable {
    enum CodingKeys: String, CodingKey {
        case location, length
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            location: try container.decode(Int.self, forKey: .location),
            length: try container.decode(Int.self, forKey: .length))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(location, forKey: .location)
        try container.encode(length, forKey: .length)
    }
}

extension ElementInfo: Codable {
    enum CodingKeys: String, CodingKey {
        case role, subrole, identifier, title, value
        case selectedText = "selected_text"
        case selectedRange = "selected_range"
        case numberOfCharacters = "number_of_characters"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            role: try container.decodeIfPresent(String.self, forKey: .role),
            subrole: try container.decodeIfPresent(String.self, forKey: .subrole),
            identifier: try container.decodeIfPresent(String.self, forKey: .identifier),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            value: try container.decodeIfPresent(String.self, forKey: .value),
            selectedText: try container.decodeIfPresent(String.self, forKey: .selectedText),
            selectedRange: try container.decodeIfPresent(TextRange.self, forKey: .selectedRange),
            numberOfCharacters: try container.decodeIfPresent(
                Int.self, forKey: .numberOfCharacters))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(selectedText, forKey: .selectedText)
        try container.encodeIfPresent(selectedRange, forKey: .selectedRange)
        try container.encodeIfPresent(numberOfCharacters, forKey: .numberOfCharacters)
    }
}

extension FocusedContext: Codable {
    enum CodingKeys: String, CodingKey {
        case app, window, element
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            app: try container.decode(AppInfo.self, forKey: .app),
            window: try container.decodeIfPresent(WindowInfo.self, forKey: .window),
            element: try container.decodeIfPresent(ElementInfo.self, forKey: .element))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encodeIfPresent(window, forKey: .window)
        try container.encodeIfPresent(element, forKey: .element)
    }
}
