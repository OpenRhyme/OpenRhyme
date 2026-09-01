// Capture — macOS Accessibility capture. Owns TCC trust checks and recovery, the focused
// context reads (and, from Part 2, observers). Emits Sendable structs only; AXUIElement
// never leaves this module. Reference: docs/accessibility-api.md.

import Foundation

public struct AppInfo: Sendable, Equatable, Hashable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var bundleURL: URL?

    public init(pid: Int32, bundleID: String?, name: String?, bundleURL: URL?) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
    }
}

public struct WindowInfo: Sendable, Equatable {
    public var title: String?
    public var document: String?
    public var url: String?

    public init(title: String? = nil, document: String? = nil, url: String? = nil) {
        self.title = title
        self.document = document
        self.url = url
    }
}

public struct TextRange: Sendable, Equatable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct ElementInfo: Sendable, Equatable {
    public static let secureSubrole = "AXSecureTextField"

    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var value: String?
    public var selectedText: String?
    public var selectedRange: TextRange?
    public var numberOfCharacters: Int?

    public init(
        role: String? = nil, subrole: String? = nil, identifier: String? = nil,
        title: String? = nil, value: String? = nil, selectedText: String? = nil,
        selectedRange: TextRange? = nil, numberOfCharacters: Int? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.numberOfCharacters = numberOfCharacters
    }

    public var isSecure: Bool { subrole == Self.secureSubrole }
}

public struct FocusedContext: Sendable, Equatable {
    public var app: AppInfo
    public var window: WindowInfo?
    public var element: ElementInfo?

    public init(app: AppInfo, window: WindowInfo?, element: ElementInfo?) {
        self.app = app
        self.window = window
        self.element = element
    }
}

public enum TrustState: String, Sendable {
    case needsPermission
    case active
    case stale
}

public enum AXReadError: Error, Equatable, Sendable {
    case apiDisabled
    case cannotComplete
    case notImplemented
    case invalidElement
    case other(Int32)
}

/// Everything the capture logic needs from the Accessibility API, so it can be driven by
/// `FakeAXClient` in tests and by `AXClient` in the daemon. Main-actor: AX is not thread-safe.
@MainActor
public protocol AXReading: AnyObject {
    func isTrusted(prompt: Bool) -> Bool
    func setGlobalMessagingTimeout(_ seconds: Float)
    func runningApplications() -> [AppInfo]
    func frontmostApplication() -> AppInfo?
    /// Focused window and element of `app`. Throws `AXReadError` when the app cannot be read.
    func focusedContext(of app: AppInfo) throws -> FocusedContext
    /// Seconds since the last keyboard/mouse event in this session. Needs no TCC grant.
    func secondsSinceLastInput() -> Double
}
