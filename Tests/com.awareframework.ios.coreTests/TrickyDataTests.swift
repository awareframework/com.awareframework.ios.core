//
//  TrickyDataTests.swift
//  Text that is easy to break in JSON, in the URL-encoded form, and on the server: backslashes
//  (alone, doubled, before n/u/quote/comma, at the end), commas, quotes, + & = %, newlines,
//  control characters, non-ASCII. In every format the requests turn back into the stored rows.
//
//  With AWARE_DUMP_DIR set, the request bodies and the expected rows are written there, so the
//  server can be checked with the same bytes (see the server's tests).
//

import XCTest
import GRDB
@testable import com_awareframework_ios_core

final class TrickyDataTests: XCTestCase {

    static let texts: [String] = [
        "\\", "\\\\", "\\n", "\\u0041", "end\\", "\\\"", "\\,", "a\\,b", "C:\\temp\\new", "\\\\server\\share",
        "{\"json\":\"in text\"}", "a,b,c", ",", ",,", "\"", "'", "it's", "a+b", "x&y=z", "100%", "%2B",
        "line\nbreak", "cr\rlf\r\n", "tab\there", "\u{1}\u{1f}", "\u{7f}", "é", "日本語、テスト", "😀", "",
        " ", "null", "[1,2]", "]}", "/slash/", "<tag>", "\u{2028}",
    ]

    private func makeEngine(table: String) throws -> SQLiteEngine {
        let config = Engine.EngineConfig()
        config.path = "tricky_\(UUID().uuidString)"
        config.tableName = table
        let engine = SQLiteEngine(config)
        let queue = try XCTUnwrap(engine.getSQLiteInstance())
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE \(table) (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER, deviceId TEXT,
                  label TEXT, os TEXT, timezone INTEGER, jsonVersion INTEGER, x REAL, note TEXT, "odd,col\\name" TEXT)
                """)
            let texts = Self.texts
            for i in 0..<(texts.count * 12) {
                try db.execute(sql: "INSERT INTO \(table) (timestamp, deviceId, label, os, timezone, jsonVersion, x, note, \"odd,col\\name\") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                               arguments: [1_795_060_031_991 + i, "dev\\ice", texts[i % texts.count], "ios", 9, 1,
                                           i % 4 == 0 ? nil : Double(i) * 1.000001 - 50,
                                           i % 5 == 0 ? nil : texts[(i * 7) % texts.count], texts[(i * 3) % texts.count]])
            }
        }
        return engine
    }

    /// The rows in a request body
    static func rows(in body: Data, form: Bool) throws -> [[String: Any]] {
        var json = body
        if form {
            let text = String(decoding: body, as: UTF8.self)
            guard let field = text.components(separatedBy: "&").first(where: { $0.hasPrefix("data=") }),
                  let value = String(field.dropFirst(5)).removingPercentEncoding else { return [] }
            json = Data(value.utf8)
        }
        let object = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        var data: Any = object
        if !form, let envelope = object as? [String: Any] { data = envelope["data"] as Any }
        return data as? [[String: Any]] ?? []
    }

    /// The same row: every stored column (not left out) with the same value
    static func mismatch(sent: [String: Any], stored: [String: Any], omitted: Set<String>) -> String? {
        let expected = stored.filter { !omitted.contains($0.key) }
        if Set(sent.keys) != Set(expected.keys) {
            return "columns differ: \(Set(sent.keys).symmetricDifference(expected.keys).sorted())"
        }
        for (key, value) in expected {
            let got = sent[key]
            switch value {
            case let v as Int64:
                if (got as? NSNumber)?.int64Value != v { return "\(key): integer differs" }
            case let v as Double:
                guard let g = (got as? NSNumber)?.doubleValue, g == v || abs(g - v) <= abs(v) * 1e-15 else {
                    return "\(key): number differs"
                }
            case let v as String:
                if got as? String != v { return "\(key): text differs" }
            default:
                return "\(key): unexpected type \(type(of: value))"
            }
        }
        return nil
    }

    func testTrickyTextInEveryFormat() throws {
        let dumpDir = ProcessInfo.processInfo.environment["AWARE_DUMP_DIR"]
        for (name, server) in [("json", ServerType.aware_micro), ("form", .aware), ("hub", .aware_hub)] {
            let table = "tricky_test"
            let engine = try makeEngine(table: table)
            let config = DbSyncConfig()
            config.serverType = server
            config.maxBatchBytes = 20_000
            let requests = engine.previewUploadRequests(config: config, batches: 10_000)
            let stored = try XCTUnwrap(engine.fetch(filter: "id > 0", limit: nil))
            let omitted: Set<String> = []
            var sent: [[String: Any]] = []
            for (i, r) in requests.enumerated() {
                XCTAssertLessThanOrEqual(r.body.count, r.limitBytes, "\(name) request \(i)")
                let rows = try Self.rows(in: r.body, form: server == .aware)
                XCTAssertEqual(rows.count, r.rows, "\(name) request \(i)")
                sent += rows
                if let dumpDir {
                    try r.body.write(to: URL(fileURLWithPath: dumpDir).appendingPathComponent("\(name)-\(i).body"))
                }
            }
            XCTAssertEqual(sent.count, stored.count, "\(name): every row once")
            for (i, (s, row)) in zip(sent, stored).enumerated() {
                if let problem = Self.mismatch(sent: s, stored: row, omitted: omitted) {
                    XCTFail("\(name) row \(i): \(problem)")
                    break
                }
            }
            if let dumpDir {
                let expected = stored.map { row in row.filter { !omitted.contains($0.key) } }
                let data = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: dumpDir).appendingPathComponent("\(name).expected.json"))
            }
        }
    }
}
