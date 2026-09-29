import Foundation

/// The Tesseract language models Klik knows how to fetch, and where they live.
///
/// Pure data, so it can be read and tested without the native library. The engine
/// that uses it is `TesseractOCREngine`; the downloader is `TessdataStore`.
///
/// These are the `tessdata_best` models — the float LSTM ones. They are ten times the
/// size of the `fast` variants and roughly twenty times slower to load, and they earn
/// it: measured on Bangla screenshots, `fast` matched `best` on crisp Retina text but
/// broke conjuncts and dropped whole lines at 1× and in a second typeface. A language
/// pack is fetched once and the engine is kept warm, so accuracy is the axis worth
/// paying on.
nonisolated enum TesseractLanguagePacks {
    /// One model file.
    struct Pack: Sendable, Hashable, Identifiable {
        /// Tesseract's three-letter name, which is also the file's name.
        let code: String
        /// The BCP-47 tag Klik speaks in, so it lines up with Vision's list.
        let tag: String
        let bytes: Int
        /// SHA-256 of the file at `release`. A pinned tag is immutable, so this is an
        /// assertion rather than a hope.
        let sha256: String

        var id: String { code }
    }

    /// The tessdata_best release the sizes and digests below were taken from. Bump
    /// this and every digest together, never one alone.
    static let release = "4.1.0"

    /// Languages Vision has no model for, plus English, which a Tesseract-read page
    /// needs as a companion when the text is mixed (Vision cannot help there — once
    /// the primary language is Tesseract's, the whole page is Tesseract's).
    ///
    /// Bangla comes first because it is why this exists.
    static let all: [Pack] = [
        Pack(code: "ben", tag: "bn-BD", bytes: 11_045_427, sha256: "1cd0129288d1f74f6661c35e638e487bd146a66bb732ecd9e011e48dcb0df623"),
        Pack(code: "asm", tag: "as-IN", bytes: 11_315_350, sha256: "7ee579ad079e30566e856dfe7fc5ce0724f3625e69025cc88c785237172d9308"),
        Pack(code: "hin", tag: "hi-IN", bytes: 11_895_564, sha256: "bd2e65a2184af08a167b0be2439e91fa5edbc4394399ca2f692b843ae26e78d6"),
        Pack(code: "eng", tag: "en-US", bytes: 15_400_601, sha256: "8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba"),
        Pack(code: "tam", tag: "ta-IN", bytes: 6_023_201, sha256: "4b9ce85987f629dd31eaf87443a1646452a43cdf91fcf05e017382ad595dcb9e"),
        Pack(code: "tel", tag: "te-IN", bytes: 9_098_795, sha256: "81b0a1cfaf8bbf0f87da72b8c348264c6f24130766f5c4ade733fc20c05aaccc"),
        Pack(code: "kan", tag: "kn-IN", bytes: 10_233_763, sha256: "6f195e0f33f0ec5118c97eff777ed70ac453d67c32bf06a43f79dab875f8ebfe"),
        Pack(code: "mal", tag: "ml-IN", bytes: 12_524_967, sha256: "b4a8b1b2fd8c5754aa0f543568626aad514d94a6c1e138ef0bf1a329aa189ef0"),
        Pack(code: "guj", tag: "gu-IN", bytes: 8_515_761, sha256: "8cbb1d139b63434b9e1154a3b51930a74ec1c9a6251b95d86d74d7f1cd706ed6"),
        Pack(code: "pan", tag: "pa-IN", bytes: 11_893_154, sha256: "6971b1f5c4094da3d73cd13bc79429de912a31919330324556a26e3b4802b905"),
        Pack(code: "ori", tag: "or-IN", bytes: 8_110_602, sha256: "90dfe91cea0b25cf96b2bb283905ba1452534776df3f00d47530939d56339534"),
        Pack(code: "sin", tag: "si-LK", bytes: 8_282_713, sha256: "1d95b36e935c8c12cc890684fad15bd3ad8d904c3a6ffa2fccb81658eabd8454"),
        Pack(code: "nep", tag: "ne-NP", bytes: 12_387_399, sha256: "54907633d05bb9fae7dbfb3d8a61ddf2f579127375aa53b8afc657efb34a79f0"),
        Pack(code: "urd", tag: "ur-PK", bytes: 7_994_323, sha256: "65af3f6e50a3c3df15d7b405aab5d467e53433207745c8f5be5b8ff1a58a67c8"),
        Pack(code: "heb", tag: "he-IL", bytes: 3_704_077, sha256: "dbaa827aea6bc21215638447f17783a1004987c2d0bf5573d111fee397abdae5"),
        Pack(code: "ell", tag: "el-GR", bytes: 8_945_021, sha256: "288b4ea00bab450cf39893d22f04a2835a8469b673b5b20dcb39b159d1bbc9b8"),
        Pack(code: "kat", tag: "ka-GE", bytes: 4_487_336, sha256: "557f48b753fdbbee2c77d83bae2542af249f915be6cf80883892a579ea2a81db"),
        Pack(code: "hye", tag: "hy-AM", bytes: 6_372_242, sha256: "ca46afdca95b5436e9510fd2fc59aff45c306132433a4267eed2bd422cdd29f4"),
    ]

    private static let byCode: [String: Pack] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
    /// Keyed by the bare language subtag, so `bn-BD` and `bn-IN` find the same pack.
    private static let byBase: [String: Pack] = Dictionary(all.map { (OCRLanguage($0.tag).base, $0) }, uniquingKeysWith: { first, _ in first })

    static func pack(forCode code: String) -> Pack? { byCode[code] }
    static func pack(forBase base: String) -> Pack? { byBase[base] }
    static func code(forBase base: String) -> String? { byBase[base]?.code }

    /// Where the model is fetched from. A pinned release, not a branch: a tag cannot
    /// change under the digests above.
    static func downloadURL(for code: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/tesseract-ocr/tessdata_best/\(release)/\(code).traineddata")
    }

    /// The model's place inside `folder`. Tesseract is handed `folder` itself as its
    /// datapath and appends `<code>.traineddata`, so the two must agree.
    static func fileURL(for code: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(code).traineddata", isDirectory: false)
    }

    /// "10.5 MB" — for the download badge in the language picker.
    static func sizeDescription(for code: String) -> String? {
        guard let pack = byCode[code] else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(pack.bytes), countStyle: .file)
    }
}
