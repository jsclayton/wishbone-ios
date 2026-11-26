import Foundation
import GRDB
import WishboneAPI

// Add link and Refresh prices, in the Edit item sheet and on an item's page. See "Edit item", States and Actions in
// `docs/screens/item.md`, and "Other writes that wait for the server" in `docs/spec.md`.
//
// **Each waits for the server.** The server reads the store's page during the request, and can refuse it: a store
// that the admin blocked, a read over the hourly limit, an eleventh link. So neither is an unsent change. With no
// connection, each says "Can't reach {address}", and nothing changes and nothing waits to be sent.
//
// **The answer goes into the copy at once,** as an answer that a pull which asked before it never undoes (see
// `Answers.swift`). The item comes with it: Add link gives an item with no price the link's price, and a refresh
// changes the links' prices and when they were read.
//
// A price edit and Remove are unsent changes, saved with Edit item (see `ItemEdits.swift`).

/// How Add link ended.
public enum StoreLinkOutcome: Sendable, Equatable {
  /// The server added the link, and read its page. The copy has it, as the server gave it.
  case added(StoreLinkRow)

  /// The instance can't be reached. Nothing was added, and nothing waits to be sent.
  case unreachable

  /// A link from a blocked store (422 `store_blocked`): nothing was added. It names the store.
  case blocked(store: String)

  /// The server refused it for another reason, such as `rate_limited` or `too_many_store_links`. Nothing was added.
  case refused(APIError.Refusal)

  /// A fault of the app, a session that ended, or text that is not a web address. Nothing was added.
  case failed
}

/// How Refresh prices ended.
public enum RefreshOutcome: Sendable, Equatable {
  /// The server read the links again: "Prices checked." The copy has the new prices, and when each was read.
  case checked

  /// The instance can't be reached. Nothing changes.
  case unreachable

  /// The server refused it, such as `rate_limited`. Nothing changes.
  case refused(APIError.Refusal)

  /// A fault of the app, or a session that ended.
  case failed
}

extension SessionModel {
  /// Add link: adds the pasted web address to the item as a store link, with `POST /items/{id}/store-links`. It
  /// waits for the server, which reads the page for its price, and is never an unsent change. Then it brings the
  /// item, with `GET /items/{id}`: an item with no price that never had one takes the link's.
  ///
  /// An item that waits to be created, by its stand-in ID, has no server's ID to add to yet. The unsent changes are
  /// sent first, so the server has it, and the link goes to the server's ID. When they can't be sent, it is
  /// `unreachable`, as for any item.
  ///
  /// It does nothing (`failed`) for text that is not an `http` or `https` address, for an item that the copy
  /// doesn't hold, and for one that the user can't edit.
  ///
  /// Diagnostics: never here. The client reports each error as its side asks: a 422 such as `too_many_store_links`
  /// is captured by its code, and a blocked store and a 429 never are.
  public func addStoreLink(_ text: String, toItem id: String) async -> StoreLinkOutcome {
    guard !hasEnded, case .link(let url, let store)? = SearchInput(text), let item = item(id: id), item.canEdit
    else { return .failed }
    let itemID: String
    switch await serverIDSendingFirst(item.id) {
    case .id(let id): itemID = id
    case .unreachable: return .unreachable
    case .notSent: return .failed
    }
    do {
      let link = try await client.addStoreLink(url, toItem: itemID)
      // The item's new price. Without it, the link is saved alone, and the next sync brings the item.
      let answered = try? await client.item(itemID)
      guard !hasEnded else { return .failed }
      try await database.saveAddedStoreLink(link, ofItem: itemID, item: answered)
      // A sync that runs now may have asked before the add. Its pull keeps the link, and one more sync asks after it.
      syncAgainIfSyncing()
      await publishNow()
      guard let row = storeLinks(ofItem: itemID).first(where: { $0.id == link.resource.id }) else { return .failed }
      return .added(row)
    } catch {
      switch await waitedOutcome(of: error) {
      case .unreachable: return .unreachable
      case .refused(let refusal) where refusal.code == .storeBlocked: return .blocked(store: store)
      case .refused(let refusal): return .refused(refusal)
      case .failed: return .failed
      }
    }
  }

