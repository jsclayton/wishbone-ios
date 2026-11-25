import GRDB
import Synchronization

/// The rows that the answers of writes that wait for the server put into the copy, each with the number of its
/// answer. "An answer in flight wins over a pull for the same thing" (see "Unsent changes" in `docs/spec.md`).
///
/// A pull writes each thing when its answer arrives, and its answers can be older than a write that waits for the
/// server: a claim, Add, a block or an unblock, and the profile gate. Its `GET /versions` can have been answered
/// before the server made the change, so it removes the new row as absent, and a body that it fetched before the
/// change puts the old row back. So the pull takes a mark before it asks (`mark()`), and each of its changes puts
/// back the rows that an answer saved or removed after that mark, as the answer left them (see
/// `LocalDatabase.change`). The pull never takes them away, not even for a moment.
///
/// A pull that an answer came during keeps no `ETag` of `GET /versions`, because the copy holds the answer's rows where
/// the pull's answer named others. The next pull takes a mark after the answer, and the server is the authority
/// again: the write's own rows are no longer kept from it. The session model still runs one more sync after a sync that a write came during (see
/// `SessionModel.syncAgainIfSyncing()`), so a row that the pull left as the answer had it is fetched again.
///
/// The record is in memory only: a pull never outlives the app. Every copy of a `LocalDatabase` shares it. It holds
/// one entry for each row that the user's own writes of this session answered, so it stays small.
final class Answers: Sendable {
  /// Where a pull starts: the answers that come after it win over the pull's changes.
  struct Mark: Sendable, Comparable {
    fileprivate let number: UInt64

    static func < (lhs: Mark, rhs: Mark) -> Bool { lhs.number < rhs.number }
  }

  /// The rows of one table that an answer saved or removed: those whose column has the value, or every row.
  struct Rows: Hashable, Sendable {
    let table: String

    /// The column and its value. Nil for every row of the table.
    let filter: Filter?

    struct Filter: Hashable, Sendable {
      let column: String
      let value: String
    }

    /// The row with the ID.
    static func row<Record: TableRecord>(_ id: String, of record: Record.Type) -> Rows {
      Rows(table: record.databaseTableName, filter: Filter(column: "id", value: id))
    }

    /// The store links of the item: an item's answer has them all, in its body.
    static func storeLinks(ofItem id: String) -> Rows {
      Rows(table: StoreLinkRow.databaseTableName, filter: Filter(column: "itemID", value: id))
    }

    /// Every row of the table.
    static func all<Record: TableRecord>(of record: Record.Type) -> Rows {
      Rows(table: record.databaseTableName, filter: nil)
    }
  }

  private struct State {
    /// How many answers came so far.
    var count: UInt64 = 0

    /// The number of the last answer that saved or removed each of the rows.
    var rows: [Rows: UInt64] = [:]
  }

  private let state = Mutex(State())

  /// A mark after every answer that came so far.
  func mark() -> Mark {
    Mark(number: state.withLock { $0.count })
  }

  /// Notes that an answer saved or removed the rows now. Its change calls this inside its transaction, so the
  /// answers are numbered in the order of the changes.
  func note(_ rows: [Rows]) {
    guard !rows.isEmpty else { return }
    state.withLock { state in
      state.count += 1
      for each in rows {
        state.rows[each] = state.count
      }
    }
  }

  /// The rows that an answer saved or removed after the mark, in one order.
  func rows(after mark: Mark) -> [Rows] {
    state.withLock { state in
      state.rows.filter { $0.value > mark.number }.keys.sorted {
        ($0.table, $0.filter?.column ?? "", $0.filter?.value ?? "")
          < ($1.table, $1.filter?.column ?? "", $1.filter?.value ?? "")
      }
    }
  }
}

extension LocalDatabase {
  /// The rows as they are now, to put back after a pull's change.
  struct KeptRows {
    let rows: Answers.Rows
    let values: [Row]
  }

  /// Reads the rows that an answer saved or removed after the mark, as the copy holds them before a pull's change.
  static func answered(after mark: Answers.Mark, by answers: Answers, in database: Database) throws -> [KeptRows] {
    try answers.rows(after: mark).map { rows in KeptRows(rows: rows, values: try values(of: rows, in: database)) }
  }

  /// Puts the rows back as they were before a pull's change, where the change touched them: a pull never removes or
  /// overwrites what an answer that came after its mark saved, and never brings back what such an answer removed.
  static func putBack(_ kept: [KeptRows], in database: Database) throws {
    for each in kept where try values(of: each.rows, in: database) != each.values {
      let (condition, arguments) = filter(of: each.rows)
      try database.execute(sql: "DELETE FROM \"\(each.rows.table)\"\(condition)", arguments: arguments)
      for row in each.values {
        let columns = row.columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let marks = Array(repeating: "?", count: row.count).joined(separator: ", ")
        try database.execute(
          sql: "INSERT INTO \"\(each.rows.table)\" (\(columns)) VALUES (\(marks))",
          arguments: StatementArguments(row.databaseValues))
      }
    }
  }

  private static func values(of rows: Answers.Rows, in database: Database) throws -> [Row] {
    let (condition, arguments) = filter(of: rows)
    return try Row.fetchAll(
      database, sql: "SELECT * FROM \"\(rows.table)\"\(condition) ORDER BY id", arguments: arguments)
  }

  private static func filter(of rows: Answers.Rows) -> (String, StatementArguments) {
    guard let filter = rows.filter else { return ("", []) }
    return (" WHERE \"\(filter.column)\" = ?", [filter.value])
  }
}
