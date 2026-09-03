import Testing

@testable import Capture

@Suite struct SecretRedactorTests {
    private func redact(_ text: String, entropy: Bool = true) -> RedactionResult {
        SecretRedactor.redact(text, entropyEnabled: entropy)
    }

    @Test func redactsStructuralSecretShapes() {
        let cases: [(String, String)] = [
            ("AKIAQQQQWWWWEEEERRRR", "aws-key"),
            ("ghp_aaaabbbbccccddddeeeeffffgggghhhh1111", "github-token"),
            ("sk_live_" + "aaaabbbbccccddddeeeeffff", "stripe-key"),
            ("xoxb-" + "1111111111-2222222222-aaaabbbbccccdddd", "slack-token"),
            ("AIzaSyAAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIII", "google-api-key"),
            ("sk-ant-api03-aaaabbbbccccddddeeeeffffgggghhhh", "anthropic-key"),
        ]
        for (secret, rule) in cases {
            let result = redact("token is \(secret) ok")
            #expect(result.rules == [rule], "\(rule)")
            #expect(!result.text.contains(secret), "\(rule) leaked")
            #expect(result.text.contains("[redacted:\(rule)]"), "\(rule)")
            #expect(result.text.hasPrefix("token is "), "\(rule) mangled context")
        }
    }

    @Test func redactsPrivateKeyBlocksAndJWTs() {
        let pem = """
            -----BEGIN RSA PRIVATE KEY-----
            AAAABBBBCCCCDDDDEEEEFFFFGGGG
            -----END RSA PRIVATE KEY-----
            """
        let pemResult = redact("before\n\(pem)\nafter")
        #expect(pemResult.rules == ["private-key-block"])
        #expect(!pemResult.text.contains("AAAABBBBCCCCDDDDEEEEFFFFGGGG"))
        #expect(pemResult.text.contains("before"))
        #expect(pemResult.text.contains("after"))

        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.aaaabbbbccccddddeeeeffff"
        let jwtResult = redact("Authorization: \(jwt)")
        #expect(jwtResult.rules.contains("jwt"))
        #expect(!jwtResult.text.contains(jwt))
    }

    @Test func redactsAssignmentsAndConnectionStrings() {
        let assignment = redact("api_key = s3cretVALUE123456")
        #expect(assignment.rules.contains("assignment-secret"))
        #expect(!assignment.text.contains("s3cretVALUE123456"))

        let conn = redact("postgres://appuser:hunter2hunter2@db.internal:5432/app")
        #expect(conn.rules.contains("connection-string"))
        #expect(!conn.text.contains("hunter2hunter2"))
    }

    @Test func entropyBackstopCatchesUnknownShapes() {
        let token = "Xq7Lm2Rt9Zw4Kp1Bn6Vc3Hs8Ja5Ye0Ud"  // mixed case + digits, 32 chars
        let on = redact("value: \(token)")
        #expect(on.rules == ["high-entropy"])
        #expect(!on.text.contains(token))
        let off = redact("value: \(token)", entropy: false)
        #expect(off.rules.isEmpty)
        #expect(off.text.contains(token))
    }

    @Test func leavesOrdinaryTextAlone() {
        let negatives = [
            "Skip to main content / Machines / Apps / Services / DNS / Users",
            "https://github.com/OpenRhyme/OpenRhyme/tree/docs/gtm-product-spec/gtm",
            "/Users/pragadeesh/Developer/OpenRhyme/OpenRhyme/Sources/Capture/AXClient.swift",
            "The quick brown fox jumps over the lazy dog and keeps running onward",
            "550e8400-e29b-41d4-a716-446655440000",
            "abd7fc7d558062550e87c0af48257ae5bd62ebf5",
            "Password",
        ]
        for text in negatives {
            let result = redact(text)
            #expect(result.rules.isEmpty, "false positive on: \(text)")
            #expect(result.text == text, "mutated: \(text)")
        }
    }

    @Test func handlesSeveralSecretsAndIsIdempotent() {
        let text = "a AKIAQQQQWWWWEEEERRRR b ghp_aaaabbbbccccddddeeeeffffgggghhhh1111 c"
        let once = redact(text)
        #expect(once.rules == ["aws-key", "github-token"])  // sorted, de-duplicated
        let twice = redact(once.text)
        #expect(twice.text == once.text)
        #expect(twice.rules.isEmpty)
    }

    @Test func emptyAndShortInputsAreSafe() {
        #expect(redact("") == RedactionResult(text: "", rules: []))
        #expect(redact("hi").rules.isEmpty)
    }
}
