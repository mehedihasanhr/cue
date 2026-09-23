import XCTest

/// Who gets asked to read what.
///
/// Availability is injected, so the whole table runs without building an engine or
/// touching the network.
final class OCRRouterTests: XCTestCase {
    private let bangla = OCRLanguage("bn-BD")
    private let english = OCRLanguage("en-US")
    private let hindi = OCRLanguage("hi-IN")

    /// Vision knows its own list; the other two answer as told.
    private func availability(tesseract: OCREngineAvailability = .unsupported,
                              cloud: OCREngineAvailability = .unsupported)
    -> (OCREngineID, OCRLanguage) -> OCREngineAvailability {
        { engine, language in
            switch engine {
            case .vision: OCRLanguageCatalog.isVisionSupported(language) ? .ready : .unsupported
            case .tesseract: language.tesseractCode == nil ? .unsupported : tesseract
            case .cloud: cloud
            }
        }
    }

    private func route(_ settings: OCRSettings,
                       tesseract: OCREngineAvailability = .unsupported,
                       cloud: OCREngineAvailability = .unsupported) -> Result<OCRRoute, OCRUnavailable> {
        OCRRouter.route(settings, availability: availability(tesseract: tesseract, cloud: cloud))
    }

    private func settings(_ languages: [OCRLanguage], preferCloud: Bool = false) -> OCRSettings {
        var settings = OCRSettings()
        settings.selection = .languages(languages)
        settings.preferCloud = preferCloud
        if preferCloud { settings.cloud = CloudOCRConfiguration(provider: .google, secret: "x") }
        return settings
    }

    // MARK: - The two invariants

    /// Nobody who never opens the new setting sees any change at all.
    func testAutomaticIsExactlyWhatKlikAlwaysDid() {
        let result = route(OCRSettings())
        guard case .success(let route) = result else { return XCTFail("automatic should always route") }
        XCTAssertEqual(route.engine, .vision)
        XCTAssertTrue(route.languages.isEmpty)
        XCTAssertTrue(route.detectsLanguage)
        XCTAssertNil(route.fallback)
        XCTAssertNil(route.expectedScript)
    }

    /// The guard on the original bug: Vision is never handed a language it has no
    /// model for, as the engine it runs or as the one it falls back to.
    func testVisionIsNeverUsedForALanguageItCannotRead() {
        let unreadable = OCRLanguageCatalog.all.filter { !OCRLanguageCatalog.isVisionSupported($0) }
        XCTAssertFalse(unreadable.isEmpty, "the catalogue should offer more than Vision does")

        for language in unreadable {
            for tesseract in [OCREngineAvailability.ready, .needsDownload(bytes: 1), .unsupported] {
                for cloud in [OCREngineAvailability.ready, .needsSetup("key"), .unsupported] {
                    let result = route(settings([language]), tesseract: tesseract, cloud: cloud)
                    guard case .success(let route) = result else { continue }
                    XCTAssertNotEqual(route.engine, .vision, "\(language.tag) must not route to Vision")
                    XCTAssertNotEqual(route.fallback, .vision, "\(language.tag) must not fall back to Vision")
                    XCTAssertFalse(route.languages.contains(language) && route.engine == .vision)
                }
            }
        }
    }

    // MARK: - The table

    func testALanguageVisionKnowsGoesToVision() {
        guard case .success(let route) = route(settings([english])) else { return XCTFail("expected a route") }
        XCTAssertEqual(route.engine, .vision)
        XCTAssertEqual(route.languages, [english])
        XCTAssertFalse(route.detectsLanguage)
        XCTAssertEqual(route.expectedScript, .latin)
    }

    func testBanglaGoesToTesseractWhenItsPackIsThere() {
        guard case .success(let route) = route(settings([bangla]), tesseract: .ready) else { return XCTFail("expected a route") }
        XCTAssertEqual(route.engine, .tesseract)
        XCTAssertEqual(route.languages, [bangla])
        XCTAssertNil(route.fallback, "answering Bangla in Devanagari is the bug, not a fallback")
        XCTAssertEqual(route.expectedScript, .bengali)
    }

    func testBanglaWithNoEngineAtAllIsRefusedByName() {
        guard case .failure(let reason) = route(settings([bangla])) else { return XCTFail("expected a refusal") }
        XCTAssertEqual(reason, .noEngine(bangla))
        XCTAssertEqual(reason.errorDescription, "Klik can't read Bangla yet")
    }

    func testBanglaFallsToTheCloudWhenThereIsNoPackButAKey() {
        guard case .success(let route) = route(settings([bangla]), cloud: .ready) else { return XCTFail("expected a route") }
        XCTAssertEqual(route.engine, .cloud)
        XCTAssertNil(route.fallback)
    }

    func testAnUnconfiguredCloudSaysSoRatherThanBlamingTheLanguage() {
        guard case .failure(let reason) = route(settings([bangla]), cloud: .needsSetup("Add a key")) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, .cloudNotConfigured)
    }

    func testPreferringTheCloudOverridesVisionButKeepsItAsAFallback() {
        guard case .success(let route) = route(settings([english], preferCloud: true), cloud: .ready) else {
            return XCTFail("expected a route")
        }
        XCTAssertEqual(route.engine, .cloud)
        XCTAssertEqual(route.fallback, .vision, "Vision does read English, so it is a real fallback")
    }

    func testPreferringTheCloudWithoutAWorkingOneChangesNothing() {
        guard case .success(let route) = route(settings([english], preferCloud: true), cloud: .needsSetup("Add a key")) else {
            return XCTFail("expected a route")
        }
        XCTAssertEqual(route.engine, .vision)
    }

    func testCompanionLanguagesAreFilteredToWhatTheEngineReads() {
        // English alongside Bangla: Tesseract takes both, because once the primary is
        // Tesseract's the whole image is.
        guard case .success(let both) = route(settings([bangla, english]), tesseract: .ready) else {
            return XCTFail("expected a route")
        }
        XCTAssertEqual(both.engine, .tesseract)
        XCTAssertEqual(both.languages, [bangla, english])

        // Hindi alongside Bangla: Vision reads Hindi, but the primary decides, and it
        // is still not allowed to see Bangla.
        guard case .success(let mixed) = route(settings([hindi, bangla])) else { return XCTFail("expected a route") }
        XCTAssertEqual(mixed.engine, .vision)
        XCTAssertEqual(mixed.languages, [hindi])
    }

    func testAnRTLLanguageIsMarkedAsSuch() {
        guard case .success(let route) = route(settings([OCRLanguage("ar-SA")])) else { return XCTFail("expected a route") }
        XCTAssertEqual(route.expectedScript, .arabic)
        XCTAssertTrue(route.expectedScript?.isRightToLeft ?? false)
    }
}
