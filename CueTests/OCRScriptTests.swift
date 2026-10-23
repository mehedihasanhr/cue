import XCTest

/// Telling one alphabet from another — the check that stops Bangla being copied as
/// Devanagari.
final class OCRScriptTests: XCTestCase {
    private let bangla = "আমি বাংলায় গান গাই"
    /// What Vision actually returns when shown the line above, at confidence 1.00.
    private let devanagari = "प्यामि वाश्लाय जान तारे"

    // MARK: - Tags

    func testATagResolvesToItsScript() {
        XCTAssertEqual(OCRScript(tag: "bn-BD"), .bengali)
        XCTAssertEqual(OCRScript(tag: "bn"), .bengali)
        XCTAssertEqual(OCRScript(tag: "hi-IN"), .devanagari)
        XCTAssertEqual(OCRScript(tag: "mr-IN"), .devanagari)
        XCTAssertEqual(OCRScript(tag: "en-US"), .latin)
        XCTAssertEqual(OCRScript(tag: "ar-SA"), .arabic)
        XCTAssertEqual(OCRScript(tag: "th-TH"), .thai)
    }

    func testAnUnknownTagHasNoScript() {
        XCTAssertEqual(OCRScript(tag: "zz-ZZ"), .other)
    }

    func testArabicAndHebrewReadRightToLeft() {
        XCTAssertTrue(OCRScript.arabic.isRightToLeft)
        XCTAssertTrue(OCRScript.hebrew.isRightToLeft)
        XCTAssertFalse(OCRScript.bengali.isRightToLeft)
        XCTAssertFalse(OCRScript.latin.isRightToLeft)
    }

    // MARK: - Share

    func testBanglaIsEntirelyBanglaAndNotAtAllDevanagari() {
        XCTAssertEqual(OCRScript.bengali.share(in: bangla), 1, accuracy: 0.001)
        XCTAssertEqual(OCRScript.devanagari.share(in: bangla), 0, accuracy: 0.001)
    }

    /// The bug, as an assertion: what Vision hands back for Bangla input would not
    /// pass a Bangla script check.
    func testVisionsDevanagariAnswerFailsABanglaCheck() {
        XCTAssertLessThan(OCRScript.bengali.share(in: devanagari), OCRScript.minimumShare)
        XCTAssertEqual(OCRScript.devanagari.share(in: devanagari), 1, accuracy: 0.001)
    }

    func testDigitsSpacesAndPunctuationAreIgnored() {
        // Only the letters count, so ASCII furniture cannot tip the balance.
        XCTAssertEqual(OCRScript.latin.share(in: "abc 123 -- !!"), 1, accuracy: 0.001)
        XCTAssertEqual(OCRScript.latin.share(in: "123 456 ... ,,,"), 0, accuracy: 0.001)
    }

    func testTextWithNoLettersHasNoShare() {
        XCTAssertEqual(OCRScript.bengali.share(in: "123 456"), 0, accuracy: 0.001)
        XCTAssertEqual(OCRScript.bengali.share(in: "   "), 0, accuracy: 0.001)
    }

    func testAnEnglishButtonOnABanglaScreenStillPasses() {
        // The threshold is forgiving on purpose: mixed UI is normal, wrong-alphabet
        // output is not.
        let mixed = bangla + " Save"
        XCTAssertGreaterThan(OCRScript.bengali.share(in: mixed), OCRScript.minimumShare)
    }

    // MARK: - Dominant

    func testDominantScript() {
        XCTAssertEqual(OCRScript.dominant(in: bangla), .bengali)
        XCTAssertEqual(OCRScript.dominant(in: devanagari), .devanagari)
        XCTAssertEqual(OCRScript.dominant(in: "Hello there"), .latin)
    }

    func testDominantOfNothingIsNil() {
        XCTAssertNil(OCRScript.dominant(in: "123 !!"))
        XCTAssertNil(OCRScript.dominant(in: ""))
    }

    /// Digits belong to no alphabet, not even their own block's.
    ///
    /// Bengali and Devanagari each have their own digits, and a recogniser that
    /// cannot read a page returns strings of them. Counting those as evidence of the
    /// script would wave exactly the wrong answers through — observed: the Bengali
    /// model, shown English, answers "০091 ও৩9101705 ৪170 00096".
    func testDigitsAreNotEvidenceOfAScript() {
        XCTAssertNil(OCRScript.dominant(in: "১২৩"))
        XCTAssertEqual(OCRScript.letterCount(in: "১২৩ 456"), 0)
        XCTAssertEqual(OCRScript.bengali.share(in: "১২৩"), 0, accuracy: 0.001)
    }

    func testIndicVowelSignsCountAsLetters() {
        // Matras are marks rather than letters, but they are certainly writing.
        XCTAssertGreaterThan(OCRScript.letterCount(in: "কী"), 1)
    }

    func testThereIsAFloorBelowWhichNothingIsJudged() {
        XCTAssertLessThan(OCRScript.letterCount(in: "ও৩"), OCRScript.minimumLettersToJudge)
        XCTAssertGreaterThanOrEqual(OCRScript.letterCount(in: bangla), OCRScript.minimumLettersToJudge)
    }

    /// Devanagari is the one answer worth querying, because it is what a recogniser
    /// with no Bengali model produces from Bangla.
    func testDevanagariSuggestsBanglaAndNothingElseDoes() {
        XCTAssertEqual(OCRScript.possiblyIntended(whenAnsweredIn: .devanagari), .bengali)
        XCTAssertNil(OCRScript.possiblyIntended(whenAnsweredIn: .latin))
        XCTAssertNil(OCRScript.possiblyIntended(whenAnsweredIn: .bengali))
    }
}
