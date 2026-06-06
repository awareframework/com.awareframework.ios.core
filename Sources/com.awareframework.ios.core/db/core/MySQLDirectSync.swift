import CryptoKit
import Foundation
import Network

public struct MySQLDirectSyncConfig {
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var password: String

    public var isConfigured: Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public init(
        host: String = "",
        port: Int = 3306,
        database: String = "",
        username: String = "",
        password: String = ""
    ) {
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
    }
}

public struct SQLiteTableColumn {
    public let name: String
    public let type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

public struct SQLiteTableSnapshot {
    public let tableName: String
    public let schema: [SQLiteTableColumn]
    public let rows: [[String: Any]]

    public init(tableName: String, schema: [SQLiteTableColumn], rows: [[String: Any]]) {
        self.tableName = tableName
        self.schema = schema
        self.rows = rows
    }
}

public struct MySQLDirectSyncResult {
    public let insertedRows: Int

    public init(insertedRows: Int) {
        self.insertedRows = insertedRows
    }
}

public final class MySQLDirectClient {

    private let config: MySQLDirectSyncConfig
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "aware.mysql.direct.client")

    public init(config: MySQLDirectSyncConfig) {
        self.config = config
    }

    public func connect() async throws {
        guard config.isConfigured else {
            throw MySQLDirectSyncError.invalidConfiguration
        }

        let host = NWEndpoint.Host(config.host)
        let port = NWEndpoint.Port(integerLiteral: UInt16(config.port))
        let conn = NWConnection(host: host, port: port, using: .tcp)
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                case .cancelled:
                    cont.resume(throwing: MySQLDirectSyncError.connectionCancelled)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }

