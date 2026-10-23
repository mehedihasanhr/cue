import XCTest

/// What tasks look like on the wire, and how webhook bodies are signed.
final class TaskSyncTests: XCTestCase {
    func testTaskRoundTrip() throws {
        var task = TaskItem(text: "Ship it\nWith notes", projectID: nil, priority: .high)
        task.status = .review
        let data = try TaskWire.encoder.encode(RemoteTask(task))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"title\":\"Ship it\""))
        XCTAssertTrue(json.contains("\"status\":\"review\""))
        XCTAssertTrue(json.contains("\"priority\":\"high\""))
        let back = try TaskWire.decoder.decode(RemoteTask.self, from: data).item
        XCTAssertEqual(back.id, task.id)
        XCTAssertEqual(back.text, task.text)
        XCTAssertEqual(back.status, .review)
        XCTAssertEqual(back.priority, .high)
        XCTAssertEqual(back.updatedAt.timeIntervalSince1970, task.updatedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testServerMayOmitFields() throws {
        let json = #"{"tasks":[{"id":"6B0C1B5E-1F4D-4D0C-9E4B-3D2F1A2B3C4D","title":"From the server"}]}"#
        let response = try TaskWire.decoder.decode(TaskSyncResponse.self, from: Data(json.utf8))
        let task = try XCTUnwrap(response.tasks?.first).item
        XCTAssertEqual(task.title, "From the server")
        XCTAssertEqual(task.status, .pending)
        XCTAssertEqual(task.priority, .medium)
        XCTAssertNil(response.deleted)
    }

    func testSignature() {
        // HMAC-SHA256("secret", "body") — a known vector.
        XCTAssertEqual(TaskWire.signature(of: Data("body".utf8), secret: "secret"),
                       "sha256=dc46983557fea127b43af721467eb9b3fde2338fe3e14f51952aa8478c13d355")
    }
}
