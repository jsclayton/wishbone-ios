import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// Answers the device's next pull with the gift as the instance sends it, edited: `GET /versions` names it with a
/// new version, and `GET /gifts/{id}` gives the edited body. Returns when the copy holds it.
///
/// The test needs a server of its own, because the canned answer stands for every row of `GET /versions`.
@MainActor
func answer(
  _ gift: Fixture.Gift, as person: Fixture.Person, to session: SessionModel, on instance: Instance,
  edited edit: (inout [String: JSON]) -> Void
) async throws {
  guard case .object(var body) = try await person.signedIn().get("/gifts/\(gift.id)") else {
    Issue.record("The gift is not an object")
    return
  }
  edit(&body)
  // A new version for each answer, so the pull fetches the gift again.
  let version = "\"canned-\(UUID().uuidString)\""
  var entries = try #require(try await person.signedIn().get("/versions")["data"].array)
  entries = entries.map { entry in
    guard entry["kind"] == "gift", entry["id"].string == gift.id else { return entry }
    return ["kind": "gift", "id": entry["id"], "version": .string(version), "list_id": nil, "item_id": nil]
  }
  instance.conditioner.answer(
    NetworkConditioner.Route("GET", "/versions"),
    with: .init(
      status: 200, headers: ["Content-Type": "application/json", "ETag": "\"canned\""],
      body: try JSON.object(["data": .array(entries)]).data))
  instance.conditioner.answer(
    NetworkConditioner.Route("GET", "/gifts/\(gift.id)"),
    with: .init(
      status: 200, headers: ["Content-Type": "application/json", "ETag": version],
      body: try JSON.object(body).data))
  await session.syncNow()
  await until { session.gift(id: gift.id)?.version == version }
}
