import Foundation
import Testing
@testable import RecordKit

/// An iPhone or iPad as a target, and the wire format every target keeps.
struct DeviceTargetTests {
    private func decode(_ json: String) throws -> RecordingRequest.Target {
        try JSONDecoder().decode(RecordingRequest.Target.self, from: Data(json.utf8))
    }

    @Test func aDeviceTargetSurvivesEncoding() throws {
        let request = RecordingRequest(target: .device(uniqueID: "00008110-000A1B2C3D4E"))
        let decoded = try JSONDecoder().decode(RecordingRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.target == .device(uniqueID: "00008110-000A1B2C3D4E"))
    }

    /// The hand-written coding must write exactly what the synthesised one did, or every
    /// request a host already on disk — and every host already shipped — stops being read.
    @Test func theOlderTargetsKeepTheirWireFormat() throws {
        #expect(try decode(#"{"display":{"_0":7}}"#) == .display(7))
        #expect(try decode(#"{"window":{"_0":42}}"#) == .window(42))
        #expect(try decode(#"{"ask":{}}"#) == .ask)
        #expect(try decode(#"{"area":{"display":1,"rect":[[10,20],[300,200]]}}"#)
                == .area(display: 1, rect: CGRect(x: 10, y: 20, width: 300, height: 200)))

        let written = String(decoding: try JSONEncoder().encode(RecordingRequest.Target.display(7)), as: UTF8.self)
        #expect(written == #"{"display":{"_0":7}}"#)
    }

    /// A kind of target this build has never heard of is "ask me", not a dropped request.
    @Test func anUnknownTargetReadsAsAsk() throws {
        #expect(try decode(#"{"hologram":{"_0":1}}"#) == .ask)
        #expect(try decode(#""something else""#) == .ask)

        // And inside a whole request, which is where it would actually arrive.
        let json = #"{"target":{"vision":{"id":"x"}},"microphone":true,"systemAudio":false,"webcam":false,"countdownSeconds":3,"opensEditorWhenFinished":false,"correlationID":"8F7C1D0E-35A4-4B8A-9C3E-2B7A4C2E1F00"}"#
        let request = try JSONDecoder().decode(RecordingRequest.self, from: Data(json.utf8))
        #expect(request.target == .ask)
        #expect(request.microphone)
    }
}
