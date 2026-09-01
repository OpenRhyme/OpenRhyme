import AppKit
import ApplicationServices
import Core
import Foundation

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

    public func focusedContext(of app: AppInfo) throws -> FocusedContext {
        let application = AXUIElementCreateApplication(app.pid)
        var window: WindowInfo?
        if let focusedWindow = try element(application, kAXFocusedWindowAttribute) {
            window = try readWindow(focusedWindow)
        }
        var element: ElementInfo?
        if let focused = try self.element(application, kAXFocusedUIElementAttribute) {
            element = try readElement(focused)
        }
        return FocusedContext(app: app, window: window, element: element)
    }

    public func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
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

        let content = try attributes(
            element,
            [
                kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute,
                kAXNumberOfCharactersAttribute, kAXDescriptionAttribute,
            ])
        // Spec §6.4 order: value → selected text → description for static text.
        info.value = string(content[0]) ?? number(content[0]).map { String($0) }
        if info.value == nil, info.role == kAXStaticTextRole {
            info.value = string(content[4]) ?? info.title
        }
        info.selectedText = string(content[1])
        info.selectedRange = range(content[2])
        info.numberOfCharacters = number(content[3]).map(Int.init)
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
