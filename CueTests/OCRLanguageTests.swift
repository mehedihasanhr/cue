import XCTest

/// How a language is named, and which engines know it.
final class OCRLanguageTests: XCTestCase {
    func testTheBaseSubtagIsWhatPacksAreKeyedBy() {
        XCTAssertEqual(OCRLanguage("bn-BD").base, "bn")
        XCTAssertEqual(OCRLanguage("bn-IN").base, "bn")
        XCTAssertEqual(OCRLanguage("bn").base, "bn")
        XCTAssertEqual(OCRLanguage("en-US").base, "en")
    }

    func testEveryDialectOfALanguageFindsTheSamePack() {
        XCTAssertEqual(OCRLanguage("bn-BD").tesseractCode, "ben")
        XCTAssertEqual(OCRLanguage("bn-IN").tesseractCode, "ben")
        XCTAssertEqual(OCRLanguage("hi-IN").tesseractCode, "hin")
        XCTAssertEqual(OCRLanguage("en-GB").tesseractCode, "eng")
    }

    func testALanguageWithNoPackHasNoCode() {
        XCTAssertNil(OCRLanguage("zz-ZZ").tesseractCode)
        XCTAssertNil(OCRLanguage("fi-FI").tesseractCode, "Vision reads Finnish; Cue ships no pack for it")
    }

    func testALanguageIsNamedInBothDirections() {
        let bangla = OCRLanguage("bn-BD")
        // macOS calls it "Bangla", which is what a Bangla reader expects to see.
        XCTAssertEqual(bangla.displayName, "Bangla")
        XCTAssertEqual(bangla.nativeName, "বাংলা")
        XCTAssertEqual(bangla.script, .bengali)
    }

    func testAnUnnameableTagFallsBackToItself() {
        XCTAssertEqual(OCRLanguage("zz-ZZ").displayName, "zz-ZZ")
    }

    // MARK: - Catalogue

    func testVisionsListComesFromTheOSAndHasEnglishInIt() {
        XCTAssertFalse(OCRLanguageCatalog.vision.isEmpty)
        XCTAssertTrue(OCRLanguageCatalog.vision.contains(OCRLanguage("en-US")))
    }

    /// The gap this feature exists to close, stated as a test. If Apple ever ships a
    /// Bengali model this fails, and the Tesseract path becomes optional.
    func testVisionHasDevanagariButNotBengali() {
        let scripts = Set(OCRLanguageCatalog.vision.map(\.script))
        XCTAssertTrue(scripts.contains(.devanagari), "Vision has Hindi and Marathi")
        XCTAssertFalse(scripts.contains(.bengali), "Vision has never shipped a Bengali model")
    }

    func testTheCatalogueOffersBanglaEvenThoughVisionDoesNot() {
        XCTAssertTrue(OCRLanguageCatalog.all.contains(OCRLanguage("bn-BD")))
        XCTAssertFalse(OCRLanguageCatalog.isVisionSupported(OCRLanguage("bn-BD")))
    }

    func testTheCatalogueIsDeduplicatedAndSorted() {
        let tags = OCRLanguageCatalog.all.map(\.tag)
        XCTAssertEqual(tags.count, Set(tags).count, "a language both engines read should appear once")
        XCTAssertEqual(OCRLanguageCatalog.all, OCRLanguageCatalog.all.sorted())
    }

    func testEnglishIsReadableByBothEnginesAndBanglaByOne() {
        XCTAssertEqual(OCRLanguageCatalog.engines(for: OCRLanguage("en-US")), [.vision, .tesseract, .cloud])
        XCTAssertEqual(OCRLanguageCatalog.engines(for: OCRLanguage("bn-BD")), [.tesseract, .cloud])
        XCTAssertEqual(OCRLanguageCatalog.engines(for: OCRLanguage("fi-FI")), [.vision, .cloud])
    }

    // MARK: - Packs

    func testEveryPackIsNamedConsistently() {
        for pack in TesseractLanguagePacks.all {
            XCTAssertEqual(TesseractLanguagePacks.code(forBase: OCRLanguage(pack.tag).base), pack.code)
            XCTAssertGreaterThan(pack.bytes, 0)
            XCTAssertEqual(pack.sha256.count, 64, "\(pack.code) needs a full SHA-256")
            XCTAssertNotNil(TesseractLanguagePacks.downloadURL(for: pack.code))
        }
    }

    func testThePackURLPointsAtAPinnedRelease() {
        let url = TesseractLanguagePacks.downloadURL(for: "ben")?.absoluteString
        XCTAssertEqual(url, "https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/4.1.0/ben.traineddata")
        XCTAssertFalse(url?.contains("/main/") ?? true, "a branch could change under the checksums")
    }

    func testThePackFileSitsWhereTesseractWillLookForIt() {
        let folder = URL(fileURLWithPath: "/tmp/tessdata", isDirectory: true)
        XCTAssertEqual(TesseractLanguagePacks.fileURL(for: "ben", in: folder).path, "/tmp/tessdata/ben.traineddata")
    }
}
