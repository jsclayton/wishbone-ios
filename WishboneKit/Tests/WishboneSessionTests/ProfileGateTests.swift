import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The profile gate, at the session model's seam, against the real server. See "The profile gate" in
/// `docs/spec.md`, and `docs/screens/profile-gate.md`.
@Suite("The profile gate", .timeLimit(.minutes(1)))
@MainActor
final class ProfileGateTests {
  typealias Route = NetworkConditioner.Route

  static let update = Route("PATCH", "/users/me")
  static let confirm = Route("POST", "/users/me/confirm-profile")
  static let upload = Route("POST", "/images")

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// A device signed in as the person, with the person in its copy. The report of the time zone, which is a
  /// `PATCH /users/me` too, has ended and is in the copy, and the conditioner forgets the requests of the sign-in.
  private func signedIn(
    as person: Fixture.Person, on instance: Instance? = nil, storage: SessionStorage = .memory
  ) async throws -> Device {
    let instance = instance ?? self.instance
    let device = instance.device(storage: storage)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.user?.record?.timezone.value == "UTC" }
    signInRequests = instance.conditioner.requests.count
    return device
  }

  /// How many requests the sign-in made. The test's own come after them.
  private var signInRequests = 0

  /// The user's record, as the server has it.
  private func record(of person: Fixture.Person) async throws -> JSON {
    try await person.signedIn().get("/users/me")
  }

  /// The requests on the route since the sign-in.
  private func requests(on route: Route) -> [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests.dropFirst(signInRequests).filter { $0.isOn(route) }
  }

  @Test("A user with no confirmed profile gets the gate after sign-in and at each launch, and a confirmed one doesn't")
  func gate() async throws {
    let robin = try await instance.person("Robin")
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: robin, storage: .folder(folder.url))
    #expect(try #require(device.session).needsProfileGate)

    // A relaunch: the copy says so at once, before anything is asked of the instance.
    let relaunched = instance.device(storage: .folder(folder.url))
    #expect(try #require(relaunched.session).needsProfileGate)

    // Another device, so the session keychain is its own.
    let other = try await Instance()
    let sam = try await other.person("Sam")
    try await other.builder.confirmProfile(of: sam)
    let confirmed = try await signedIn(as: sam, on: other)
    #expect(try #require(confirmed.session).needsProfileGate == false)
  }

  @Test("Continue sends only the changed fields, then confirms, and the gate goes from every window")
  func continueConfirms() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    // Two windows read the device's one session model.
    let first = try #require(device.session)
    let second = try #require(device.session)
    let user = try #require(first.user)

    var draft = ProfileDraft(user)
    draft.lastName = "Fischer"
    draft.birthday = PartialDate(month: 6, day: 15, year: 2014)
    #expect(await first.confirmProfile(draft) == .confirmed)

    // The answer reaches the copy, and every window reads it.
    await until { !first.needsProfileGate }
    #expect(!second.needsProfileGate)
    let patches = requests(on: Self.update)
    #expect(patches.count == 1)
    let sent = try JSON(parsing: try #require(patches.first).body)
    #expect(sent == ["last_name": "Fischer", "birthday": ["month": 6, "day": 15, "year": 2014]])
    #expect(requests(on: Self.confirm).count == 1)
    #expect(requests(on: Self.upload).isEmpty)

    let record = try await record(of: robin)
    #expect(record["last_name"].string == "Fischer")
    #expect(record["birthday"]["year"].number == 2014)
    #expect(record["profile_confirmed_at"].string != nil)
    #expect(first.user?.record?.lastName == "Fischer")
  }

  @Test("Clearing sends null: a last name of spaces, a birthday with no year, and Remove only with an avatar")
  func clearing() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)
    var draft = ProfileDraft(try #require(session.user))
    draft.lastName = "Fischer"
    draft.birthday = PartialDate(month: 6, day: 15, year: 2014)
    #expect(await session.confirmProfile(draft) == .confirmed)
    await until { session.user?.record?.lastName == "Fischer" }

    // Robin has no avatar, so Remove sends nothing for it.
    var clearing = ProfileDraft(try #require(session.user))
    clearing.lastName = "   "
    clearing.birthday = PartialDate(month: 6, day: 15)
    clearing.photo = .remove
    #expect(await session.confirmProfile(clearing) == .confirmed)

    let patches = requests(on: Self.update)
    #expect(patches.count == 2)
    let sent = try JSON(parsing: try #require(patches.last).body)
    #expect(sent == ["last_name": nil, "birthday": ["month": 6, "day": 15, "year": nil]])
    let record = try await record(of: robin)
    #expect(record["last_name"].isNull)
    #expect(record["birthday"]["year"].isNull)
    await until { session.user?.record?.lastName == nil && session.user?.record?.birthday.year == nil }
  }

  @Test("A draft with nothing changed sends no PATCH, and confirms")
  func nothingChanged() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)

    #expect(await session.confirmProfile(ProfileDraft(try #require(session.user))) == .confirmed)

    #expect(requests(on: Self.update).isEmpty)
    #expect(requests(on: Self.confirm).count == 1)
    await until { !session.needsProfileGate }
  }

  @Test("With the network dropped, nothing is confirmed, and Try again sends what is left")
  func offline() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)
    var draft = ProfileDraft(try #require(session.user))
    draft.name = "Robyn"

    // The network goes after the save, while the confirmation is on its way.
    let hold = instance.conditioner.hold(Self.confirm, at: .request)
    async let continuing = session.confirmProfile(draft)
    await hold.waitUntilHeld()
    instance.conditioner.dropEverything()
    #expect(await continuing == .unreachable)

    #expect(try await record(of: robin)["profile_confirmed_at"].isNull)
    // The save went through, and is in the copy.
    await until { session.user?.name == "Robyn" }
    #expect(session.needsProfileGate)

    // Try again, with the same draft: the fields are saved already, so only the confirmation goes.
    instance.conditioner.passEverything()
    #expect(await session.confirmProfile(draft) == .confirmed)
    #expect(requests(on: Self.update).count == 1)
    await until { !session.needsProfileGate }
    #expect(try await record(of: robin)["name"].string == "Robyn")
  }

  @Test("With no network at all, nothing is sent, and the copy is as it was")
  func offlineFromTheStart() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)
    let before = try #require(session.user)
    var draft = ProfileDraft(before)
    draft.lastName = "Fischer"

    instance.conditioner.dropEverything()
    #expect(await session.confirmProfile(draft) == .unreachable)

    #expect(session.user == before)
    #expect(session.needsProfileGate)
    instance.conditioner.passEverything()
    #expect(try await record(of: robin)["last_name"].isNull)
  }

  @Test("A 422 invalid_input names the fields to mark, and nothing is confirmed")
  func invalidInput() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)
    var draft = ProfileDraft(try #require(session.user))
    draft.name = String(repeating: "R", count: 101)

    let outcome = await session.confirmProfile(draft)

    guard case .refused(let refusal) = outcome else {
      Issue.record("Continue gave \(outcome), not a refusal.")
      return
    }
    #expect(refusal.status == 422)
    #expect(refusal.code == .invalidInput)
    #expect(refusal.fields == ["name"])
    #expect(requests(on: Self.confirm).isEmpty)
    #expect(session.needsProfileGate)
  }

  @Test("A photo is uploaded and becomes the avatar, and Remove clears it")
  func photo() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)
    var draft = ProfileDraft(try #require(session.user))
    draft.photo = .new(FixtureBuilder.onePixelPNG)

    #expect(await session.confirmProfile(draft) == .confirmed)

    await until { session.user?.avatar != nil }
    let avatar = try #require(session.user?.avatar)
    #expect(try await record(of: robin)["avatar"]["id"].string == avatar.id)
    #expect(requests(on: Self.upload).count == 1)
    // The avatar's request carries the token, to the instance address only.
    let request = try #require(session.imageRequest(avatar))
    #expect(request.url?.absoluteString == "\(try instance.address.text)\(avatar.url)")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)

    // Remove, from the next draft. The profile is confirmed already, and stays so.
    var removing = ProfileDraft(try #require(session.user))
    removing.photo = .remove
    #expect(await session.confirmProfile(removing) == .confirmed)
    await until { session.user?.avatar == nil }
    #expect(try await record(of: robin)["avatar"].isNull)
  }

  @Test("A file that is not an image is refused as image_invalid, and the old photo stays")
  func notAnImage() async throws {
    let robin = try await instance.person("Robin")
    let oldPhoto = try await instance.builder.avatar(for: robin)
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)
    #expect(session.user?.avatar?.id == oldPhoto)
    var draft = ProfileDraft(try #require(session.user))
    draft.lastName = "Fischer"
    draft.photo = .new(Data("This is not an image.".utf8))

    let outcome = await session.confirmProfile(draft)

    guard case .photoRefused(let refusal) = outcome else {
      Issue.record("Continue gave \(outcome), not a refused photo.")
      return
    }
    #expect(refusal.code == .imageInvalid)
    // Nothing else was sent.
    #expect(requests(on: Self.update).isEmpty)
    #expect(requests(on: Self.confirm).isEmpty)
    #expect(session.user?.avatar?.id == oldPhoto)
    #expect(try await record(of: robin)["avatar"]["id"].string == oldPhoto)
    #expect(session.needsProfileGate)
  }

  @Test("The API's own 401 during Continue signs the device out, as a sync does")
  func endedByServer() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    let session = try #require(device.session)
    let kept = try #require(instance.keychain.read())
    try await APIClient(session: kept, userAgent: UserAgent(version: "1.0", isPad: false)).revokeCurrentSession()

    #expect(await session.confirmProfile(ProfileDraft(try #require(session.user))) == .failed)

    #expect(device.session == nil)
    #expect(device.signInState == .signedOutByServer(try instance.address))
    #expect(instance.keychain.read() == nil)
  }

  @Test("Sign out works from the gate")
  func signOutFromTheGate() async throws {
    let robin = try await instance.person("Robin")
    let device = try await signedIn(as: robin)
    #expect(try #require(device.session).needsProfileGate)

    await device.signOut()

    #expect(device.session == nil)
    #expect(device.signInState == .plain)
    #expect(instance.keychain.read() == nil)
    #expect(try await record(of: robin)["profile_confirmed_at"].isNull)
  }
}
