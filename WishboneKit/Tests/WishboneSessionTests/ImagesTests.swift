import Foundation
import TestSupport
import Testing
import WishboneAPI
import WishboneSession

/// The session's image cache, at the session model's seam, against the real server. See "Images" in
/// `docs/spec.md`, and "The API client" in `docs/architecture.md`.
@Suite("Images", .timeLimit(.minutes(1)))
@MainActor
struct ImagesTests {
  typealias Route = NetworkConditioner.Route

  let instance: Instance

  init() async throws {
    instance = try await Instance()
  }

  /// A family: Robin, with a photo, and two items on their primary list, each with an image, and Robin's child
  /// Sam, with a photo. Robin sees all four images.
  private struct Family {
    let robin: Fixture.Person
    let imageIDs: [String]
  }

  private func family() async throws -> Family {
    let builder = instance.builder
    let robin = try await builder.person("Robin")
    let sam = try await builder.person("Sam", parents: [robin])
    let list = try await builder.primaryList(of: robin)
    let kiteImage = try await builder.image(as: robin)
    _ = try await builder.item("Kite", on: list, as: robin, imageIDs: [kiteImage])
    let ballImage = try await builder.image(as: robin)
    _ = try await builder.item("Ball", on: list, as: robin, imageIDs: [ballImage])
    let robinAvatar = try await builder.avatar(for: robin)
    let samAvatar = try await builder.avatar(for: sam)
    return Family(robin: robin, imageIDs: [kiteImage, ballImage, robinAvatar, samAvatar])
  }

  /// A device signed in as the person, with the person's items in its copy.
  private func signedIn(
    as person: Fixture.Person, in folder: ScratchDirectory? = nil, network: any NetworkChanges = .unchanging
  ) async throws -> Device {
    let storage: SessionStorage = folder.map { .folder($0.url) } ?? .memory
    let device = instance.device(storage: storage, images: storage, network: network)
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    await until { session.primaryListItems.count == 2 }
    return device
  }

  private func imageRequests(of id: String) -> [NetworkConditioner.SeenRequest] {
    instance.conditioner.requests.filter { $0.isOn(Route("GET", "/images/\(id)")) }
  }

  private func image(of title: String, in session: SessionModel) throws -> ImageSummary {
    try #require(session.primaryListItems.first { $0.title == title }?.primaryImage)
  }

  /// The bytes that the server serves for the image, which it has made from the upload.
  private func served(_ image: ImageSummary, to person: Fixture.Person) async throws -> Data {
    try await person.signedIn().send("GET", String(image.url.dropFirst(TestServer.apiPrefix.count))).expecting(200)
      .body
  }

