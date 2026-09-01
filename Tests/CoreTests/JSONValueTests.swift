import Foundation
import Testing

@testable import Core

@Suite struct JSONValueTests {
    @Test func roundTripsNestedStructure() throws {
        let value: JSONValue = [
            "s": "text", "n": 1.5, "i": 2, "b": true, "z": .null,
            "a": [1, "two", false], "o": ["k": "v"],
        ]
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == value)
    }

    @Test func decodesFromRawJSON() throws {
        let data = Data(#"{"a":[1,2,{"b":null}],"c":"d","e":true}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["a"]?.arrayValue?.count == 3)
        #expect(value["a"]?[2]?["b"] == .null)
        #expect(value["c"]?.stringValue == "d")
        #expect(value["e"]?.boolValue == true)
    }

    @Test func encodesIntegralNumbersWithoutFraction() throws {
        let data = try JSONEncoder().encode(JSONValue.number(5))
        #expect(String(decoding: data, as: UTF8.self) == "5")
    }
}
