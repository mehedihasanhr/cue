import AVFoundation
import Foundation
import os
import ScreenCaptureKit

/// The screen, into the writer.
///
/// One type for displays, windows and areas, because ScreenCaptureKit already models the
/// difference: it is the `SCContentFilter` that changes, plus a `sourceRect` for an area.
/// Three near-identical classes would only be three places to fix the same bug.
///
/// Frames are delivered on the writer's own queue, so a frame goes from the system
/// straight into the encoder without a hop, a copy or a `Sendable` wrapper.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: SessionWriter
    /// Where the screen's *own* sound goes — a file of its own, beside the picture rather
    /// than inside it. `nil` when this take is not capturing system audio, and that `nil`
    /// is what stops the stream ever being asked for an audio output.
    private let audio: AudioTrackWriter?
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    /// Built in `start()` rather than in `init`: `SCStream` takes its delegate at
    /// construction, and `self` is not available until after `super.init()`.
    private var stream: SCStream?
    /// Called when the stream stops on its own — a window closed, a display unplugged,
    /// the disk filled. The session decides what that means for the recording.
    private let onStop: @Sendable (RecordingError) -> Void
    /// Told where each frame's picture came from, for a recording of a window. Set before
    /// `start()` and not after: it is read on the capture queue.
    ///
    /// A window is the one target whose picture can be moved and resized inside the file
    /// while the take runs, and the frame is the only thing that knows by how much.
    public var cursorMapper: CursorMapper?
    /// Told where each frame's picture sits inside the frame, for a recording of a window.
    /// Set before `start()` and not after, like `cursorMapper`, and for the same reason.
    ///
    /// The file's size is fixed when the take starts; a window resized after that is scaled
    /// to fit and the rest of the frame is black. This is how the editor learns which part.
    public var pictureTracker: PictureTracker?

    private static let log = Logger(subsystem: "com.stackrover.cue.studio", category: "screen")

    public init(filter: SCContentFilter,
                configuration: SCStreamConfiguration,
                writer: SessionWriter,
                audio: AudioTrackWriter? = nil,
                onStop: @escaping @Sendable (RecordingError) -> Void) {
        self.writer = writer
        self.audio = audio
        self.filter = filter
        self.configuration = configuration
        self.onStop = onStop
        super.init()
    }

    /// Starts the stream. System audio is captured when this recorder was given somewhere
    /// to put it — one condition rather than two, so a stream cannot be subscribed to audio
    /// that has no file waiting for it.
    public func start() async throws(RecordingError) {
        let systemAudio = audio != nil
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.queue)
            if systemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.queue)
            }
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw Self.mapped(error)
        }
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    /// Swaps what the running stream leaves out, without stopping it — see
    /// `DesktopIconsWatcher`. A refusal is logged and the old filter kept: a Finder window
    /// missing from the picture is a smaller loss than a take that stops.
    public func update(_ filter: SCContentFilter) async {
        do {
            try await stream?.updateContentFilter(filter)
        } catch {
            Self.log.error("Couldn't update the filter: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // A frame arrives for every change *and* for several non-changes: `.idle`
            // means "identical to the last one", `.blank` means the display went dark.
            // Neither carries a picture. An idle one still carries the *time*, which is
            // what the writer needs to keep a still screen in step with the clock.
            let status = buffer.screenFrameStatus
            if status == .idle {
                writer.appendStill(at: buffer.presentationTimeStamp)
                return
            }
            guard status == .complete else { return }
            if cursorMapper != nil || pictureTracker != nil, let geometry = buffer.frameGeometry {
                cursorMapper?.place(geometry)
                pictureTracker?.place(geometry, at: buffer.presentationTimeStamp)
            }
            writer.append(video: buffer)
        case .audio:
            audio?.append(buffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.log.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        onStop(Self.mapped(error))
    }

    private static func mapped(_ error: any Error) -> RecordingError {
        let error = error as NSError
        return switch error.code {
        case -3801, -3802: .permissionDenied
        // SCK reports "the window went away" and "the display went away" the same way.
        case -3808, -3812: .targetDisappeared
        default: .contentUnavailable(error.localizedDescription)
        }
    }
}

extension CMSampleBuffer {
    /// What ScreenCaptureKit says about this frame.
    ///
    /// The status rides along in the buffer's attachments rather than its type, and a
    /// recorder that ignores it writes the same still frame hundreds of times.
    var screenFrameStatus: SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// Where this frame's picture was on the desk and where it was put in the frame.
    ///
    /// `nil` when any of it is missing — a frame that half-describes itself is not one to
    /// move the pointer track on.
    var frameGeometry: FrameGeometry? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let screen = info[.screenRect].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
              let content = info[.contentRect].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }),
              let contentScale = info[.contentScale] as? CGFloat,
              let scaleFactor = info[.scaleFactor] as? CGFloat
        else { return nil }
        return FrameGeometry(screenRect: screen, contentRect: content,
                             contentScale: contentScale, scaleFactor: scaleFactor)
    }
}