  private func imagesFolder(in folder: ScratchDirectory) -> URL {
    folder.url.appending(path: "Images", directoryHint: .isDirectory)
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  // MARK: - The token

  @Test("A request for an instance image has the token, and a request for a store's image has none")
  func token() async throws {
    let family = try await family()
    let device = try await signedIn(as: family.robin, network: TestNetwork(expensive: true))
    let session = try #require(device.session)
    let kite = try image(of: "Kite", in: session)

    let served = try await served(kite, to: family.robin)
    #expect(await session.images.data(for: kite) == served)
    let request = try #require(imageRequests(of: kite.id).only)
    #expect(request.headers["authorization"]?.hasPrefix("Bearer ") == true)
    #expect((request.headers["authorization"]?.count ?? 0) > "Bearer ".count)

    // A store's image, even at the instance address, goes with no token, through the system's default session.
    let store = try #require(APIClient.storeImageRequest(instance.conditioner.url("/store-image.png").absoluteString))
    #expect(store.value(forHTTPHeaderField: "Authorization") == nil)
    _ = try? await URLSession.shared.data(for: store)
    let seen = try #require(instance.conditioner.requests.first { $0.isOn(Route("GET", "/store-image.png")) })
    #expect(seen.headers["authorization"] == nil)
    #expect(APIClient.storeImageRequest("javascript:alert(1)") == nil)
  }

  @Test("The token never goes to another host, also after a redirect away from the instance")
  func noTokenElsewhere() async throws {
    let family = try await family()
    let device = try await signedIn(as: family.robin, network: TestNetwork(expensive: true))
    let session = try #require(device.session)
    let kite = try image(of: "Kite", in: session)
    let elsewhere = try await NetworkConditioner(to: instance.server.address)
    defer { elsewhere.stop() }
    let away = elsewhere.url("/images/\(kite.id)").absoluteString
    instance.conditioner.answer(
      Route("GET", "/images/\(kite.id)"), with: .init(status: 302, headers: ["Location": away]))

    // The redirect is not followed, so the image doesn't show, and the other host gets nothing.
    #expect(await session.images.data(for: kite) == nil)
    #expect(imageRequests(of: kite.id).count == 1)
    #expect(elsewhere.requests.isEmpty)

    // An image whose address is another host's is never asked for.
    let foreign = try JSONDecoder().decode(
      ImageSummary.self, from: Data(#"{"id": "\#(kite.id)", "url": "\#(away)", "width": 1, "height": 1}"#.utf8))
    #expect(await session.images.data(for: foreign) == nil)
    #expect(elsewhere.requests.isEmpty)
  }

  // MARK: - Fetching ahead

  @Test("After a sync on an ordinary network, each primary image and each avatar is fetched once")
  func fetchedAhead() async throws {
    let family = try await family()
    let device = try await signedIn(as: family.robin)
    let session = try #require(device.session)
    await session.imagesFetchedAhead()
    #expect(await session.syncNow() == .succeeded)
    await session.imagesFetchedAhead()

    for id in family.imageIDs {
      #expect(imageRequests(of: id).count == 1)
    }
    // What was fetched ahead shows with no request.
    let ball = try image(of: "Ball", in: session)
    let served = try await served(ball, to: family.robin)
    #expect(await session.images.data(for: ball) == served)
    #expect(imageRequests(of: family.imageIDs[1]).count == 1)
  }

  @Test("On an expensive or constrained network, nothing is fetched ahead, and an image loads when it shows")
  func notOnAnExpensiveNetwork() async throws {
    let family = try await family()
    let device = try await signedIn(as: family.robin, network: TestNetwork(expensive: true))
    let session = try #require(device.session)
    await session.imagesFetchedAhead()
    #expect(await session.syncNow() == .succeeded)
    await session.imagesFetchedAhead()

    for id in family.imageIDs {
      #expect(imageRequests(of: id).isEmpty)
    }
    let kite = try image(of: "Kite", in: session)
    let served = try await served(kite, to: family.robin)
    #expect(await session.images.data(for: kite) == served)
    #expect(imageRequests(of: family.imageIDs[0]).count == 1)
  }

  // MARK: - With no connection

  @Test("With the network dropped, a cached image is served, and an image that is not cached gives none")
  func offline() async throws {
    let family = try await family()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: family.robin, in: folder, network: TestNetwork(expensive: true))
    let session = try #require(device.session)
    let kite = try image(of: "Kite", in: session)
    let ball = try image(of: "Ball", in: session)
    let served = try await served(kite, to: family.robin)
    #expect(await session.images.data(for: kite) == served)

    // The app opens again with no connection: the image comes from the folder.
    instance.conditioner.dropEverything()
    let relaunched = try #require(
      instance.device(storage: .folder(folder.url), images: .folder(folder.url)).session)
    #expect(await relaunched.images.data(for: kite) == served)
    #expect(await relaunched.images.data(for: ball) == nil)
    #expect(imageRequests(of: kite.id).count == 1)
  }

  // MARK: - The folder

  @Test("The folder is named for the instance and the user")
  func folderName() async throws {
    let family = try await family()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: family.robin, in: folder)
    let session = try #require(device.session)
    await session.imagesFetchedAhead()

    let images = imagesFolder(in: folder)
    let named = try FileManager.default.contentsOfDirectory(atPath: images.path(percentEncoded: false))
    #expect(named == [session.session.opaqueName])
    let files = try FileManager.default.contentsOfDirectory(
      atPath: images.appending(path: session.session.opaqueName).path(percentEncoded: false))
    #expect(files.count == family.imageIDs.count)
    // Another user at the same instance has another name.
    let other = Session(instance: session.session.instance, token: "", userID: "\(session.session.userID)0")
    #expect(other.opaqueName != session.session.opaqueName)
  }

  @Test("Sign-out deletes the folder")
  func signOutDeletes() async throws {
    let family = try await family()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: family.robin, in: folder)
    try await #require(device.session).imagesFetchedAhead()
    #expect(exists(imagesFolder(in: folder)))

