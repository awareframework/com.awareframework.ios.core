//
//  UploadJSONBytesTests.swift
//  The byte writer (SQLiteEngine.appendUploadJSON) writes the same text as the string writer it
//  replaced, and the form encoding matches URLComponents except for "+".
//

import XCTest
import GRDB
@testable import com_awareframework_ios_core

final class UploadJSONBytesTests: XCTestCase {

    private let table = "bytes_test"

    /// The rows as the string writer (UploadJSONWriter) wrote them before
    private func referenceJSON(_ queue: DatabaseQueue, omitting: Set<String>) throws -> [String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { row in
                var json = "{"
                var first = true
                for (column, value) in row {
                    if omitting.contains(column) { continue }
                    switch value.storage {
                    case .null, .blob: continue
                    case .int64(let v):
                        if !first { json.append(",") }
                        UploadJSONWriter.appendKey(column, to: &json)
                        json.append(String(v))
                    case .double(let v):
                        if !first { json.append(",") }
                        UploadJSONWriter.appendKey(column, to: &json)
                        _ = UploadJSONWriter.appendDouble(v, to: &json)
                    case .string(let v):
                        if !first { json.append(",") }
                        UploadJSONWriter.appendKey(column, to: &json)
                        UploadJSONWriter.appendString(v, to: &json)
                    }
                    first = false
                }
                return json + "}"
            }
        }
    }

    func testSameTextAsTheStringWriter() throws {
        let config = Engine.EngineConfig()
        config.path = "bytes_\(UUID().uuidString)"
        config.tableName = table
        let engine = SQLiteEngine(config)
        let queue = try XCTUnwrap(engine.getSQLiteInstance())
        let ints: [Int64] = [0, 1, -1, 9, 10, 1_795_060_031_991, Int64.max, Int64.min]
        let doubles: [Double] = [0, -0.0, 0.1, 0.0123456789, -0.98765432, 1e-7, 1e+20, 123456789.123,
                                 5e-324, 1.7976931348623157e308, 3.0, -2.5e-310]
        let texts = ["", "abc", "E2F5B9CE-EB39-498A-BA44-C391175D313C", "it's \"quoted\"", "back\\slash",
                     "line\nbreak\r\ttab", "\u{1}\u{1f}\u{7f}", "é", "日本語", "😀 emoji", "GMT+9 a+b", "a/b?c=d&e"]
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE \(table) (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER, deviceId TEXT, label TEXT, x REAL, n INTEGER, note TEXT)")
            for i in 0..<120 {
                try db.execute(sql: "INSERT INTO \(table) (timestamp, deviceId, label, x, n, note) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [1_795_060_031_991 + Int64(i), "E2F5B9CE-EB39-498A-BA44-C391175D313C",
                                           i % 7 == 0 ? nil : texts[i % texts.count], doubles[i % doubles.count],
                                           ints[i % ints.count], i % 3 == 0 ? texts[(i / 3) % texts.count] : "same"])
            }
        }
        for omitting in [Set<String>(), ["id"]] {
            let expected = try referenceJSON(queue, omitting: omitting)
            let written = try XCTUnwrap(engine.fetchUploadJSON(afterId: 0, limit: 1000, omitting: omitting))
            XCTAssertEqual(written.count, expected.count)
            for (i, (w, e)) in zip(written, expected).enumerated() {
                XCTAssertEqual(w.json, e, "row \(i)")
            }
            var buffer: [UInt8] = [1, 2, 3]  // appended after what is there
            let spans = try XCTUnwrap(engine.appendUploadJSON(afterId: 0, limit: 1000, omitting: omitting, to: &buffer))
            XCTAssertEqual(Array(buffer.prefix(3)), [1, 2, 3])
            XCTAssertEqual(spans.compactMap { $0.range.map { String(decoding: buffer[$0], as: UTF8.self) } }, expected)
            XCTAssertEqual(spans.map(\.id), Array(1...120).map(Int64.init))
        }
    }

    func testFormEncodingMatchesURLComponentsExceptPlus() {
        var ascii = ""
        for v in 0x20...0x7e where v != 0x2B { ascii.append(Character(UnicodeScalar(v)!)) }
        let samples = [ascii, "", "é日本語😀", "{\"x\":0.1,\"label\":\"a b\"}", "[1,2]&data=x"]
        for text in samples {
            var c = URLComponents()
            c.queryItems = [URLQueryItem(name: "v", value: text)]
            XCTAssertEqual(FormEncoding.body([("v", text)]), c.percentEncodedQuery, text)
            XCTAssertEqual(FormEncoding.encodedLength(text) + 2, c.percentEncodedQuery?.utf8.count)
        }
        XCTAssertEqual(FormEncoding.body([("v", "GMT+9")]), "v=GMT%2B9", "+ is encoded, so the server does not read a space")
        XCTAssertEqual(FormEncoding.body([("a", "1"), ("b", "x y")]), "a=1&b=x%20y", "fields in order")
    }

    func testIntegersWithoutStrings() {
        for v: Int64 in [0, 7, -7, 10, 1_000_000, Int64.max, Int64.min] {
            var out: [UInt8] = []
            JSONBytes.appendInt(v, to: &out)
            XCTAssertEqual(String(decoding: out, as: UTF8.self), String(v))
        }
    }
}