        let handshake = try await readPacket()
        let seed = try parseHandshakeV10(handshake)
        let authToken = mysqlNativePassword(password: config.password, seed: seed)
        let response = buildHandshakeResponse(
            user: config.username,
            authToken: authToken,
            database: config.database
        )
        try await sendPacket(response, sequenceId: 1)
        try checkOKPacket(try await readPacket())
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
    }

    public func syncTable(_ table: SQLiteTableSnapshot, batchSize: Int = 100) async throws -> Int {
        guard table.rows.isEmpty == false, table.schema.isEmpty == false else {
            return 0
        }

        try await executeQuery(buildCreateTable(tableName: table.tableName, schema: table.schema))

        var inserted = 0
        let columns = table.schema.map(\.name)
        for start in stride(from: 0, to: table.rows.count, by: batchSize) {
            let batch = Array(table.rows[start..<min(start + batchSize, table.rows.count)])
            try await executeQuery(buildInsert(tableName: table.tableName, columns: columns, rows: batch))
            inserted += batch.count
        }
        return inserted
    }

    public func syncTables(_ tables: [SQLiteTableSnapshot], batchSize: Int = 100) async throws -> MySQLDirectSyncResult {
        var insertedRows = 0
        for table in tables {
            insertedRows += try await syncTable(table, batchSize: batchSize)
        }
        return MySQLDirectSyncResult(insertedRows: insertedRows)
    }

    private func executeQuery(_ sql: String) async throws {
        var payload = Data([0x03])
        payload.append(contentsOf: sql.utf8)
        try await sendPacket(payload, sequenceId: 0)
        let result = try await readPacket()
        if result.first == 0xFF {
            throw MySQLDirectSyncError.queryError(parseErrorPacket(result))
        }
    }

    private func sendPacket(_ payload: Data, sequenceId: UInt8) async throws {
        var packet = Data(count: 4)
        let length = payload.count
        packet[0] = UInt8(length & 0xFF)
        packet[1] = UInt8((length >> 8) & 0xFF)
        packet[2] = UInt8((length >> 16) & 0xFF)
        packet[3] = sequenceId
        packet.append(payload)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection?.send(content: packet, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readPacket() async throws -> Data {
        let header = try await readBytes(count: 4)
        let length = Int(header[0]) | (Int(header[1]) << 8) | (Int(header[2]) << 16)
        guard length > 0 else {
            return Data()
        }
        return try await readBytes(count: length)
    }

    private func readBytes(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            var accumulated = Data()

            func receive() {
                connection?.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) {
                    data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if let data {
                        accumulated.append(data)
                    }
                    if accumulated.count >= count {
                        cont.resume(returning: accumulated)
                    } else if isComplete {
                        cont.resume(throwing: MySQLDirectSyncError.connectionClosed)
                    } else {
                        receive()
                    }
                }
            }

            receive()
        }
    }

    private func parseHandshakeV10(_ data: Data) throws -> Data {
        guard data.count > 10, data[0] == 0x0A else {
            throw MySQLDirectSyncError.unexpectedPacket("Expected HandshakeV10")
        }

        var offset = 1
        while offset < data.count && data[offset] != 0 { offset += 1 }
        offset += 1
        offset += 4
        var seed = Data(data[offset..<offset + 8])
        offset += 8
        offset += 1
        offset += 2
        offset += 1
        offset += 2
        offset += 2
        let authPluginDataLength = data.count > offset ? Int(data[offset]) : 0
        offset += 1
        offset += 10

        let part2Length = max(13, authPluginDataLength - 8)
        if offset + part2Length <= data.count {
            seed.append(contentsOf: data[offset..<offset + part2Length - 1])
        }
        return seed
    }

    private func buildHandshakeResponse(user: String, authToken: Data, database: String) -> Data {
        var payload = Data()
        let capabilities: UInt32 = 0x000FA68D
        payload.appendUInt32LE(capabilities)
        payload.appendUInt32LE(0x01000000)
        payload.append(0x21)
        payload.append(contentsOf: Data(repeating: 0, count: 23))
        payload.append(contentsOf: user.utf8)
        payload.append(0)
        payload.append(UInt8(authToken.count))
        payload.append(contentsOf: authToken)
        payload.append(contentsOf: database.utf8)
        payload.append(0)
        payload.append(contentsOf: "mysql_native_password".utf8)
        payload.append(0)
        return payload
    }

    private func mysqlNativePassword(password: String, seed: Data) -> Data {
        guard password.isEmpty == false else {
            return Data()
        }
        let pass1 = Data(Insecure.SHA1.hash(data: Data(password.utf8)))
        let pass2 = Data(Insecure.SHA1.hash(data: pass1))
        var combined = seed
        combined.append(contentsOf: pass2)
        let pass3 = Data(Insecure.SHA1.hash(data: combined))
        return Data(zip(pass1, pass3).map { $0 ^ $1 })
    }

    private func checkOKPacket(_ data: Data) throws {
        guard let first = data.first else {
            throw MySQLDirectSyncError.emptyResponse
        }
        if first == 0xFF {
            throw MySQLDirectSyncError.authFailed(parseErrorPacket(data))
        }
    }

    private func parseErrorPacket(_ data: Data) -> String {
        guard data.count > 9 else {
            return "Unknown MySQL error"
        }
        let messageData = data.dropFirst(9)
        return String(data: messageData, encoding: .utf8) ?? "Unknown MySQL error"
    }

    private func buildCreateTable(tableName: String, schema: [SQLiteTableColumn]) -> String {
        let columns = schema.map { column -> String in
            let mysqlType = sqliteTypeToMySQL(column.type)
            let escapedName = escapeIdentifier(column.name)
            return column.name == "id"
                ? "\(escapedName) \(mysqlType) NOT NULL AUTO_INCREMENT"
                : "\(escapedName) \(mysqlType)"
        }
        return "CREATE TABLE IF NOT EXISTS \(escapeIdentifier(tableName)) (\(columns.joined(separator: ", ")), PRIMARY KEY (`id`)) CHARACTER SET utf8mb4"
    }

    private func sqliteTypeToMySQL(_ sqliteType: String) -> String {
        switch sqliteType.uppercased() {
        case "INTEGER", "INT":
            return "BIGINT"
        case "REAL", "FLOAT", "DOUBLE":
            return "DOUBLE"
        case "BLOB":
            return "LONGBLOB"
        default:
            return "LONGTEXT"
        }
    }

    private func buildInsert(tableName: String, columns: [String], rows: [[String: Any]]) -> String {
        let columnList = columns.map { escapeIdentifier($0) }.joined(separator: ", ")
        let valueSets = rows.map { row -> String in
            let values = columns.map { column -> String in
                guard let value = row[column], (value is NSNull) == false else {
                    return "NULL"
                }
                return escapeMySQLValue(value)
            }
            return "(\(values.joined(separator: ", ")))"
        }
        return "INSERT IGNORE INTO \(escapeIdentifier(tableName)) (\(columnList)) VALUES \(valueSets.joined(separator: ", "))"
    }

    private func escapeIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    private func escapeMySQLValue(_ value: Any) -> String {
        switch value {
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\0", with: "\\0")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\u{001A}", with: "\\Z")
            return "'\(escaped)'"
        case let data as Data:
            return "0x\(data.map { String(format: "%02x", $0) }.joined())"
        default:
            return "'\(value)'"
        }
    }
}

public enum MySQLDirectSyncError: Error, LocalizedError {
    case invalidConfiguration
    case connectionCancelled
    case connectionClosed
    case unexpectedPacket(String)
    case authFailed(String)
    case queryError(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "MySQL configuration is incomplete"
        case .connectionCancelled:
            return "MySQL connection was cancelled"
        case .connectionClosed:
            return "MySQL connection was closed"
        case .unexpectedPacket(let message):
            return "Unexpected MySQL packet: \(message)"
        case .authFailed(let message):
            return "MySQL authentication failed: \(message)"
        case .queryError(let message):
            return "MySQL query error: \(message)"
        case .emptyResponse:
            return "MySQL returned an empty response"
        }
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