  /// Whether the item's page offers Refresh prices: the server's `can_refresh_prices`. An item that waits to be
  /// created shows none, as the server doesn't have it yet (see `ItemRow(standingInFor:at:)`).
  public func offersRefreshPrices(onItem id: String) -> Bool {
    item(id: id)?.canRefreshPrices ?? false
  }

  /// Refresh prices: the server reads each store link's page again, with `POST /items/{id}/refresh-prices`. It
  /// waits for the server, and is never an unsent change. The item that the server gives back goes into the copy at
  /// once, with each link's new price and when it was read. A link that the server couldn't read keeps its price.
  ///
  /// It does nothing (`failed`) for an item that doesn't offer it (see `offersRefreshPrices(onItem:)`).
  ///
  /// Diagnostics: never here. A 429 is never captured.
  public func refreshPrices(ofItem id: String) async -> RefreshOutcome {
    guard !hasEnded, offersRefreshPrices(onItem: id), let item = item(id: id) else { return .failed }
    do {
      let answered = try await client.refreshPrices(ofItem: item.id)
      guard !hasEnded else { return .failed }
      try await database.save([answered], answering: true)
      // A sync that runs now may have asked before the refresh. Its pull keeps the new prices, and one more sync
      // asks after it.
      syncAgainIfSyncing()
      await publishNow()
      return .checked
    } catch {
      switch await waitedOutcome(of: error) {
      case .unreachable: return .unreachable
      case .refused(let refusal): return .refused(refusal)
      case .failed: return .failed
      }
    }
  }

  /// The server's ID of an item, for a write that waits for the server.
  private enum ServerID {
    case id(String)

    /// The item waits to be created, and the instance can't be reached.
    case unreachable

    /// The item waits to be created, and its create wasn't sent: the server refused it, so the item is gone, or
    /// something before it in the journal must wait.
    case notSent
  }

  /// The server's ID of the item. An item that waits to be created is sent first, with every unsent change before
  /// it, in the journal's order.
  private func serverIDSendingFirst(_ id: String) async -> ServerID {
    guard StandIn.isStandIn(id) else { return .id(id) }
    let end = await sendUnsentChanges()
    // Read with the journal: the copy's observation may not have published the server's ID yet.
    if let serverID = try? await database.unsentChangesAndStandIns().standIns[id] { return .id(serverID) }
    return end == .unreachable ? .unreachable : .notSent
  }

  /// What an error of a write that waits for the server means for its screen, after the session has done what the
  /// error asks: the API's own 401 ends the session, and its 410 shows the block for an app that is too old.
  private enum WaitedOutcome {
    case unreachable
    case refused(APIError.Refusal)
    case failed
  }

  private func waitedOutcome(of error: any Error) async -> WaitedOutcome {
    switch error {
    case let error as APIError:
      if let refusal = await outcome(of: error) { return .refused(refusal) }
      if case .unreachable = error { return .unreachable }
      return .failed
    case is CancellationError:
      return .failed
    default:
      Log.fault(.session, "The copy can't take the store links.", detail: "\(error)")
      return .failed
    }
  }
}

extension LocalDatabase {
  /// Saves a store link that Add link added, with the item as the server gives it now, in one change. With no item,
  /// which the instance didn't give after the add, the link goes at the end of the item's links, and the next sync
  /// brings the item.
  ///
  /// It is the server's answer to a write that waits for it: a pull that started before it doesn't change the item
  /// or its store links (see `Answers`).
  func saveAddedStoreLink(_ link: Versioned<StoreLink>, ofItem itemID: String, item: Versioned<Item>?) async throws {
    if let item, item.resource.id == itemID {
      try await save([item], answering: true)
      return
    }
    try await change(answering: [.row(itemID, of: ItemRow.self), .storeLinks(ofItem: itemID)]) { database in
      let position = try StoreLinkRow.filter(Column("itemID") == itemID).fetchCount(database)
      try StoreLinkRow(link.resource, ofItem: itemID, at: position, version: "").save(database)
    }
  }
}
