import AppKit
import XCTest

/// The shelf's file actions on a generated image.
final class FileActionsTests: XCTestCase {
    /// A 3000 × 2000 red PNG in a fresh folder.
    private func sample() throws -> (image: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 3000, height: 2000))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 3000, height: 2000).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let url = folder.appendingPathComponent("Red.png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return (url, folder)
    }

    func testConvertsToEachWritableFormat() throws {
        let (image, folder) = try sample()
        for format in FileActions.ImageFormat.writable {
            let output = try XCTUnwrap(FileActions.convert(image, to: format, into: folder))
            XCTAssertEqual(output.pathExtension, format.fileExtension)
            XCTAssertNotNil(NSImage(contentsOf: output), format.title)
        }
    }

    func testCompressesToAtMost2560Pixels() throws {
        let (image, folder) = try sample()
        let output = try XCTUnwrap(FileActions.compress(image, into: folder))
        let rep = try XCTUnwrap(NSImage(contentsOf: output)?.representations.first)
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), 2560)
    }

    func testZipsFiles() throws {
        let (image, folder) = try sample()
        let output = try XCTUnwrap(FileActions.zip([image], into: folder))
        XCTAssertEqual(output.pathExtension, "zip")
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 0)
    }
}
