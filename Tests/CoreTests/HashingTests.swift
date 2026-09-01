import Testing

@testable import Core

@Suite struct HashingTests {
    @Test func sha256OfKnownString() {
        #expect(
            Hashing.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Hashing.sha256Hex("").count == 64)
    }
}
