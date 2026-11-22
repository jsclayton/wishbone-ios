import TestSupport
import Testing
import WishboneSession

/// The kinds of entry of `GET /versions` that another test on the shared server changes for every user: each
/// standard family adds an occasion for everyone, and each new user joins the users of every such occasion. The
/// admin's groups of an occasion go with them. `untilInStep(_:as:)` leaves them out, so that it never waits for
/// a change that the device's sync didn't see.
private let changedByOtherTests: Set<String> = ["occasion", "users_of_occasion", "occasion_groups"]

/// What the session publishes from the copy, as the entries of `GET /versions` are: `kind id version`, for every
/// kind but those of `changedByOtherTests`. A recipient row is named by its list and its user, an item by its list
/// too, and a store link by its item too.
@MainActor
private func publishedEntries(of session: SessionModel) -> Set<String> {
  var entries: Set<String> = []
  for list in session.lists {
    entries.insert("list \(list.id) \(list.version)")
    for row in session.recipients(ofList: list.id) {
      entries.insert("list_recipient \(row.listID)/\(row.userID) \(row.version)")
    }
    for item in session.items(onList: list.id) {
      entries.insert("item \(item.listID)/\(item.id) \(item.version)")
      for link in session.storeLinks(ofItem: item.id) {
        entries.insert("store_link \(link.itemID)/\(link.id) \(link.version)")
      }
    }
  }
  for invitation in session.invitations {
    entries.insert("invitation \(invitation.id) \(invitation.version)")
  }
  for gift in session.gifts {
    entries.insert("gift \(gift.id) \(gift.version)")
  }
  for user in session.users {
    entries.insert("\(user.isSummary ? "user_summary" : "user") \(user.id) \(user.version)")
  }
  for group in session.groups {
    entries.insert("group \(group.id) \(group.version)")
  }
  for membership in session.memberships where !changedByOtherTests.contains(membership.kind.rawValue) {
    entries.insert("\(membership.kind.rawValue) \(membership.ownerID) \(membership.version)")
  }
  return entries
}

/// What the instance names for the person now, for every kind but those of `changedByOtherTests`, named as
/// `publishedEntries(of:)` names the copy's. The person's own session asks, not the device.
private func entries(namedFor person: Fixture.Person) async throws -> Set<String> {
  let data = try await person.signedIn().get("/versions")["data"].array ?? []
  return Set(
    data.compactMap { entry in
      let kind = entry["kind"].string ?? ""
      guard !changedByOtherTests.contains(kind) else { return nil }
      let id = entry["id"].string ?? ""
      let version = entry["version"].string ?? ""
      return switch kind {
      case "list_recipient", "item": "\(kind) \(entry["list_id"].string ?? "")/\(id) \(version)"
      case "store_link": "\(kind) \(entry["item_id"].string ?? "")/\(id) \(version)"
      default: "\(kind) \(id) \(version)"
      }
    })
}

/// Waits until the session publishes what the instance names for the person, each thing with its version, for
/// every kind but the occasions'.
///
/// A sync writes each thing when its answer arrives, and the session publishes each write as its own change, a
/// moment after it. So a sync can return before the session publishes its last write, and a test that reads
/// after a sync waits for what it reads. This is that wait for a test that reads the whole copy, on the shared
/// server too. The occasions come before every list, so the session has published them by the time it publishes
/// the lists of a first sync.
///
/// The admin sees every user and group of the instance, which other tests change. So a test of the admin that
/// waits here has a server of its own.
@MainActor
func untilInStep(_ session: SessionModel, as person: Fixture.Person, sourceLocation: SourceLocation = #_sourceLocation)
  async throws
{
  let named = try await entries(namedFor: person)
  await until { publishedEntries(of: session) == named }
  #expect(publishedEntries(of: session) == named, sourceLocation: sourceLocation)
}
