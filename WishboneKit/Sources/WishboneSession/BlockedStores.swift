import Foundation
import WishboneAPI

/// What the admin typed or pasted in the Add form of Blocked stores: a host name, such as `example.com`, or a web
/// address of the store. See `docs/screens/blocked-stores.md`.
///
/// It is the text to send, with no space at either end, when it names a host. The server names the store by its
/// host, and is the judge: this check only marks text that can't be a host name or a web address before anything
/// is sent. It is no stricter than the server's, so it never marks a store that the server would block.
public struct StoreEntry: Sendable, Equatable {
  /// The text that goes to the server.
  public let text: String

  /// Nil for text that is not a host name or a web address: empty, with a space in it, with no host, or with a
  /// host that has no dot, or a dot at either end, or two dots in a row.
  public init?(_ typed: String) {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
    let address = text.contains("://") ? text : "https://\(text)"
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http", let host = url.host(percentEncoded: false)?.lowercased()
    else { return nil }
    guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return nil }
    self.text = text
  }
}

/// How Add in Blocked stores ended. See "States" in `docs/screens/blocked-stores.md`.
public enum BlockOutcome: Sendable, Equatable {
  /// The server blocked the store, or it was blocked already. The copy holds it once.
  case blocked

  /// The text is not a host name or a web address. Nothing was sent, or the server refused it as such. The field
  /// is marked.
  case notAStore

  /// The instance can't be reached. Nothing changes.
  case unreachable

  /// The server refused the block for another reason.
  case refused(APIError.Refusal)

  /// A fault of the app, such as an answer that it can't read, or a session that ended.
  case failed
}

/// How Unblock in Blocked stores ended.
public enum UnblockOutcome: Sendable, Equatable {
  /// The server no longer blocks the store, and the copy no longer holds it.
  case unblocked

  /// The instance can't be reached. Nothing changes.
  case unreachable

  /// The server refused.
  case refused(APIError.Refusal)

  /// A fault of the app, such as a session that ended.
  case failed
}

extension SessionModel {
  /// Whether the session's user is the admin, as the copy says. False until the copy holds the user's record. Only
  /// the admin sees For the admin in Settings, and Blocked stores. See "Blocked stores" in `docs/spec.md`.
  public var isAdmin: Bool {
    user?.record?.isAdmin == true
  }

  /// Add in Blocked stores: blocks the store that the text names, with `POST /blocked-stores`. It waits for the
  /// server, and is never an unsent change. See "Other writes that wait for the server" in `docs/spec.md`.
  ///
  /// A store that is blocked already (409 `already_blocked`) counts as success. The server's answer doesn't name
  /// the store, so the copy reads the blocked stores again, and holds the store once.
  ///
  /// Diagnostics: a 422 is captured by the client, as the route and the code. Nothing else here.
  public func block(_ typed: String) async -> BlockOutcome {
    guard !hasEnded else { return .failed }
    guard let entry = StoreEntry(typed) else { return .notAStore }
    do {
      let store = try await client.blockStore(entry.text)
      guard !hasEnded else { return .failed }
      try await database.saveBlockedStore(store)
      return .blocked
    } catch APIError.refused(let refusal) where refusal.code == .alreadyBlocked {
      await readBlockedStoresAgain()
      return .blocked
    } catch APIError.refused(let refusal) where refusal.code == .invalidInput {
      return .notAStore
    } catch let error as APIError {
      if let refusal = await outcome(of: error) { return .refused(refusal) }
      if case .unreachable = error { return .unreachable }
      return .failed
    } catch is CancellationError {
      return .failed
    } catch {
      Log.fault(.session, "The copy can't take the blocked store.", detail: "\(error)")
      return .failed
    }
  }

  /// Unblock in Blocked stores: takes the store off the blocked list, with `DELETE /blocked-stores/{id}`. It waits
  /// for the server, and is never an unsent change. The copy holds the store until the server answers.
  ///
  /// A store that is gone from the list already (a 404) is unblocked: it goes from the copy too.
  ///
  /// Diagnostics: never here. The client reports each error as its side asks.
  public func unblock(_ store: BlockedStoreRow) async -> UnblockOutcome {
    guard !hasEnded else { return .failed }
    do {
      do {
        try await client.unblockStore(store.id)
      } catch APIError.refused(let refusal) where refusal.status == 404 {
        // Someone else unblocked it first.
      }
      guard !hasEnded else { return .failed }
      try await database.removeBlockedStore(store.id)
      return .unblocked
    } catch let error as APIError {
      if let refusal = await outcome(of: error) { return .refused(refusal) }
      if case .unreachable = error { return .unreachable }
      return .failed
    } catch is CancellationError {
      return .failed
    } catch {
      Log.fault(.session, "The copy can't drop the blocked store.", detail: "\(error)")
      return .failed
    }
  }

  /// Reads the blocked stores again, after a block that the server says it had already. An instance that can't be
  /// reached now leaves the copy as it is: the next sync reads them.
  private func readBlockedStoresAgain() async {
    guard let stores = try? await client.blockedStores(), !hasEnded else { return }
    do {
      try await database.replaceBlockedStores(with: stores.rows)
    } catch is CancellationError {
    } catch {
      Log.fault(.session, "The copy can't take the blocked stores.", detail: "\(error)")
    }
  }

  /// The refusal of an admin's write, for its screen to show. Nil for the rest, which the screen shows otherwise,
  /// after the session has done what each asks: the API's own 401 ends the session, and its 410 shows the block for
  /// an app that is too old.
  private func outcome(of error: APIError) async -> APIError.Refusal? {
    switch error {
    case .refused(let refusal):
      return refusal
    case .unauthorized:
      await endedByServer(self)
      return nil
    case .appTooOld:
      blockAppTooOld()
      return nil
    case .unreachable, .cancelled, .undecodable:
      return nil
    }
  }
}
