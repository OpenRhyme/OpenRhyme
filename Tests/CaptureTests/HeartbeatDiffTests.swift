import Testing

@testable import Capture
@testable import Core

@Suite @MainActor struct HeartbeatDiffTests {
    let safari = FakeAXClient.app(10, "com.apple.Safari")
    let textEdit = FakeAXClient.app(20, "com.apple.TextEdit")
    let finder = FakeAXClient.app(30, "com.apple.finder")
    let allow: Set<String> = ["com.apple.Safari", "com.apple.TextEdit"]

    private func input(
        _ app: AppInfo?, window: WindowInfo? = nil, element: ElementInfo? = nil,
        others: Bool = false, maxBytes: Int = 1000, now: Double = 100
    ) -> HeartbeatDiff.Input {
        HeartbeatDiff.Input(
            frontmost: app,
            context: app.map { FocusedContext(app: $0, window: window, element: element) },
            allowlist: allow, recordOtherApps: others, maxValueBytes: maxBytes, now: now)
    }

    @Test func firstAllowedAppActivatesAndSnapshots() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "Apple", url: "https://apple.com")))
        #expect(out.events.map(\.kind) == [.appActivated, .contextSnapshot])
        #expect(out.events[0].bundleID == "com.apple.Safari")
        #expect(out.events[0].extra?["allowlisted"] == true)
        #expect(out.events[1].windowTitle == "Apple")
        #expect(out.events[1].url == "https://apple.com")
        #expect(out.events[1].extra?["reason"] == "heartbeat")
        #expect(out.events.allSatisfy { $0.ts == 100 })
        #expect(out.state.frontmost == safari)
        #expect(out.state.signature?.windowTitle == "Apple")
    }

    @Test func unchangedContextEmitsNothing() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, window: WindowInfo(title: "Apple")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(safari, window: WindowInfo(title: "Apple"), now: 105))
        #expect(second.events.isEmpty)
        #expect(second.state == first.state)
    }

    @Test func titleChangeSnapshotsWithoutRepeatingUnchangedValue() {
        let element = ElementInfo(role: "AXTextArea", value: "same text")
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(textEdit, window: WindowInfo(title: "a.md"), element: element))
        #expect(first.events[1].value == "same text")
        #expect(first.events[1].extra?["valueHash"] == .string(Hashing.sha256Hex("same text")))

        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(textEdit, window: WindowInfo(title: "a.md — Edited"), element: element))
        #expect(second.events.map(\.kind) == [.contextSnapshot])
        #expect(second.events[0].value == nil)
        #expect(second.events[0].extra?["valueUnchanged"] == true)
        #expect(second.events[0].windowTitle == "a.md — Edited")
    }

    @Test func valueChangeSnapshotsWithNewValueAndHash() {
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(textEdit, element: ElementInfo(role: "AXTextArea", value: "v1")))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(textEdit, element: ElementInfo(role: "AXTextArea", value: "v2")))
        #expect(second.events.count == 1)
        #expect(second.events[0].value == "v2")
        #expect(second.events[0].extra?["valueHash"] == .string(Hashing.sha256Hex("v2")))
        #expect(second.events[0].extra?["truncated"] == false)
        #expect(second.events[0].extra?["length"] == 2)
    }

    @Test func appSwitchWithMatchingEmptyValueIsNotTreatedAsUnchanged() {
        let element = ElementInfo(role: "AXTextArea", value: "")
        let first = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, element: element))
        let second = HeartbeatDiff.compute(
            previous: first.state, input: input(textEdit, element: element))
        #expect(second.events.map(\.kind) == [.appDeactivated, .appActivated, .contextSnapshot])
        #expect(second.events[2].value == "")
        #expect(second.events[2].extra?["valueUnchanged"] == nil)

        let third = HeartbeatDiff.compute(
            previous: second.state,
            input: input(textEdit, window: WindowInfo(title: "a.md"), element: element))
        #expect(third.events.map(\.kind) == [.contextSnapshot])
        #expect(third.events[0].value == nil)
        #expect(third.events[0].extra?["valueUnchanged"] == true)
    }

    @Test func switchingBetweenAllowedAppsDeactivatesAndActivates() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(previous: first.state, input: input(textEdit))
        #expect(second.events.map(\.kind) == [.appDeactivated, .appActivated, .contextSnapshot])
        #expect(second.events[0].bundleID == "com.apple.Safari")
        #expect(second.events[1].bundleID == "com.apple.TextEdit")
    }

    @Test func leavingToOtherAppIsInvisibleByDefault() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(previous: first.state, input: input(finder))
        #expect(second.events.map(\.kind) == [.appDeactivated])
        #expect(second.state.frontmost == finder)
        #expect(second.state.signature == nil)
        let third = HeartbeatDiff.compute(previous: second.state, input: input(finder, now: 110))
        #expect(third.events.isEmpty)
    }

    @Test func recordOtherAppsAddsBareActivation() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(
            previous: first.state,
            input: input(finder, window: WindowInfo(title: "Desktop"), others: true))
        #expect(second.events.map(\.kind) == [.appDeactivated, .appActivated])
        #expect(second.events[1].bundleID == "com.apple.finder")
        #expect(second.events[1].windowTitle == nil)
        #expect(second.events[1].extra?["allowlisted"] == false)
    }

    @Test func secureFieldSnapshotHasNoText() {
        let element = ElementInfo(role: "AXTextField", subrole: "AXSecureTextField", value: "pw")
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(), input: input(safari, element: element))
        let snapshot = out.events[1]
        #expect(snapshot.value == nil)
        #expect(snapshot.selectedText == nil)
        #expect(snapshot.subrole == "AXSecureTextField")
        #expect(snapshot.extra?["valueHash"] == nil)
    }

    @Test func noFrontmostAppClearsState() {
        let first = HeartbeatDiff.compute(previous: LastKnownState(), input: input(safari))
        let second = HeartbeatDiff.compute(previous: first.state, input: input(nil))
        #expect(second.events.map(\.kind) == [.appDeactivated])
        #expect(second.state.frontmost == nil)
    }

    @Test func snapshotCarriesTextSource() {
        let element = ElementInfo(role: "AXWebArea", value: "page body")
        var el = element
        el.textSource = "subtree"
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(safari, window: WindowInfo(title: "Apple"), element: el))
        let snapshot = out.events.first { $0.kind == .contextSnapshot }
        #expect(snapshot?.extra?["textSource"] == "subtree")
        #expect(snapshot?.value == "page body")
    }

    @Test func snapshotOmitsTextSourceWhenAbsent() {
        let out = HeartbeatDiff.compute(
            previous: LastKnownState(),
            input: input(
                safari, window: WindowInfo(title: "Apple"),
                element: ElementInfo(role: "AXGroup")))
        let snapshot = out.events.first { $0.kind == .contextSnapshot }
        #expect(snapshot?.extra?["textSource"] == nil)
    }
}
