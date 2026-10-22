import XCTest

/// Turning what is stored in the preferences into what it means.
final class OCRSettingsTests: XCTestCase {
    // MARK: - Languages

    /// An empty list is what every existing install has, because the key has never
    /// been written. It has to mean "carry on as before".
    func testNothingStoredMeansAutomatic() {
        XCTAssertEqual(OCRPreferenceCodec.selection(fromTags: []), .automatic)
    }

    func testLanguagesRoundTripInOrder() {
        let tags = ["bn-BD", "en-US"]
        let selection = OCRPreferenceCodec.selection(fromTags: tags)
        XCTAssertEqual(selection, .languages([OCRLanguage("bn-BD"), OCRLanguage("en-US")]))
        XCTAssertEqual(selection.primary, OCRLanguage("bn-BD"))
        XCTAssertEqual(OCRPreferenceCodec.tags(for: selection), tags)
    }

    func testAnUnknownTagIsDroppedWithoutLosingTheRest() {
        let selection = OCRPreferenceCodec.selection(fromTags: ["bn-BD", "zz-ZZ"])
        XCTAssertEqual(selection.languages, [OCRLanguage("bn-BD")])
    }

    func testATagNothingCanReadFallsBackToAutomaticRatherThanBreaking() {
        XCTAssertEqual(OCRPreferenceCodec.selection(fromTags: ["zz-ZZ"]), .automatic)
    }

    // MARK: - Cloud

    func testTheCloudIsNilUnlessItIsBothOnAndUsable() {
        XCTAssertNil(OCRPreferenceCodec.cloud(enabled: false, provider: "google", secret: "abc", endpoint: "", model: ""))
        XCTAssertNil(OCRPreferenceCodec.cloud(enabled: true, provider: "google", secret: "", endpoint: "", model: ""),
                     "a provider without a key is not configured")
        XCTAssertNil(OCRPreferenceCodec.cloud(enabled: true, provider: "google", secret: "   ", endpoint: "", model: ""))
        XCTAssertNotNil(OCRPreferenceCodec.cloud(enabled: true, provider: "google", secret: "abc", endpoint: "", model: ""))
    }

    func testAModelProviderAlsoNeedsSomewhereToSendIt() {
        XCTAssertNil(OCRPreferenceCodec.cloud(enabled: true, provider: "model", secret: "abc", endpoint: "", model: ""))
        XCTAssertNil(OCRPreferenceCodec.cloud(enabled: true, provider: "model", secret: "abc",
                                              endpoint: "https://example.com", model: ""))
        XCTAssertNotNil(OCRPreferenceCodec.cloud(enabled: true, provider: "model", secret: "abc",
                                                 endpoint: "https://example.com", model: "some-model"))
    }

    func testAnUnrecognisedProviderNameDoesNotDisableTheCloud() {
        let cloud = OCRPreferenceCodec.cloud(enabled: true, provider: "nonsense", secret: "abc", endpoint: "", model: "")
        XCTAssertEqual(cloud?.provider, .google)
    }

    // MARK: - Indexing

    /// The library index is never shown to anyone, so it guesses rather than refuses.
    func testTheIndexNeverUsesTheCloudAndNeverRefuses() {
        var settings = OCRSettings()
        settings.selection = .languages([OCRLanguage("bn-BD")])
        settings.cloud = CloudOCRConfiguration(provider: .google, secret: "abc")
        settings.preferCloud = true
        settings.checksScript = true

        let indexing = settings.forIndexing
        XCTAssertNil(indexing.cloud)
        XCTAssertFalse(indexing.preferCloud)
        XCTAssertFalse(indexing.checksScript)
        XCTAssertEqual(indexing.selection, settings.selection, "it still reads the right language")
    }

    func testTheDefaultSettingsAreTodaysBehaviour() {
        let settings = OCRSettings()
        XCTAssertEqual(settings.selection, .automatic)
        XCTAssertNil(settings.cloud)
        XCTAssertFalse(settings.preferCloud)
    }
}
