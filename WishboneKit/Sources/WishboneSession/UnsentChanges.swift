import Foundation
import WishboneAPI

// The unsent changes: the writes that show at once and reach the instance when it answers. See ADR 0006, "Unsent
// changes" and "Unsent changes, sign-out, and late refusals" in `docs/spec.md`, and `Journal.swift`.
//
// - A change is saved in the journal, and every window shows it at once. Then a sync starts, which sends it.
// - A sync sends the unsent changes first, one at a time, in order, then pulls. So the pull after the last change
//   comes in the same sync, after its answer, and an answer in flight is never undone by a pull of the same sync.
// - An instance that can't be reached never refuses: the change waits, and never expires.
// - A refusal rolls the change back in every window, and waits to show once, the next time a window comes to the
//   foreground.
// - Sign-out tries to send first. Sign-out and the API's own 401 discard the journal with the database.

extension SessionModel {
  // MARK: - Mark bought

  /// Mark bought: sets or clears the giver's private mark on one of their open gifts, as an unsent change. It shows
  /// at once, in every window, and then a sync sends it, now or when the instance answers. See "Mark bought" in
  /// `docs/screens/gifts.md` and `docs/screens/gift.md`.
  ///
  /// It does nothing for a gift that the copy doesn't hold, that the giver can't edit, or that already has the
  /// mark. It returns when the change is in the journal and published, and doesn't wait for the sync.
  public func markBought(gift id: String, _ isBought: Bool) async {
    guard !hasEnded, let gift = gift(id: id), gift.state == .open, gift.canEdit, gift.isBought.value != isBought
    else { return }
    await record(.markBought(giftID: id, isBought: isBought), title: gift.title)
  }

  /// Saves an unsent change in the journal, publishes it, so every window shows it at once, and starts a sync,
  /// which sends it. It doesn't wait for the sync.
  func record(_ action: UnsentChange.Action, title: String) async {
    await record([LocalDatabase.NewChange(action, title: title)])
  }

  /// Saves the unsent changes in the journal, in order, in one change, publishes them, so every window shows them
  /// at once, and starts a sync, which sends them. It doesn't wait for the sync.
  func record(_ changes: [LocalDatabase.NewChange]) async {
    do {
      try await database.record(changes)
    } catch {
      Log.fault(.session, "The journal can't take an unsent change.", detail: "\(error)")
      return
    }
    await publishNow()
    Task { await syncNow() }
  }

  // MARK: - Sending

  /// Sends the unsent changes, one at a time, in the journal's order, until none is left or one can't be sent. A
  /// sync does this first. One send runs at a time: a call while one runs waits for it, and then sends what is
  /// left.
  ///
  /// It ends as a pull does: `succeeded` when it left no change that it could send, `unreachable` when the instance
  /// can't be reached, `refused` when the instance answered and the change must wait (a version block, too many
  /// requests), `faulted` on a journal or a copy that can't be read or written, `cancelled` on a cancel or the end
  /// of the session, and `endedByServer` on the API's own 401.
  func sendUnsentChanges() async -> PullEnd {
    while let earlier = sending {
      _ = await earlier.value
      if sending == earlier { sending = nil }
    }
    guard !hasEnded else { return .cancelled }
    let task = Task { await sendEach() }
    sending = task
    let end = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if sending == task { sending = nil }
    return end
  }

  /// Tries to send the unsent changes before a sign-out. See "Sign out" in `docs/spec.md`. Whatever happens, the
  /// sign-out goes on, and the journal goes with the database.
  func sendBeforeSignOut() async {
    guard !hasEnded, let count = try? await database.unsentChangeCount(), count > 0 else { return }
    _ = await sendUnsentChanges()
  }

  /// The send: each unsent change in turn, the oldest first.
  ///
  /// Diagnostics: a refusal is captured by its method, its path template and the server's code, except a 404 or a
  /// 410, for something deleted elsewhere, and a 400 or a 422, which the client has captured already. A journal or a copy
  /// that can't be read or written is captured by the error's domain and code. An unreachable instance, a cancel,
  /// and the API's own 401 never are.
  private func sendEach() async -> PullEnd {
    while true {
      guard !hasEnded, !Task.isCancelled else { return .cancelled }
      let change: UnsentChange
      do {
        guard let next = try await database.firstUnsentChange() else { return .succeeded }
        change = next
      } catch {
        return copyFailed(error, "The journal can't be read.")
      }
      do {
        let answer: UnsentChange.Answer
        do {
          answer = try await send(change)
        } catch .undecodable {
          // The instance took the change, and its answer can't be read. The client has captured it. The change is
          // sent, and the pull brings the row.
          answer = .none
        }
        // The session ended while the answer was on its way. The database is gone, and stays gone.
        guard !hasEnded, !Task.isCancelled else { return .cancelled }
        try await database.accept(change, answer: answer)
      } catch APIError.unreachable {
        return .unreachable
      } catch APIError.cancelled {
        return .cancelled
      } catch APIError.unauthorized {
        return .endedByServer
      } catch APIError.appTooOld {
        blockAppTooOld()
        return .refused
      } catch APIError.refused(let refusal) where Self.waits(refusal) {
        // The instance didn't decide the change. It waits for the next sync.
        return .refused
      } catch APIError.refused(let refusal) {
        guard !hasEnded, !Task.isCancelled else { return .cancelled }
        do {
          try await database.refuse(change, refusal: refusal)
        } catch {
          return copyFailed(error, "The journal can't take a late refusal.")
        }
        if Self.isCaptured(refusal) { diagnostics.capture(.refused(refusal.route, code: refusal.code)) }
      } catch is CancellationError {
        return .cancelled
      } catch {
        return copyFailed(error, "The copy can't take the answer of an unsent change.")
      }
    }
  }

