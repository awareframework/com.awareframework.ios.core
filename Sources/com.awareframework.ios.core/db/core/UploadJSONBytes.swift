//
//  UploadJSONBytes.swift
//  com.awareframework.ios.core
//
//  Upload rows written as JSON straight into one byte buffer, and the URL encoding of the form
//  body for the legacy AWARE server. The text is the same as `UploadJSONWriter` writes with
//  strings; bytes avoid making a string for every row and every value.
//

import Foundation

/// A row written into a byte buffer by `Engine.appendUploadJSON(afterId:limit:omitting:to:)`:
/// its ID, and where its JSON object is in the buffer (nil when the row cannot be written as JSON).
public struct UploadRowSpan {
    public let id: Int64
    public let range: Range<Int>?

    public init(id: Int64, range: Range<Int>?) {
        self.id = id
        self.range = range
    }
}

/// Writes JSON values as UTF-8 bytes: the same text as `UploadJSONWriter`.
enum JSONBytes {

    /// `"key":`
    static func key(_ key: String) -> [UInt8] {
        var out: [UInt8] = []
        appendString(key, to: &out)
        out.append(UInt8(ascii: ":"))
        return out
    }

    /// An integer, digit by digit (no string is made)
    static func appendInt(_ value: Int64, to out: inout [UInt8]) {
        if value == 0 {
            out.append(UInt8(ascii: "0"))
            return
        }
        var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var count = 0
        // The magnitude as UInt64, so that Int64.min has one
        var magnitude = value.magnitude
        withUnsafeMutableBytes(of: &digits) { buffer in
            while magnitude > 0 {
                buffer[count] = UInt8(ascii: "0") + UInt8(magnitude % 10)
                magnitude /= 10
                count += 1
            }
        }
        if value < 0 { out.append(UInt8(ascii: "-")) }
        withUnsafeBytes(of: &digits) { buffer in
            for i in stride(from: count - 1, through: 0, by: -1) { out.append(buffer[i]) }
        }
    }

    /// A number with the shortest text that reads back as the same Double. Returns false for
    /// infinity and NaN, which JSON cannot hold.
    static func appendDouble(_ value: Double, to out: inout [UInt8]) -> Bool {
        guard value.isFinite else { return false }
        // Most texts fit in a small string, which needs no allocation
        var text = value.description
        text.withUTF8 { out.append(contentsOf: $0) }
        return true
    }

    /// A string from `String`
    static func appendString(_ text: String, to out: inout [UInt8]) {
        var text = text
        text.withUTF8 { appendString(utf8: $0, to: &out) }
    }

    /// A string from valid UTF-8 bytes. Only `"`, `\` and control characters are escaped; other
    /// bytes, including those of non-ASCII characters, are copied.
    static func appendString(utf8 bytes: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        var plainStart = 0
        for i in 0..<bytes.count {
            let b = bytes[i]
            guard b < 0x20 || b == UInt8(ascii: "\"") || b == UInt8(ascii: "\\") else { continue }
            if plainStart < i { out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[plainStart..<i])) }
            switch b {
            case UInt8(ascii: "\""): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            default:
                // \u00XX with lowercase hex, like UploadJSONWriter
                let hex: [UInt8] = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"),
                                        hex[Int(b >> 4)], hex[Int(b & 0x0F)]])
            }
            plainStart = i + 1
        }
        if plainStart < bytes.count {
            out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[plainStart..<bytes.count]))
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// URL encoding of form values (`application/x-www-form-urlencoded`) for the legacy AWARE server.
///
/// The same characters are left as they are as `URLComponents` leaves in query values, except
/// `+`: `URLComponents` leaves it, and the server reads it as a space, so a `+` in the data (a time
/// zone like "GMT+9", a number like 1e+20) arrived as a space. Here it is encoded as `%2B`.
enum FormEncoding {

    /// Bytes left as they are: `!$'()*,-./0-9:;?@A-Z_a-z~`
    private static let plain: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for b in "!$'()*,-./0123456789:;?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~".utf8 {
            table[Int(b)] = true
        }
        return table
    }()

    private static let hex: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Length of `bytes` after encoding
    static func encodedLength(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var length = 0
        for b in bytes { length += plain[Int(b)] ? 1 : 3 }
        return length
    }

    static func encodedLength(_ text: String) -> Int {
        var text = text
        return text.withUTF8 { encodedLength($0) }
    }

    /// Appends `bytes`, encoded, to `out`
    static func append(_ bytes: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) {
        for b in bytes {
            if plain[Int(b)] {
                out.append(b)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
            }
        }
    }

    static func append(_ text: String, to out: inout [UInt8]) {
        var text = text
        text.withUTF8 { append($0, to: &out) }
    }

    /// `name=value&name=value`, in the given order
    static func body(_ fields: [(String, String)]) -> String {
        var out: [UInt8] = []
        for (i, (name, value)) in fields.enumerated() {
            if i > 0 { out.append(UInt8(ascii: "&")) }
            append(name, to: &out)
            out.append(UInt8(ascii: "="))
            append(value, to: &out)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
