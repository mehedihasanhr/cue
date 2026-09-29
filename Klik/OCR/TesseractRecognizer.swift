import os
import CoreGraphics
import Dispatch
import Foundation
import CTesseract

/// The Tesseract engine, kept alive between captures.
///
/// An actor, because `TessBaseAPI` is not thread-safe and an actor is exactly the
/// mutual exclusion it needs — no lock, no `@unchecked Sendable`. Its executor is a
/// serial dispatch queue rather than the cooperative pool: recognition takes the best
/// part of a second and would otherwise occupy one of the pool's few threads for the
/// whole of it.
///
/// Every pointer — the API handle, the iterator, each `char *` — is created, used and
/// destroyed inside one isolated method. `OpaquePointer` is `Sendable`, but that says
/// nothing about what it points at, so nothing here is allowed to escape. What crosses
/// the boundary is an `OCRImageBuffer` in and `[RecognizedTextItem]` out, both values.
actor TesseractEngine {
    static let shared = TesseractEngine()

    private let queue = DispatchSerialQueue(label: "com.stackrover.klik.ocr.tesseract", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// `TessBaseAPI *`, alive between captures because loading a language model costs
    /// a good fraction of a second and most people read one language.
    private var handle: OpaquePointer?
    private var loaded: String?
    private var idleRelease: Task<Void, Never>?

    /// How long a loaded model is kept after the last capture. A model is tens of
    /// megabytes resident; nobody reads one screenshot a minute for an hour.
    private static let idleTimeout = Duration.seconds(120)

    // No deinit: this is a process-lifetime singleton, so one would never run, and an
    // actor's deinit cannot touch isolated state under strict concurrency anyway.
    // `unload()` is the real release path and the idle timer drives it.

    /// Reads `buffer`. `language` is Tesseract's own spelling, several joined with
    /// `+` when more than one should be tried.
    func recognize(_ buffer: OCRImageBuffer, language: String, datapath: URL,
                   minimumConfidence: Float) throws -> [RecognizedTextItem] {
        let api = try engine(for: language, datapath: datapath)

        buffer.pixels.withUnsafeBufferPointer { raw in
            TessBaseAPISetImage(api, raw.baseAddress, Int32(buffer.width), Int32(buffer.height),
                                1, Int32(buffer.bytesPerRow))
        }
        // Say what the resolution is rather than letting Tesseract guess and log about it.
        TessBaseAPISetSourceResolution(api, 300)
        defer { TessBaseAPIClear(api) }

        guard TessBaseAPIRecognize(api, nil) == 0 else { throw TesseractError.recognitionFailed }
        guard let iterator = TessBaseAPIGetIterator(api) else { return [] }
        defer { TessResultIteratorDelete(iterator) }
        // The page iterator is the same object, so it must not be deleted separately.
        guard let page = TessResultIteratorGetPageIterator(iterator) else { return [] }

        let width = CGFloat(buffer.width), height = CGFloat(buffer.height)
        var items: [RecognizedTextItem] = []
        repeat {
            var left: Int32 = 0, top: Int32 = 0, right: Int32 = 0, bottom: Int32 = 0
            guard TessPageIteratorBoundingBox(page, RIL_TEXTLINE, &left, &top, &right, &bottom) != 0,
                  right > left, bottom > top,
                  let raw = TessResultIteratorGetUTF8Text(iterator, RIL_TEXTLINE)
            else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            TessDeleteText(raw)
            guard !text.isEmpty else { continue }

            let confidence = TessResultIteratorConfidence(iterator, RIL_TEXTLINE) / 100
            guard confidence >= minimumConfidence else { continue }

            // Tesseract counts pixels from the top left; everything downstream of
            // here expects Vision's normalised box with its origin at the bottom
            // left. Dividing by the buffer's own size also divides out any enlarging
            // done in preprocessing, so the box lands on the original image.
            let box = CGRect(x: CGFloat(left) / width,
                             y: 1 - CGFloat(bottom) / height,
                             width: CGFloat(right - left) / width,
                             height: CGFloat(bottom - top) / height)
            items.append(RecognizedTextItem(text: text, confidence: confidence, boundingBox: box))
        } while TessResultIteratorNext(iterator, RIL_TEXTLINE) != 0

        scheduleIdleRelease()
        return items
    }

    private func scheduleIdleRelease() {
        idleRelease?.cancel()
        idleRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    /// The API handle, loading the language only when it is not the one already in.
    private func engine(for language: String, datapath: URL) throws -> OpaquePointer {
        if let handle, loaded == language { return handle }
        if let handle {
            TessBaseAPIEnd(handle)
            TessBaseAPIDelete(handle)
            self.handle = nil
            loaded = nil
        }

        guard let created = TessBaseAPICreate() else { throw TesseractError.couldNotStart }
        // The datapath is the directory holding `<language>.traineddata` itself:
        // Tesseract appends the file name to it and does not add a `tessdata`
        // component of its own.
        let started = datapath.path(percentEncoded: false).withCString { path in
            language.withCString { name in TessBaseAPIInit3(created, path, name) }
        }
        guard started == 0 else {
            TessBaseAPIDelete(created)
            throw TesseractError.couldNotLoad(language)
        }

        // Tesseract's own logging otherwise goes to stderr from inside a sandboxed
        // agent; Log.ocr should be the only voice.
        _ = "/dev/null".withCString { value in
            "debug_file".withCString { name in TessBaseAPISetVariable(created, name, value) }
        }
        TessBaseAPISetPageSegMode(created, PSM_AUTO)

        handle = created
        loaded = language
        Log.ocr.info("Tesseract loaded \(language, privacy: .public)")
        return created
    }

    /// Lets go of the loaded model — a few tens of megabytes — when it will not be
    /// wanted again soon.
    func unload() {
        idleRelease?.cancel()
        idleRelease = nil
        guard let handle else { return }
        TessBaseAPIEnd(handle)
        TessBaseAPIDelete(handle)
        self.handle = nil
        loaded = nil
    }
}

nonisolated enum TesseractError: Error, LocalizedError {
    case couldNotStart
    case couldNotLoad(String)
    case couldNotRender
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .couldNotStart: "Tesseract wouldn't start."
        case .couldNotLoad(let language): "Tesseract couldn't load the \(language) model."
        case .couldNotRender: "That image couldn't be prepared for recognition."
        case .recognitionFailed: "Tesseract couldn't read that image."
        }
    }
}
