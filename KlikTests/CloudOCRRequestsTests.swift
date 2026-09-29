import XCTest

/// Building requests for a cloud recogniser and reading its answers. No network and
/// no key — everything here is a pure transformation.
final class CloudOCRRequestsTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])
    private let bangla = [OCRLanguage("bn-BD")]

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Google

    func testTheGoogleRequestAsksForDenseTextAndHintsTheLanguage() throws {
        let request = try CloudOCRRequests.googleRequest(png: png, languages: bangla, secret: "abc123")
        let json = try body(of: request)
        let first = try XCTUnwrap((json["requests"] as? [[String: Any]])?.first)

        let features = try XCTUnwrap(first["features"] as? [[String: Any]])
        XCTAssertEqual(features.first?["type"] as? String, "DOCUMENT_TEXT_DETECTION")

        let context = try XCTUnwrap(first["imageContext"] as? [String: Any])
        XCTAssertEqual(context["languageHints"] as? [String], ["bn-BD"])

        let image = try XCTUnwrap(first["image"] as? [String: Any])
        XCTAssertEqual(image["content"] as? String, png.base64EncodedString())
    }

    /// The key belongs in the query string for this API — and must not also end up in
    /// the body, where it would be logged by anything that logs request bodies.
    func testTheGoogleKeyGoesInTheQueryAndNowhereElse() throws {
        let request = try CloudOCRRequests.googleRequest(png: png, languages: bangla, secret: "abc123")
        XCTAssertEqual(request.url?.absoluteString.contains("key=abc123"), true)
        let raw = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(raw.contains("abc123"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// Google measures pixels down from the top left; everything downstream expects a
    /// normalised box measured up from the bottom left. Get this wrong and the lines
    /// silently come out in the wrong order.
    func testTheBoxIsFlippedAndNormalised() throws {
        let box: [String: Any] = ["vertices": [
            ["x": 10, "y": 20], ["x": 110, "y": 20], ["x": 110, "y": 60], ["x": 10, "y": 60],
        ]]
        let rect = try XCTUnwrap(CloudOCRRequests.boundingBox(from: box, imageSize: CGSize(width: 200, height: 100)))
        XCTAssertEqual(rect.minX, 0.05, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 0.4, accuracy: 0.0001)
        // The top of the box was 20 px down, so in a 100 px image its maxY is 0.8.
        XCTAssertEqual(rect.maxY, 0.8, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 0.4, accuracy: 0.0001)
    }

    func testABoxWithoutVerticesIsNil() {
        XCTAssertNil(CloudOCRRequests.boundingBox(from: nil, imageSize: CGSize(width: 10, height: 10)))
        XCTAssertNil(CloudOCRRequests.boundingBox(from: ["vertices": []], imageSize: CGSize(width: 10, height: 10)))
    }

    func testGoogleParagraphsBecomeItems() throws {
        let answer = """
        {"responses":[{"fullTextAnnotation":{"pages":[{"blocks":[{"paragraphs":[
          {"confidence":0.97,
           "boundingBox":{"vertices":[{"x":0,"y":0},{"x":100,"y":0},{"x":100,"y":50},{"x":0,"y":50}]},
           "words":[{"symbols":[{"text":"আ"},{"text":"মি"}]},{"symbols":[{"text":"বাং"},{"text":"লা"}]}]}
        ]}]}]}}]}
        """
        let items = try CloudOCRRequests.parseGoogle(Data(answer.utf8), imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "আমি বাংলা")
        XCTAssertEqual(items.first?.confidence ?? 0, 0.97, accuracy: 0.001)
    }

    func testAnEmptyGoogleAnswerIsNoTextRatherThanAnError() throws {
        let items = try CloudOCRRequests.parseGoogle(Data(#"{"responses":[{}]}"#.utf8), imageSize: CGSize(width: 10, height: 10))
        XCTAssertTrue(items.isEmpty)
    }

    func testGooglesOwnErrorIsPassedOnInWords() {
        let answer = #"{"error":{"message":"API key not valid"}}"#
        XCTAssertThrowsError(try CloudOCRRequests.parseGoogle(Data(answer.utf8), imageSize: .zero)) { error in
            XCTAssertEqual((error as? CloudOCRRequests.Failure)?.errorDescription, "API key not valid")
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try CloudOCRRequests.parseGoogle(Data("not json".utf8), imageSize: .zero))
        XCTAssertThrowsError(try CloudOCRRequests.parseModel(Data("not json".utf8)))
    }

    // MARK: - A vision model

    func testTheModelRequestCarriesTheImageAndNamesTheLanguage() throws {
        let configuration = CloudOCRConfiguration(provider: .model, secret: "sk-test",
                                                  endpoint: "https://example.com/v1/chat/completions",
                                                  model: "some-model")
        let request = try CloudOCRRequests.modelRequest(png: png, languages: bangla, configuration: configuration)
        XCTAssertEqual(request.url?.absoluteString, configuration.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let json = try body(of: request)
        XCTAssertEqual(json["model"] as? String, "some-model")
        let content = try XCTUnwrap((json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        let instruction = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(instruction.contains("Bangla"), "the model should be told which language; got: \(instruction)")
        let image = try XCTUnwrap(content.last?["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, "data:image/png;base64,\(png.base64EncodedString())")
    }

    func testABadEndpointIsRejectedBeforeAnythingIsSent() {
        let configuration = CloudOCRConfiguration(provider: .model, secret: "sk", endpoint: "", model: "m")
        XCTAssertThrowsError(try CloudOCRRequests.modelRequest(png: png, languages: bangla, configuration: configuration))
    }

    /// A model answers in prose, so the whole reply becomes one item covering the
    /// image. `TextLayout` then passes it through unchanged.
    func testAModelsAnswerBecomesOneItemSpanningTheImage() throws {
        let answer = #"{"choices":[{"message":{"content":"আমি বাংলায় গান গাই"}}]}"#
        let items = try CloudOCRRequests.parseModel(Data(answer.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "আমি বাংলায় গান গাই")
        XCTAssertEqual(items.first?.boundingBox, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(TextLayout.compose(items), "আমি বাংলায় গান গাই")
    }

    func testAnAnthropicShapedAnswerIsAlsoUnderstood() throws {
        let answer = #"{"content":[{"type":"text","text":"Hello Klik"}]}"#
        XCTAssertEqual(try CloudOCRRequests.parseModel(Data(answer.utf8)).first?.text, "Hello Klik")
    }

    func testAnEmptyModelAnswerIsNoText() throws {
        XCTAssertTrue(try CloudOCRRequests.parseModel(Data(#"{"choices":[{"message":{"content":"  "}}]}"#.utf8)).isEmpty)
    }

    // MARK: - Usage

    func testUsageIsReadFromEitherWireShape() {
        let openAI = #"{"usage":{"prompt_tokens":1200,"completion_tokens":340}}"#
        XCTAssertEqual(CloudOCRRequests.usage(Data(openAI.utf8)), CloudOCRRequests.Usage(input: 1200, output: 340))
        let anthropic = #"{"usage":{"input_tokens":1200,"output_tokens":340}}"#
        XCTAssertEqual(CloudOCRRequests.usage(Data(anthropic.utf8)), CloudOCRRequests.Usage(input: 1200, output: 340))
    }

    /// Google Cloud Vision bills per image and reports no tokens; that is not an error.
    func testAnAnswerWithNoUsageIsNil() {
        XCTAssertNil(CloudOCRRequests.usage(Data(#"{"responses":[{}]}"#.utf8)))
        XCTAssertNil(CloudOCRRequests.usage(Data("not json".utf8)))
    }
}