    await device.signOut()

    #expect(!exists(imagesFolder(in: folder)))
  }

  @Test("Sign-out doesn't wait for an image that is still loading")
  func signOutDoesntWait() async throws {
    let family = try await family()
    let held = instance.conditioner.hold(Route("GET", "/images/{id}"), at: .request)
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: family.robin))
    // The fetch ahead of time, after the first sync, waits for its first image.
    await held.waitUntilHeld()
    let releasing = Task {
      try? await Task.sleep(for: .seconds(5))
      held.release()
    }
    defer { releasing.cancel() }

    let start = ContinuousClock.now
    await device.signOut()
    let took = ContinuousClock.now - start

    #expect(device.session == nil)
    #expect(took < .seconds(2), "Sign-out took \(took)")
  }

  @Test("An upload that ends with the session leaves no folder")
  func uploadEndingWithTheSession() async throws {
    let robin = try await instance.person("Robin")
    let folder = try ScratchDirectory("device")
    let device = instance.device(storage: .folder(folder.url), images: .folder(folder.url))
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    var draft = ProfileDraft(try #require(session.user))
    draft.photo = .new(FixtureBuilder.onePixelPNG)

    // The upload has reached the server, and its answer comes as the sign-out starts. The cache keeps the photo
    // then, or keeps nothing, but writes nothing after the sign-out removed the folder.
    let upload = instance.conditioner.hold(Route("POST", "/images"))
    let confirming = Task { await session.confirmProfile(draft) }
    await upload.waitUntilHeld()
    upload.release()
    await device.signOut()
    _ = await confirming.value

    #expect(device.session == nil)
    #expect(!exists(imagesFolder(in: folder)))
  }

  @Test("The API's own 401 deletes the folder")
  func unauthorizedDeletes() async throws {
    let family = try await family()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: family.robin, in: folder)
    let session = try #require(device.session)
    await session.imagesFetchedAhead()
    #expect(exists(imagesFolder(in: folder)))

    // Another session revokes this one, as the Devices list in a browser does.
    let other = try family.robin.signedIn()
    let sessions = try await other.all("/users/me/sessions")
    let current = try #require(sessions.first { $0["is_current"].bool == false })
    _ = try await other.send("DELETE", "/users/me/sessions/\(try #require(current["id"].string))").expecting(204)
    await session.syncNow()

    #expect(device.session == nil)
    #expect(!exists(imagesFolder(in: folder)))
  }

  @Test("A fresh install deletes the folder that an earlier install left")
  func freshInstallDeletes() async throws {
    let family = try await family()
    let folder = try ScratchDirectory("device")
    let device = try await signedIn(as: family.robin, in: folder)
    try await #require(device.session).imagesFetchedAhead()
    #expect(exists(imagesFolder(in: folder)))

    // A reinstall: the Keychain item stays, and the install marker is gone.
    let reinstalled = instance.device(
      storage: .folder(folder.url), images: .folder(folder.url), marker: InMemoryInstallMarker())
    await reinstalled.launchEnded()

    #expect(reinstalled.session == nil)
    #expect(!exists(imagesFolder(in: folder)))
  }

  // MARK: - Uploads

  @Test("An uploaded image is served from the cache, with no download")
  func uploaded() async throws {
    let robin = try await instance.person("Robin")
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: robin))
    let session = try #require(device.session)
    var draft = ProfileDraft(try #require(session.user))
    draft.photo = .new(FixtureBuilder.onePixelPNG)
    #expect(await session.confirmProfile(draft) == .confirmed)
    await until { session.user?.avatar != nil }
    let avatar = try #require(session.user?.avatar)

    instance.conditioner.dropEverything()
    #expect(session.images.cached(avatar) == FixtureBuilder.onePixelPNG)
    #expect(await session.images.data(for: avatar) == FixtureBuilder.onePixelPNG)
    #expect(imageRequests(of: avatar.id).isEmpty)
  }
}

extension TestNetwork {
  /// A network that never changes, and is expensive or constrained as given.
  convenience init(expensive: Bool) {
    self.init()
    isExpensiveOrConstrained = expensive
  }
}

extension Array {
  /// The one element, or nil when there are none or more than one.
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}
