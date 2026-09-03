import AppKit
import ApplicationServices
import Core
import Foundation
import os

extension AppInfo {
    public init(running app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName,
            bundleURL: app.bundleURL)
    }
}

/// The real `AXReading` over the C API (docs/accessibility-api.md §3). Every read is one
/// `AXUIElementCopyMultipleAttributeValues` round-trip per element.
@MainActor
public final class AXClient: AXReading {
    public init() {}

    private let hub = AXObserverHub()
    private let lifecycle = AppLifecycle()
    private let logger = Logger(subsystem: "org.openrhyme.engine", category: "ax")

    public func isTrusted(prompt: Bool) -> Bool {
        // The literal key avoids importing the non-Sendable `kAXTrustedCheckOptionPrompt` global.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func setGlobalMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    public func runningApplications() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(AppInfo.init(running:))
    }

    public func frontmostApplication() -> AppInfo? {
        NSWorkspace.shared.frontmostApplication.map(AppInfo.init(running:))
    }

    public private(set) var contentReadCount = 0

    public func focusedContext(
        of app: AppInfo, reusing cache: ContentCache?
    ) throws -> FocusedContext {
        let application = AXUIElementCreateApplication(app.pid)
        var window: WindowInfo?
        if let focusedWindow = try element(application, kAXFocusedWindowAttribute) {
            window = try readWindow(focusedWindow)
        }
        var element: ElementInfo?
        if let focused = try self.element(application, kAXFocusedUIElementAttribute) {
            let ids = try attributes(
                focused,
                [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
            let role = string(ids[0])
            let subrole = string(ids[1])
            let identifier = string(ids[2])
            let title = string(ids[3])
            if let cache,
                cache.matches(
                    role: role, subrole: subrole, identifier: identifier, title: title,
                    windowTitle: window?.title, document: window?.document, url: window?.url)
            {
                // Cache hit: rung 1 (own value) is cheap and must stay fresh so native-field
                // edits aren't masked; only the expensive rungs 2-3 are reused (spec §6).
                var info = try readElementIdentityOnly(focused)
                if !info.isSecure {
                    let resolved = ContentExtractor.resolveHit(
                        from: AXUIElementTextNode(focused, client: self),
                        cachedValue: cache.value,
                        cachedSource: cache.textSource.flatMap(TextSource.init(rawValue:)))
                    info.value = resolved.value
                    info.textSource = resolved.source?.rawValue
                }
                element = info
            } else {
                contentReadCount += 1
                element = try readElement(focused)
            }
        }
        return FocusedContext(app: app, window: window, element: element)
    }

    /// Identity + selection only (no content ladder), for the cache-hit path.
    func readElementIdentityOnly(_ element: AXUIElement) throws -> ElementInfo {
        let identity = try attributes(
            element,
            [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
        var info = ElementInfo(
            role: string(identity[0]), subrole: string(identity[1]),
            identifier: string(identity[2]), title: string(identity[3]))
        guard !info.isSecure else { return info }
        let content = try attributes(
            element,
            [
                kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute,
                kAXNumberOfCharactersAttribute,
            ])
        info.selectedText = string(content[0])
        info.selectedRange = range(content[1])
        info.numberOfCharacters = number(content[2]).map(Int.init)
        return info
    }

    /// Build a cache key from a just-read context.
    public func cache(from context: FocusedContext) -> ContentCache {
        ContentCache(
            role: context.element?.role, subrole: context.element?.subrole,
            identifier: context.element?.identifier, title: context.element?.title,
            windowTitle: context.window?.title, document: context.window?.document,
            url: context.window?.url, value: context.element?.value,
            textSource: context.element?.textSource)
    }

    public func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: - Observers (spec §5.4)

    public func startObserving(
        _ app: AppInfo, handler: @escaping @MainActor (ObservedChange) -> Void
    ) throws {
        try hub.start(pid: app.pid, handler: handler)
    }

    public func stopObserving(pid: Int32) { hub.stop(pid: pid) }

    public func stopObservingAll() { hub.stopAll() }

    public func startLifecycle(handler: @escaping @MainActor (LifecycleEvent) -> Void) {
        lifecycle.start(handler: handler)
    }

    public func stopLifecycle() { lifecycle.stop() }

    /// Spec §5.7. `AXManualAccessibility` first; on `attributeUnsupported` fall back to
    /// `AXEnhancedUserInterface`. Logged: it is the only write the daemon makes into another
    /// process.
    public func enableElectronAccessibility(_ app: AppInfo) -> ElectronEnableResult {
        let application = AXUIElementCreateApplication(app.pid)
        for method in ElectronSupport.enableAttributes {
            let error = AXUIElementSetAttributeValue(
                application, method as CFString, kCFBooleanTrue)
            switch error {
            case .success:
                logger.info("set \(method) on pid \(app.pid) (\(app.bundleID ?? "?"))")
                return ElectronEnableResult(method: method, result: "ok")
            case .attributeUnsupported:
                continue
            default:
                logger.warning(
                    "\(method) on pid \(app.pid) failed: AXError \(error.rawValue)")
                return ElectronEnableResult(method: method, result: "failed")
            }
        }
        return ElectronEnableResult(
            method: ElectronSupport.enableAttributes.last ?? "", result: "unsupported")
    }

    // MARK: - Reads (internal so AXClient+Inspect can reuse them)

    func readWindow(_ window: AXUIElement) throws -> WindowInfo {
        let values = try attributes(
            window, [kAXTitleAttribute, kAXDocumentAttribute, kAXURLAttribute])
        return WindowInfo(
            title: string(values[0]), document: string(values[1]) ?? url(values[1]),
            url: url(values[2]) ?? string(values[2]))
    }

    func readElement(_ element: AXUIElement) throws -> ElementInfo {
        let identity = try attributes(
            element,
            [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
        var info = ElementInfo(
            role: string(identity[0]), subrole: string(identity[1]),
            identifier: string(identity[2]), title: string(identity[3]))
        guard !info.isSecure else { return info }

        // value + textSource via the content ladder (spec §4). 512 KB harvest guard; Redaction
        // applies the authoritative per-config cap downstream.
        let extracted = ContentExtractor.extract(
            from: AXUIElementTextNode(element, client: self), maxBytes: 524_288)
        info.value = extracted.value
        info.textSource = extracted.source?.rawValue

        let content = try attributes(
            element,
            [
                kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute,
                kAXNumberOfCharactersAttribute,
            ])
        info.selectedText = string(content[0])
        info.selectedRange = range(content[1])
        info.numberOfCharacters = number(content[2]).map(Int.init)
        return info
    }

    func element(_ parent: AXUIElement, _ name: String) throws -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, name as CFString, &value)
        try check(error)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ parent: AXUIElement, _ name: String) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, name as CFString, &value)
        try check(error)
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return ((value as! CFArray) as NSArray).compactMap { item -> AXUIElement? in
            let object = item as AnyObject
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
    }

    /// One IPC for several attributes. Unsupported attributes come back as `nil`.
    func attributes(_ element: AXUIElement, _ names: [String]) throws -> [CFTypeRef?] {
        var array: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &array)
        try check(error)
        guard let array else { return Array(repeating: nil, count: names.count) }
        return (0..<CFArrayGetCount(array)).map { index -> CFTypeRef? in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            if CFGetTypeID(value) == AXValueGetTypeID(),
                AXValueGetType(value as! AXValue) == .axError
            {
                return nil  // placeholder for an unsupported attribute
            }
            return value
        }
    }

    func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names else {
            return []
        }
        return (names as NSArray).compactMap { $0 as? String }
    }

    func check(_ error: AXError) throws {
        switch error {
        case .success, .noValue, .attributeUnsupported: return
        case .apiDisabled: throw AXReadError.apiDisabled
        case .cannotComplete: throw AXReadError.cannotComplete
        case .notImplemented: throw AXReadError.notImplemented
        case .invalidUIElement: throw AXReadError.invalidElement
        default: throw AXReadError.other(error.rawValue)
        }
    }

    // MARK: - Ranged text (spec §4.1)

    /// The element's visible character range, if it advertises one.
    func visibleCharacterRange(_ element: AXUIElement) throws -> TextRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXVisibleCharacterRangeAttribute as CFString, &value)
        try check(error)
        return range(value)
    }

    /// The text for a character range, via the parameterized `AXStringForRange` attribute.
    /// Returns nil when the element does not support it (mapped to no-error by `check`).
    func stringForRange(_ element: AXUIElement, _ textRange: TextRange) throws -> String? {
        var cfRange = CFRange(location: textRange.location, length: textRange.length)
        guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &value)
        try check(error)
        return string(value)
    }

    // MARK: - CF conversions

    func string(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    func url(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return ((value as! CFURL) as URL).absoluteString
    }

    func number(_ value: CFTypeRef?) -> Double? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return ((value as! CFNumber) as NSNumber).doubleValue
    }

    func range(_ value: CFTypeRef?) -> TextRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }
        return TextRange(location: cfRange.location, length: cfRange.length)
    }
}

