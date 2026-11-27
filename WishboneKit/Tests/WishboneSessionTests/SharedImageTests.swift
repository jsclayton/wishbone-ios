import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Synchronization
import TestSupport
import Testing
import UniformTypeIdentifiers
import WishboneAPI
import WishboneSession

/// One image shared to the share extension, a photo or a screenshot, at its device's and its session model's seam,
/// against the real server: what it reads from the share, the form, Add, and the hourly limit. See "The share
/// extension" in `docs/spec.md`, and `docs/screens/share-extension.md`.
@Suite("An image shared to the share extension", .timeLimit(.minutes(2)))
@MainActor
final class SharedImageTests {
  typealias Route = NetworkConditioner.Route

  static let search = Route("POST", "/search")
  static let upload = Route("POST", "/images")

  /// The words of the title when no guess comes back, as `PhotoAddingTests` has them. The app's come from the
  /// String Catalog.
  nonisolated static func untitled(_ date: Date) -> String {
    "Photo from \(date.formatted(.iso8601.year().month().day()))"
  }

  /// Where the extension tells the app that it added an item.
  let app = TellingRecorder()

  /// The files that the tests share.
  let files: ScratchDirectory

  init() throws {
    files = try ScratchDirectory("shared-images")
  }

  /// The extension's device on the instance, with the lists read, after the app signed in as a new person.
  private func loaded(on instance: Instance) async throws -> (SessionModel, Fixture.Person) {
    let person = try await instance.person("Robin")
    let device = instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    try await untilInStep(try #require(device.session), as: person)
    let share = ShareDevice(
      .init(
        userAgent: UserAgent(version: "1.0", isPad: false), keychain: instance.keychain, marker: instance.marker,
        tellsTheApp: app))
    await share.load()
    #expect(share.state == .ready)
    return (try #require(share.session), person)
  }

  /// An image file in the scratch folder, as Photos or the Files app gives one.
  private func file(_ data: Data, as type: UTType) throws -> URL {
    let url = files.url.appending(path: "\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
    try data.write(to: url)
    return url
  }

  /// What the extension reads from one shared attachment.
  private func read(_ providers: [NSItemProvider]) async -> SharedThing? {
    await SharedThing.read(providers, untitled: Self.untitled)
  }

  /// An attachment of the bytes, as the screenshot editor shares one: no file.
  private static func provider(of data: Data, as type: UTType) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { load in
      load(data, nil)
      return nil
    }
    return provider
  }

  /// The photo that the extension reads from the shared image file.
  private func sharedPhoto(_ url: URL) async throws -> Photo {
    let thing = await read([try #require(NSItemProvider(contentsOf: url))])
    guard case .photo(let photo) = thing else {
      Issue.record("The share gave \(String(describing: thing))")
      throw CancellationError()
    }
    return photo
  }

  /// The search of the shared thing, as the extension starts it and takes its answer.
  private func search(_ thing: SharedThing, in session: SessionModel) async throws -> ItemDraft? {
    var state = AddScreenState()
    let started = state.startSearch(try #require(SearchInput(shared: thing)))
    return state.searchEnded(started.id, with: await session.search(started.input))
  }

  // MARK: - What it reads

  @Test("One photo, and one screenshot, are read as a photo. Two, one with a link, or a broken one, are not")
  func whatItReads() async throws {
    let taken = "2026:07:04 15:30:00"
    let heic = try file(PhotoAddingTests.image(width: 400, height: 300, as: .heic, taken: taken), as: .heic)

    let photo = try await sharedPhoto(heic)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    #expect(photo.untitled == Self.untitled(try #require(formatter.date(from: taken))))
    #expect(SearchInput(shared: .photo(photo)) == .photo(photo))

    // A screenshot, as the screenshot editor shares it: the bytes, with no file.
    let png = try PhotoAddingTests.image(width: 300, height: 200, as: .png)
    let screenshot = await read([Self.provider(of: png, as: .png)])
    guard case .photo(let shot) = screenshot else {
      Issue.record("The screenshot gave \(String(describing: screenshot))")
      return
    }
    let source = try #require(CGImageSourceCreateWithData(shot.data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)

    // Two images, an image that comes with a web link, and a file that the device can't read as an image.
    let second = try #require(NSItemProvider(contentsOf: heic))
    #expect(await read([try #require(NSItemProvider(contentsOf: heic)), second]) == nil)
    let withLink = Self.provider(of: png, as: .png)
    withLink.registerObject(try #require(URL(string: "https://shop.example/kite")) as NSURL, visibility: .all)
    #expect(await read([withLink]) == nil)
    let broken = try file(Data("not an image".utf8), as: .jpeg)
    #expect(await read([try #require(NSItemProvider(contentsOf: broken))]) == nil)
    // A link and a text are read as before.
    let link = NSItemProvider(object: try #require(URL(string: "https://shop.example/kite")) as NSURL)
    #expect(await read([link]) == .link(try #require(URL(string: "https://shop.example/kite"))))
    #expect(await read([NSItemProvider(object: "A red kite" as NSString)]) == .text("A red kite"))
  }

  // MARK: - The form

  @Test("One image gives the form with the image and the guessed title, and the image goes to search")
  func guessedTitle() async throws {
    let model = try await PhotoModel(title: "Blue enamel kettle")
    let instance = try await Instance(server: try await TestServer.start(environment: model.environment))
    let (session, _) = try await loaded(on: instance)
    let photo = try await sharedPhoto(try file(PhotoAddingTests.image(width: 640, height: 480, as: .jpeg), as: .jpeg))

    let draft = try #require(await search(.photo(photo), in: session))

    #expect(model.guesses == 1)
    #expect(draft.title == "Blue enamel kettle")
    #expect(draft.photo == photo)
    #expect(draft.note == nil)
    let searched = try #require(instance.conditioner.requests.last { $0.isOn(Self.search) })
    #expect(searched.body.range(of: photo.data) != nil)
  }

  @Test("With no guess, the form has the image and \"Photo from {date}\", and Add uploads it as a JPEG under the limit")
  func addUploadsTheJPEG() async throws {
    let instance = try await Instance()
    let (session, person) = try await loaded(on: instance)
    // A large photo, with where it was taken in its file.
    let heic = try PhotoAddingTests.image(
      width: 4032, height: 3024, as: .heic, taken: "2026:07:04 15:30:00",
      metadata: [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"]
      ])
    let photo = try await sharedPhoto(try file(heic, as: .heic))

    var draft = try #require(await search(.photo(photo), in: session))

    #expect(draft.title == photo.untitled)
    #expect(draft.note == .photoNotRead)
    #expect(draft.photo == photo)
    guard case .added(let item) = await session.add(&draft) else {
      Issue.record("The add gave no item")
      return
    }

    // What went to `POST /images` is the JPEG that the extension made: under the limit, at most the side that the
    // server keeps, and with nothing of the file's metadata.
    let uploads = instance.conditioner.requests.filter { $0.isOn(Self.upload) }
    #expect(uploads.map(\.body) == [photo.data])
    #expect(photo.data.count <= Photo.byteLimit)
    let source = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == Photo.sharedLongestSide)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 900)
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect(
      (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
    // The item has the image, and the app was told once.
    let saved = try await person.signedIn().get("/items/\(item.id)")
    #expect(saved["title"].string == photo.untitled)
    #expect(saved["images"].array?.count == 1)
    #expect(saved["primary_image"]["id"].string == saved["images"][0]["id"].string)
    #expect(app.count == 1)
    #expect(session.unsentChangeCount == 0)
  }

  @Test("Over the hourly limit, the form has the image, \"Photo from {date}\", and the limit's note")
  func overTheHourlyLimit() async throws {
    let instance = try await Instance()
    let (session, _) = try await loaded(on: instance)
    let photo = try await sharedPhoto(try file(PhotoAddingTests.image(width: 64, height: 48, as: .png), as: .png))
    instance.conditioner.answer(Self.search, with: try .problem(429, code: "rate_limited"))

    let draft = try #require(await search(.photo(photo), in: session))

    #expect(draft.note == .overLimit)
    #expect(draft.title == photo.untitled)
    #expect(draft.photo == photo)
    #expect(instance.conditioner.requests.contains { $0.isOn(Self.search) })
  }

  // MARK: - Memory

  /// The most that the extension's process grows by while it reads a shared image, in MiB. The extension has about
  /// 120 MB, and needs the rest for itself.
  static let readingBudget = 60.0

  @Test(
    "A 48 MP image is made smaller from its file, with a measured peak under the budget",
    arguments: [UTType.heic, .jpeg, .png])
  func largeImageStaysUnderTheLimit(_ type: UTType) throws {
    let url = try file(try PhotoAddingTests.image(width: 8064, height: 6048, as: type), as: type)

    var photo: Photo?
    let reading = Self.peakGrowth {
      photo = Photo(fileAt: url, longestSide: Photo.sharedLongestSide, untitled: Self.untitled)
    }
    // The measure sees a full decode: the image at its full size is about 186 MiB.
    let fullSize = Self.peakGrowth {
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
      _ = source.flatMap {
        CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      }
    }

    #expect(reading < Self.readingBudget, "Reading the \(type.identifier) grew by \(reading) MiB")
    #expect(fullSize > 150, "A full decode grew by \(fullSize) MiB")
    let data = try #require(photo?.data)
    #expect(data.count <= Photo.byteLimit)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == Photo.sharedLongestSide)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 900)
  }

  /// How far the process's footprint rose above where it was while the work ran, in MiB, sampled on a thread of its
  /// own every 200 µs.
  nonisolated static func peakGrowth(_ work: () -> Void) -> Double {
    let start = footprint()
    let sampled = Sampled(start)
    let sampler = Thread {
      while !sampled.stop.load(ordering: .relaxed) {
        sampled.note(footprint())
        usleep(200)
      }
    }
    sampler.start()
    work()
    usleep(5000)
    sampled.stop.store(true, ordering: .relaxed)
    sampled.note(footprint())
    return Double(sampled.peak.load(ordering: .relaxed) - start) / 1_048_576
  }

  /// The highest footprint that the sampler saw, and the word for it to stop.
  private final class Sampled: Sendable {
    let peak: Atomic<UInt64>
    let stop = Atomic(false)

    init(_ start: UInt64) {
      peak = Atomic(start)
    }

    func note(_ footprint: UInt64) {
      peak.max(footprint, ordering: .relaxed)
    }
  }

  /// The process's physical footprint, as the system counts it against an extension's memory limit.
  nonisolated static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
