import Testing

@testable import Capture

@Suite struct TitleNormalizerTests {
    @Test func stripsLeadingNotificationCounter() {
        #expect(
            TitleNormalizer.normalize("(86) Indiana State Sycamores") == "Indiana State Sycamores")
        #expect(TitleNormalizer.normalize("(1) Inbox") == "Inbox")
    }

    @Test func stripsStatusGlyphs() {
        #expect(
            TitleNormalizer.normalize("◑ Set up DGX Sparks hardware")
                == "Set up DGX Sparks hardware")
        #expect(
            TitleNormalizer.normalize("◐ Set up DGX Sparks hardware")
                == "Set up DGX Sparks hardware")
        #expect(
            TitleNormalizer.normalize("✳ cmux session event query") == "cmux session event query")
    }

    @Test func stripsChromeBadgesButKeepsTheAppSuffix() {
        let raw =
            "(86) Highlights | FOX College Football - YouTube - Audio playing"
            + " - High memory usage - 807 MB - Google Chrome - Pragan"
        #expect(
            TitleNormalizer.normalize(raw)
                == "Highlights | FOX College Football - YouTube - Google Chrome - Pragan")
        #expect(
            TitleNormalizer.normalize(
                "Docs - Muted - High memory usage - 1.0 GB - Google Chrome - Pragan")
                == "Docs - Google Chrome - Pragan")
        #expect(
            TitleNormalizer.normalize("New Tab - Google Chrome - Pragan")
                == "New Tab - Google Chrome - Pragan")
    }

    @Test func keepsMeaningfulState() {
        #expect(TitleNormalizer.normalize("notes.md — Edited") == "notes.md — Edited")
    }

    @Test func collapsesWhitespaceAndIsIdempotent() {
        #expect(TitleNormalizer.normalize("  a   b \t c ") == "a b c")
        let once = TitleNormalizer.normalize("(3) ◐  Foo - Audio playing - Google Chrome - Pragan")
        #expect(TitleNormalizer.normalize(once) == once)
        #expect(TitleNormalizer.normalize(nil as String?) == nil)
    }
}
