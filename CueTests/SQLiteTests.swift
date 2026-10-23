import XCTest

/// The thin wrapper over libsqlite3 behind the clipboard history.
final class SQLiteTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cue-test-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    func testRoundTripsEveryValueType() throws {
        let database = try SQLiteDatabase(url: url)
        try database.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT)")
        let blob = Data((0..<1000).map { UInt8($0 % 256) })
        try database.run("INSERT INTO t VALUES (?,?,?,?,?)", [.integer(42), .real(1.5), .text("héllo ✓"), .blob(blob), .null])
        let rows = try database.query("SELECT i, r, s, b, n FROM t") { row in
            (row.integer(0), row.double(1), row.text(2), row.blob(3), row.text(4))
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, 42)
        XCTAssertEqual(rows[0].1, 1.5)
        XCTAssertEqual(rows[0].2, "héllo ✓")
        XCTAssertEqual(rows[0].3, blob)
        XCTAssertNil(rows[0].4)
    }

    func testTransactionRollsBackOnError() throws {
        let database = try SQLiteDatabase(url: url)
        try database.execute("CREATE TABLE t (id TEXT PRIMARY KEY)")
        XCTAssertThrowsError(try database.transaction {
            try database.run("INSERT INTO t VALUES (?)", [.text("a")])
            try database.run("INSERT INTO t VALUES (?)", [.text("a")]) // duplicate key
        })
        let count = try database.query("SELECT COUNT(*) FROM t") { $0.integer(0) }.first
        XCTAssertEqual(count, 0)
    }

    func testCascadeDeleteAndPersistence() throws {
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("""
                CREATE TABLE items (id TEXT PRIMARY KEY);
                CREATE TABLE contents (item_id TEXT REFERENCES items(id) ON DELETE CASCADE, data BLOB);
                """)
            try database.run("INSERT INTO items VALUES ('x')")
            try database.run("INSERT INTO contents VALUES ('x', ?)", [.blob(Data([1, 2, 3]))])
            try database.run("INSERT INTO items VALUES ('y')")
            try database.run("DELETE FROM items WHERE id = 'x'")
        }
        // Reopen: the data survived and the cascade removed the orphaned blob.
        let database = try SQLiteDatabase(url: url)
        XCTAssertEqual(try database.query("SELECT id FROM items") { $0.text(0) }, ["y"])
        XCTAssertEqual(try database.query("SELECT COUNT(*) FROM contents") { $0.integer(0) }.first, 0)
    }

    func testSurvivesConcurrentUse() throws {
        let database = try SQLiteDatabase(url: url)
        try database.execute("CREATE TABLE t (n INTEGER)")
        let group = DispatchGroup()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for j in 0..<50 { try? database.run("INSERT INTO t VALUES (?)", [.integer(Int64(i * 100 + j))]) }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try database.query("SELECT COUNT(*) FROM t") { $0.integer(0) }.first, 400)
    }
}