  /// Sends one unsent change, and gives the server's answer. An unclaim, a delete and a decline have none. An
  /// upload's answer is the image, and a create's is the item, each by the server's ID. An item's edit and a move have
  /// the item as their answer, and a store link's price edit the link.
  ///
  /// An unclaim of a gift that is gone (a 404) is done: it was unclaimed, merged, or restored from elsewhere, and the
  /// giver no longer has it, which is what they asked for. So the gift leaves the copy, and nothing is said.
  private func send(_ change: UnsentChange) async throws(APIError) -> UnsentChange.Answer {
    switch change.action {
    case .markBought(let id, _), .setFromLabel(let id, _), .setNote(let id, _), .lowerQuantity(let id, _),
      .setOccasion(let id, _):
      return .gift(try await client.updateGift(id, change.action.giftChanges, key: change.key))
    case .unclaim(let id):
      do {
        try await client.unclaimGift(id, key: change.key)
      } catch .refused(let refusal) where refusal.status == 404 {
        // Gone already.
      }
      return .none
    case .acknowledge(let id, let flag):
      return .gift(try await client.acknowledgeGift(id, codes: [flag], key: change.key))
    case .editList(let id, let changes):
      return .list(try await client.updateList(id, changes, key: change.key))
    case .deleteList(let id):
      try await client.deleteList(id, key: change.key)
      return .none
    case .acceptInvitation(let invitation):
      return .list(try await client.acceptInvitation(invitation.invitationID, key: change.key))
    case .declineInvitation(let id):
      try await client.declineInvitation(id, key: change.key)
      return .none
    case .uploadImage(let id):
      // An upload whose bytes the journal doesn't hold can't be sent. It leaves, and the item goes without it.
      guard let file = await unsentFile(id) else { return .none }
      let image = try await client.uploadImage(file, key: change.key)
      // An image that the user just uploaded goes into the cache under its new address.
      await images.keep(file, for: image)
      return .image(image)
    case .createItem(let item):
      return .item(try await client.createItem(item.newItem, onList: item.listID, key: change.key))
    case .editItem(let id, let changes):
      return .item(try await client.updateItem(id, changes.sent, key: change.key))
    case .deleteItem(let id, _):
      try await client.deleteItem(id, key: change.key)
      return .none
    case .editStoreLink(let edit):
      return .storeLink(
        try await client.updateStoreLink(
          edit.storeLinkID, ofItem: edit.itemID, StoreLinkChanges(priceMinor: edit.priceMinor), key: change.key))
    case .deleteStoreLink(let itemID, let id):
      try await client.deleteStoreLink(id, ofItem: itemID, key: change.key)
      return .none
    case .moveItem(let move):
      // Only `list_id`: never a field that the user didn't change.
      return .item(try await client.updateItem(move.itemID, ItemChanges(listID: move.toListID), key: change.key))
    }
  }

  /// The bytes that the upload sends, from the journal. Nil when it holds none, or can't be read.
  private func unsentFile(_ id: String) async -> Data? {
    do {
      guard let file = try await database.unsentFile(id) else {
        Log.fault(.session, "An unsent upload has no file.")
        return nil
      }
      return file
    } catch {
      Log.fault(.session, "The journal can't be read.", detail: "\(error)")
      return nil
    }
  }

  /// Whether the instance answered without deciding the change: too many requests, a request that took too long,
  /// or the same change still running from an earlier send. The change waits.
  private static func waits(_ refusal: APIError.Refusal) -> Bool {
    refusal.status == 408 || refusal.status == 429 || refusal.code.text == "idempotency_key_in_use"
  }

  /// Whether a late refusal is captured here: never a 404 or a 410, for something deleted elsewhere, and never a 400
  /// or a 422 of a write, which the client captures for every write. See "Never captured" in `docs/spec.md`.
  private static func isCaptured(_ refusal: APIError.Refusal) -> Bool {
    ![404, 410].contains(refusal.status) && !(refusal.route.isWrite && [400, 422].contains(refusal.status))
  }

  // MARK: - Late refusals

  /// Shows the late refusals that wait, in the window that came to the foreground, in one alert. They leave the
  /// journal as the alert shows, so they show once, and never again.
  ///
  /// While the alert shows in a window that is in the foreground, or only inactive, it stays there, and the
  /// refusals that came since wait for it to close. An alert whose window went to the background, or closed, before
  /// it was closed moves to this window, with the refusals that came since, so none is lost.
  func showLateRefusals(in window: UUID) async {
    guard !hasEnded, !lateRefusalAlertShows else { return }
    let refusals: [LateRefusal]
    do {
      refusals = try await database.lateRefusals()
    } catch {
      Log.fault(.session, "The journal can't be read.", detail: "\(error)")
      return
    }
    // Another window may have shown them meanwhile.
    guard !hasEnded, !lateRefusalAlertShows else { return }
    let earlier = lateRefusalAlert?.refusals ?? []
    let new = refusals.filter { refusal in !earlier.contains { $0.id == refusal.id } }
    guard !earlier.isEmpty || !new.isEmpty else { return }
    lateRefusalAlert = LateRefusalAlert(window: window, refusals: earlier + new)
    guard !new.isEmpty else { return }
    do {
      try await database.removeLateRefusals(new.map(\.id))
    } catch {
      Log.fault(.session, "The journal can't forget the late refusals.", detail: "\(error)")
    }
  }

  /// The alert of late refusals in `window` has closed. An alert that has moved to another window since stays: the
  /// window it left may say that its own alert closed as it goes, and the refusals have left the journal already.
  public func lateRefusalsShown(in window: UUID) {
    guard lateRefusalAlert?.window == window else { return }
    lateRefusalAlert = nil
  }
}
