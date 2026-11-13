import Foundation
import SQLite3

/// opencode's database, read-only. One connection and one prepared statement live for as
/// long as the database file does; each query is a single statement, reset as soon as it is
/// stepped through, so no read transaction is ever held between looks (opencode's WAL
/// checkpoints are never blocked). Not thread-safe: the monitor's serial queue owns it.
final class OpencodeUsageSource: OpencodeRowSource {
    /// `time_created` first so SQLite walks its index; `json_extract` runs only on matches.
    static let query = """
        SELECT id, time_created, time_updated, json_extract(data, '$.tokens')
        FROM session_message
        WHERE type = 'assistant' AND time_updated > ?1 AND time_created >= ?2 AND time_created < ?3
        """

    let url: URL
    private var db: OpaquePointer?
    private var statement: OpaquePointer?
    private var openedInode: UInt64?

    init(url: URL) { self.url = url }

    deinit { close() }

    func close() {
        if let statement { sqlite3_finalize(statement) }
        if let db { sqlite3_close_v2(db) }
        statement = nil
        db = nil
        openedInode = nil
    }

    func rows(updatedAfterMs: Int64, createdFromMs: Int64, createdToMs: Int64) -> Result<[OpencodeRow], OpencodeReadError> {
        switch prepare() {
        case .failure(let error): return .failure(error)
        case .success(let statement):
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            sqlite3_bind_int64(statement, 1, updatedAfterMs)
            sqlite3_bind_int64(statement, 2, createdFromMs)
            sqlite3_bind_int64(statement, 3, createdToMs)
            var rows: [OpencodeRow] = []
            while true {
                let code = sqlite3_step(statement)
                switch code {
                case SQLITE_ROW:
                    guard let id = text(statement, 0) else { continue }
                    rows.append(OpencodeUsage.row(id: id, createdMs: sqlite3_column_int64(statement, 1),
                                                  updatedMs: sqlite3_column_int64(statement, 2),
                                                  tokensJSON: text(statement, 3)))
                case SQLITE_DONE:
                    return .success(rows)
                case SQLITE_BUSY, SQLITE_LOCKED:
                    return .failure(.busy)
                default:
                    let message = String(cString: sqlite3_errmsg(db))
                    // A replaced or corrupted file: drop the connection, reopen next time.
                    close()
                    return .failure(.failed("step \(code): \(message)"))
                }
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }

    /// Opens (or reopens, if the file was replaced) and prepares. Read-only by URI and flag.
    private func prepare() -> Result<OpaquePointer, OpencodeReadError> {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            close()
            return .failure(.missing)
        }
        if let statement, openedInode == UInt64(info.st_ino) { return .success(statement) }
        close()

        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = components.string else { return .failure(.failed("bad path")) }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            return .failure(.failed(message))
        }
        sqlite3_busy_timeout(handle, 100)
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v3(handle, Self.query, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil) == SQLITE_OK,
              let prepared else {
            let code = sqlite3_errcode(handle)
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close_v2(handle)
            return .failure(code == SQLITE_BUSY || code == SQLITE_LOCKED ? .busy : .schema(message))
        }
        db = handle
        statement = prepared
        openedInode = UInt64(info.st_ino)
        return .success(prepared)
    }
}
