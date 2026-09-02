import Testing

@testable import Capture

/// In-memory TextNode for testing the ladder without AX.
private struct Node: TextNode {
    var role: String?
    var subrole: String?
    var value: String?
    var ranged: String?
    var kids: [Node] = []
    var throwsOnValue = false

    func ownValue() throws -> String? {
        if throwsOnValue { throw AXReadError.cannotComplete }
        return value
    }
    func rangedText() throws -> String? { ranged }
    func children() throws -> [TextNode] { kids }
}

@Suite struct ContentExtractorTests {
    @Test func rung1OwnValueWins() {
        let n = Node(role: "AXTextArea", value: "typed text", ranged: "should not be used")
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: "typed text", source: .value))
    }

    @Test func rung2RangedTextWhenValueEmpty() {
        let n = Node(role: "AXWebArea", value: nil, ranged: "visible page text")
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: "visible page text", source: .range))
    }

    @Test func rung3SubtreeHarvestWhenValueAndRangeEmpty() {
        let n = Node(
            role: "AXWebArea", value: nil, ranged: nil,
            kids: [
                Node(role: "AXHeading", value: "Title"),
                Node(
                    role: "AXGroup", value: nil,
                    kids: [Node(role: "AXStaticText", value: "Body line")]),
                Node(role: "AXLink", value: "a link"),
            ])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r.source == .subtree)
        #expect(r.value == "Title\nBody line\na link")
    }

    @Test func harvestSkipsSecureFields() {
        let n = Node(
            role: "AXGroup", value: nil, ranged: nil,
            kids: [
                Node(role: "AXStaticText", value: "Username"),
                Node(role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2"),
                Node(role: "AXStaticText", value: "Sign in"),
            ])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r.value == "Username\nSign in")
        #expect(!(r.value ?? "").contains("hunter2"))
    }

    @Test func focusedSecureFieldYieldsNothing() {
        let n = Node(
            role: "AXTextField", subrole: "AXSecureTextField", value: "hunter2", ranged: "hunter2")
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: nil, source: nil))
    }

    @Test func nodeBudgetStopsTheWalk() {
        // 10 text children but a budget of 3 nodes (root + 2 harvested).
        let kids = (0..<10).map { Node(role: "AXStaticText", value: "L\($0)") }
        let n = Node(role: "AXGroup", value: nil, ranged: nil, kids: kids)
        let r = ContentExtractor.extract(from: n, maxBytes: 10000, nodeBudget: 3)
        // Budget-bounded: fewer than all 10 lines captured, no crash.
        #expect((r.value ?? "").split(separator: "\n").count < 10)
    }

    @Test func byteCapStopsAccumulation() {
        let kids = (0..<100).map { _ in
            Node(role: "AXStaticText", value: String(repeating: "x", count: 100))
        }
        let n = Node(role: "AXGroup", value: nil, ranged: nil, kids: kids)
        let r = ContentExtractor.extract(from: n, maxBytes: 250)
        #expect((r.value ?? "").utf8.count <= 250)
        #expect(r.source == .subtree)
    }

    @Test func emptyEverywhereYieldsNothing() {
        let n = Node(
            role: "AXGroup", value: nil, ranged: nil, kids: [Node(role: "AXImage", value: nil)])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r == ExtractedText(value: nil, source: nil))
    }

    @Test func aThrowingNodeDoesNotAbortTheWalk() {
        let n = Node(
            role: "AXGroup", value: nil, ranged: nil,
            kids: [
                Node(role: "AXStaticText", value: "before", throwsOnValue: true),
                Node(role: "AXStaticText", value: "after"),
            ])
        let r = ContentExtractor.extract(from: n, maxBytes: 1000)
        #expect(r.value == "after")
    }
}
