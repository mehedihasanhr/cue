import Foundation
import Testing
@testable import BackgroundKit

/// Naming a background, and finding it again.
struct WallpaperIDTests {
    @Test func everyNamespaceRoundTrips() throws {
        for namespace in WallpaperID.Namespace.allCases {
            let id = WallpaperID(namespace, "something")
            let parsed = try #require(WallpaperID(rawValue: id.rawValue))
            #expect(parsed.namespace == namespace)
            #expect(parsed.name == "something")
        }
    }

    @Test(arguments: ["", "nonamespace", "bogus:x", "klik:", ":klik"])
    func nonsenseIsRejected(_ raw: String) {
        #expect(WallpaperID(rawValue: raw) == nil)
    }

    @Test func aSystemPictureInAFolderKeepsItsPath() throws {
        let id = WallpaperID(.system, "Solid Colors/Black.png")
        let parsed = try #require(WallpaperID(rawValue: id.rawValue))
        #expect(parsed.name == "Solid Colors/Black.png")
    }

    @Test func anIdSurvivesBeingWrittenDown() throws {
        let id = WallpaperID.preset(.flame)
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(WallpaperID.self, from: data) == id)
    }
}

/// The gradients the picker is made of.
struct GradientPresetTests {
    @Test func everyPresetHasAUsableRamp() {
        for preset in GradientPreset.allCases {
            #expect(preset.colors.count >= 2, "\(preset) needs at least two stops to be a gradient")
            for colour in preset.colors {
                #expect((0...1).contains(colour.r) && (0...1).contains(colour.g)
                    && (0...1).contains(colour.b) && (0...1).contains(colour.a))
            }
        }
    }

    @Test func namesAreUniqueBecauseTheyAreIdentity() {
        let names = Set(GradientPreset.allCases.map(\.rawValue))
        #expect(names.count == GradientPreset.allCases.count)
    }
}

struct WallpaperResolverTests {
    @Test func aPresetIdResolvesToThePresetItNames() throws {
        for preset in GradientPreset.allCases {
            let source = WallpaperResolver().source(for: .preset(preset))
            #expect(source == .procedural(preset))
        }
    }

    @Test func anUnknownPresetResolvesToNothingRatherThanToADefault() {
        let id = try! #require(WallpaperID(rawValue: "klik:invented"))
        #expect(WallpaperResolver().source(for: id) == nil)
    }

    @Test func aUserIdWithNoStoredBookmarkResolvesToNothing() {
        let id = WallpaperID(.user, Data("not a bookmark".utf8).base64EncodedString())
        #expect(WallpaperResolver().source(for: id) == nil)
    }

    @Test func aProceduralSourceNeedsNoGrant() {
        let opened = WallpaperResolver().withAccess(to: .procedural(.ocean)) { $0 == nil }
        #expect(opened)
    }
}

struct WallpaperTests {
    @Test func aTitleIsTheFileNameWithoutItsFolderOrExtension() {
        #expect(Wallpaper(name: "Solid Colors/Black.png").title == "Black")
        #expect(Wallpaper(name: "Sonoma.heic").title == "Sonoma")
    }

    @Test func recentsAreCappedAndMostRecentFirst() throws {
        let suite = "BackgroundKitTests-\(UUID().uuidString)"
        let bookmarks = WallpaperBookmarks(suiteName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [URL] = []
        for index in 0..<(WallpaperBookmarks.limit + 3) {
            let url = folder.appendingPathComponent("\(index).txt")
            try Data("x".utf8).write(to: url)
            urls.append(url)
            bookmarks.remember(url)
        }

        #expect(bookmarks.recents.count <= WallpaperBookmarks.limit)
        let resolved = bookmarks.resolvedRecents().map(\.url.lastPathComponent)
        #expect(resolved.first == urls.last?.lastPathComponent, "the newest pick is offered first")
    }

    @Test func rememberingTheSameFileTwiceDoesNotListItTwice() throws {
        let suite = "BackgroundKitTests-\(UUID().uuidString)"
        let bookmarks = WallpaperBookmarks(suiteName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        bookmarks.remember(url)
        bookmarks.remember(url)
        #expect(bookmarks.recents.count == 1)
    }
}
