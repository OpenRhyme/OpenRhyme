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
    public var textSource: String?

    public init(
        role: String? = nil, subrole: String? = nil, identifier: String? = nil,
        title: String? = nil, value: String? = nil, selectedText: String? = nil,
        selectedRange: TextRange? = nil, numberOfCharacters: Int? = nil,
        textSource: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.numberOfCharacters = numberOfCharacters
        self.textSource = textSource
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

/// The cheap-identity + resolved content of a focused element, cached across heartbeats so the
/// expensive content read (spec §6) is skipped when nothing user-visible changed.
public struct ContentCache: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var windowTitle: String?
    public var document: String?
    public var url: String?
    public var value: String?
    public var textSource: String?

    public init(
        role: String? = nil, subrole: String? = nil, identifier: String? = nil,
        title: String? = nil, windowTitle: String? = nil, document: String? = nil,
        url: String? = nil, value: String? = nil, textSource: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.windowTitle = windowTitle
        self.document = document
        self.url = url
        self.value = value
        self.textSource = textSource
    }

    /// True when the cheap identity is unchanged, so the cached `value`/`textSource` may be reused.
    public func matches(
        role: String?, subrole: String?, identifier: String?, title: String?,
        windowTitle: String?, document: String?, url: String?
    ) -> Bool {
        self.role == role && self.subrole == subrole && self.identifier == identifier
            && self.title == title && self.windowTitle == windowTitle
            && self.document == document && self.url == url
    }
}

/// Spec §5.3. What an `AXObserver` notification meant — AX-free, so the Capturer and tests never
/// see an `AXUIElement`.
public enum ObservedKind: String, Sendable {
    case focusedWindowChanged  // kAXFocusedWindowChanged and kAXMainWindowChanged
    case focusedElementChanged  // kAXFocusedUIElementChanged
    case titleChanged  // kAXTitleChanged
    case valueChanged  // kAXValueChanged, registered on the focused element
    case menuItemSelected  // kAXMenuItemSelected
}

public struct ObservedChange: Sendable, Equatable {
    public var pid: Int32
    public var kind: ObservedKind
    /// `menuItemSelected` only: the item's title, read once in the callback.
    public var menuTitle: String?
    public var ts: Double

    public init(pid: Int32, kind: ObservedKind, menuTitle: String? = nil, ts: Double) {
        self.pid = pid
        self.kind = kind
        self.menuTitle = menuTitle
        self.ts = ts
    }
}

/// Spec §5.2. `NSWorkspace` app lifecycle and power events.
public enum LifecycleEvent: Sendable, Equatable {
    case launched(AppInfo)
    case terminated(AppInfo)
    case activated(AppInfo)
    case sleep
    case wake
}

/// Spec §5.7. Outcome of the one write the daemon performs into another process.
public struct ElectronEnableResult: Sendable, Equatable {
    public var method: String  // "AXManualAccessibility" | "AXEnhancedUserInterface"
    public var result: String  // "ok" | "unsupported" | "failed"

    public init(method: String, result: String) {
        self.method = method
        self.result = result
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
    /// Focused window and element of `app`. `reusing` is the previous heartbeat's cached
    /// cheap-identity + content; when the cheap identity is unchanged the expensive content read
    /// is skipped and the cached value reused (spec §6). Throws `AXReadError` when the app cannot be read.
    func focusedContext(of app: AppInfo, reusing cache: ContentCache?) throws -> FocusedContext
    /// Seconds since the last keyboard/mouse event in this session. Needs no TCC grant.
    func secondsSinceLastInput() -> Double
    /// Build a cache key from a just-read context.
    func cache(from context: FocusedContext) -> ContentCache

    // MARK: Observers (spec §5.4)

    /// Register for `app`'s in-app notifications. Throws `.cannotComplete` / `.invalidElement`
    /// while the app's AX tree is not ready — the caller retries (spec §6.2).
    func startObserving(
        _ app: AppInfo, handler: @escaping @MainActor (ObservedChange) -> Void) throws
    func stopObserving(pid: Int32)
    func stopObservingAll()
    func startLifecycle(handler: @escaping @MainActor (LifecycleEvent) -> Void)
    func stopLifecycle()
    /// Spec §5.7: the daemon's only write into another process.
    func enableElectronAccessibility(_ app: AppInfo) -> ElectronEnableResult
}