/// `TextNode` backed by a real `AXUIElement`, so `ContentExtractor` can read the live tree.
@MainActor
struct AXUIElementTextNode: @MainActor TextNode {
    let element: AXUIElement
    unowned let client: AXClient
    let role: String?
    let subrole: String?

    init(_ element: AXUIElement, client: AXClient) {
        self.element = element
        self.client = client
        let ids =
            (try? client.attributes(element, [kAXRoleAttribute, kAXSubroleAttribute])) ?? [
                nil, nil,
            ]
        self.role = client.string(ids[0])
        self.subrole = client.string(ids[1])
    }

    /// Rung 1, behaviour-identical to the pre-slice value read: value → number-as-string →
    /// (static text) description → title.
    func ownValue() throws -> String? {
        let content = try client.attributes(
            element, [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute])
        if let s = client.string(content[0]) { return s }
        if let n = client.number(content[0]) { return String(n) }
        if role == kAXStaticTextRole {
            return client.string(content[1]) ?? client.string(content[2])
        }
        return nil
    }

    func rangedText() throws -> String? {
        guard let vr = try client.visibleCharacterRange(element), vr.length > 0 else { return nil }
        return try client.stringForRange(element, vr)
    }

    func children() throws -> [TextNode] {
        try client.elements(element, kAXChildrenAttribute).map {
            AXUIElementTextNode($0, client: self.client)
        }
    }
}
