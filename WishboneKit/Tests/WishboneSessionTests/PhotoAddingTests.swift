import CoreGraphics
import Foundation
import ImageIO
import TestSupport
import Testing
import UniformTypeIdentifiers
import WishboneAPI
import WishboneSession

/// Adding an item from a photo that the user took or chose, at the session model's seam, against the real server:
/// the search of the photo, the form with the photo as the item's image, and the add. See "The empty Add screen",
/// "What the add form holds" and "When search can't fill in the form" in `docs/spec.md`, and `docs/screens/add.md`.
@Suite("Adding an item from a photo", .timeLimit(.minutes(2)))
@MainActor
final class PhotoAddingTests {
  typealias Route = NetworkConditioner.Route

  static let search = Route("POST", "/search")
  static let upload = Route("POST", "/images")

  /// The words of the title when no guess comes back. The app's come from the String Catalog.
  static func untitled(_ date: Date) -> String {
    "Photo from \(date.formatted(.iso8601.year().month().day()))"
  }

  /// A device on the instance, signed in as a new person, with the first sync over.
  private func signedIn(
    on instance: Instance, diagnostics: RecordingDiagnostics? = nil
  ) async throws -> (SessionModel, Fixture.Person) {
    let person = try await instance.person("Robin")
    let device = diagnostics.map { instance.device(diagnostics: $0) } ?? instance.device()
    await device.signIn(pasting: try await instance.loginLink(for: person))
    let session = try #require(device.session)
    try await untilInStep(session, as: person)
    #expect(session.primaryList != nil)
    return (session, person)
  }

  /// The search of the photo, as the Add screen starts it and takes its answer. The form to push, or nil. A photo
  /// that the device couldn't read (nil) starts no search, as on the screen.
  private func search(_ photo: Photo?, in session: SessionModel, state: inout AddScreenState) async -> ItemDraft? {
    guard let started = state.startSearch(ofPhoto: photo) else { return nil }
    let outcome = await session.search(started.input)
    return state.searchEnded(started.id, with: outcome)
  }

  /// A photo as the camera or the picker gives it: a small PNG, encoded as the app sends it.
  private func photo(now: Date = .now) throws -> Photo {
    try #require(Photo(file: try Self.image(width: 64, height: 48, as: .png), now: now, untitled: Self.untitled))
  }

  @Test("A photo, on a server with a model, gives the guessed title and the photo, and Add saves it as the image")
  func guessedTitle() async throws {
    let model = try await PhotoModel(title: "Blue enamel kettle")
    let instance = try await Instance(server: try await TestServer.start(environment: model.environment))
    let diagnostics = RecordingDiagnostics()
    let (session, person) = try await signedIn(on: instance, diagnostics: diagnostics)
    let photo = try photo()
    var state = AddScreenState(text: "kept")

    let found = await search(photo, in: session, state: &state)
    var draft = try #require(found)

    #expect(model.guesses == 1)
    #expect(draft.title == "Blue enamel kettle")
    #expect(draft.photo == photo)
    #expect(draft.note == nil)
    #expect(draft.images.isEmpty)
    #expect(draft.storeLink == nil)
    #expect(state.phase == .empty)
    // A photo is searched from its rows: the field's text stays.
    #expect(state.text == "kept")
    // The photo went to search as a file, as a JPEG.
    let searched = try #require(instance.conditioner.requests.last { $0.isOn(Self.search) })
    #expect(searched.headers["content-type"]?.hasPrefix("multipart/form-data") == true)
    #expect(searched.body.range(of: photo.data) != nil)

    guard case .added(let item) = await session.add(&draft) else {
      Issue.record("The add gave no item")
      return
    }
    #expect(item.title == "Blue enamel kettle")
    // On Add, the photo's bytes went to `POST /images`, then the item was added with it as its image.
    let uploads = instance.conditioner.requests.filter { $0.isOn(Self.upload) }
    #expect(uploads.map(\.body) == [photo.data])
    let saved = try await person.signedIn().get("/items/\(item.id)")
    #expect(saved["images"].array?.count == 1)
    #expect(saved["primary_image"]["id"].string == saved["images"][0]["id"].string)
    await until { session.item(id: item.id) != nil }
    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  @Test("On a server with no model, a photo gives the title \"Photo from {date}\" and the note that asks for a title")
  func noModel() async throws {
    let instance = try await Instance()
    let diagnostics = RecordingDiagnostics()
    let (session, person) = try await signedIn(on: instance, diagnostics: diagnostics)
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let photo = try photo(now: now)
    var state = AddScreenState()

    let found = await search(photo, in: session, state: &state)
    var draft = try #require(found)

    #expect(draft.title == Self.untitled(now))
    #expect(draft.note == .photoNotRead)
    #expect(draft.photo == photo)
    #expect(draft.hasTitle)

    guard case .added(let item) = await session.add(&draft) else {
      Issue.record("The add gave no item")
      return
    }
    let saved = try await person.signedIn().get("/items/\(item.id)")
    #expect(saved["title"].string == Self.untitled(now))
    #expect(saved["images"].array?.count == 1)
    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  @Test("A photo over the hourly limit gives the form with the photo, \"Photo from {date}\", and the limit's note")
  func overTheHourlyLimit() async throws {
    let instance = try await Instance()
    let diagnostics = RecordingDiagnostics()
    let (session, _) = try await signedIn(on: instance, diagnostics: diagnostics)
    let photo = try photo()
    var state = AddScreenState()
    instance.conditioner.answer(Self.search, with: try .problem(429, code: "rate_limited"))

    let found = await search(photo, in: session, state: &state)
    let draft = try #require(found)

    #expect(draft.note == .overLimit)
    #expect(draft.title == photo.untitled)
    #expect(draft.photo == photo)
    #expect(draft.priceMinor == nil)
    #expect(draft.storeLink == nil)
    #expect(state.phase == .empty)
    // A refused search is not captured.
    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  @Test("A file that the device can't read as an image sends nothing, and the line has the words of image_invalid")
  // The words of the phase are `ErrorWords.notAnImage`, which the hosted `ErrorWordsTests` holds to image_invalid's.
  func unreadableFile() async throws {
    let instance = try await Instance()
    let diagnostics = RecordingDiagnostics()
    let (session, _) = try await signedIn(on: instance, diagnostics: diagnostics)
    var state = AddScreenState(text: "kept")

    // A photo whose search is still running when the user chooses a file that isn't an image.
    let hold = instance.conditioner.hold(Self.search, at: .request)
    let first = state.startSearch(.photo(try photo()))
    let reading = Task { await session.search(first.input) }
    await hold.waitUntilHeld()
    let sent = instance.conditioner.requests.filter { $0.isOn(Self.search) || $0.isOn(Self.upload) }.count

    let notAnImage = Photo(file: Data("not a photo".utf8), untitled: Self.untitled)
    #expect(notAnImage == nil)
    #expect(await search(notAnImage, in: session, state: &state) == nil)
    #expect(state.phase == .unreadablePhoto)
    #expect(state.searching == nil)
    #expect(state.text == "kept")
    // Nothing of the file went to the instance: no search, and no upload.
    #expect(instance.conditioner.requests.filter { $0.isOn(Self.search) || $0.isOn(Self.upload) }.count == sent)

    // The search that ran was stopped: its late answer changes nothing.
    hold.release()
    let late = await reading.value
    #expect(state.searchEnded(first.id, with: late) == nil)
    #expect(state.phase == .unreadablePhoto)
    // Nothing is captured.
    #expect(diagnostics.faults.isEmpty, "\(diagnostics.faults)")
  }

  @Test("A file that is too large, and one that the server can't use, are refused with their codes, and open no form")
  // The words for each code are the hosted `ErrorWordsTests`'.
  func refusedFiles() async throws {
    let instance = try await Instance()
    let diagnostics = RecordingDiagnostics()
    let (session, _) = try await signedIn(on: instance, diagnostics: diagnostics)
    var state = AddScreenState()

    // The app sends only a JPEG that it made, so the server refuses one as image_invalid only if it can't read the
    // JPEG. These bytes stand in for that.
    let notAnImage = Photo(data: Data("not a photo".utf8), untitled: "Photo")
    #expect(await search(notAnImage, in: session, state: &state) == nil)
    guard case .refused(.photo(notAnImage), let invalid) = state.phase else {
      Issue.record("The search ended with \(state.phase)")
      return
    }
    #expect(invalid.code == .imageInvalid)

    // The server takes at most 10 MiB, and its form a little more. Either refusal has the same words.
    let tooLarge = Photo(data: Data(count: Photo.byteLimit + 2 << 20), untitled: "Photo")
    #expect(await search(tooLarge, in: session, state: &state) == nil)
    guard case .refused(.photo(tooLarge), let large) = state.phase else {
      Issue.record("The search ended with \(state.phase)")
      return
    }
    #expect([ErrorCode.imageTooLarge, .requestTooLarge].contains(large.code))
    // No new error type is captured. A 422 of a write is captured as it always is (section 11). A 413 is not.
    #expect(diagnostics.faults == [.refusedWrite(.search, code: "image_invalid")])
  }

  @Test("Fill it in myself, while a photo is read, gives a form with only the photo, and the late answer is ignored")
  func fillItInMyself() async throws {
    let instance = try await Instance()
    let (session, _) = try await signedIn(on: instance)
    let photo = try photo()
    var state = AddScreenState()
    let hold = instance.conditioner.hold(Self.search, at: .request)

    let started = state.startSearch(.photo(photo))
    #expect(state.phase == .reading(.photo(photo)))
    let reading = Task { await session.search(started.input) }
    await hold.waitUntilHeld()

    let filled = state.fillItInMyself()
    let draft = try #require(filled)
    #expect(draft.photo == photo)
    #expect(draft.title.isEmpty)
    #expect(!draft.hasTitle)
    #expect(draft.note == nil)
    #expect(draft.images.isEmpty)
    #expect(draft.storeLink == nil)
    #expect(state.phase == .empty)

    hold.release()
    let late = await reading.value
    let before = state
    #expect(state.searchEnded(started.id, with: late) == nil)
    #expect(state == before)
  }

  // MARK: - The file that is sent

  @Test("A HEIC photo goes out as an upright JPEG of at most 2400 px, under the limit, titled by the day it was taken")
  func heicGoesAsJPEG() throws {
    try #require(
      (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true,
      "This Mac can't write HEIC")
    let taken = "2026:07:04 15:30:00"
    // As a phone takes it held upright: the pixels lie on their side, and the orientation tag (6) turns them. The
    // file says where it was taken, and the phone that took it.
    let heic = try Self.image(
      width: 4032, height: 3024, as: .heic, taken: taken,
      metadata: [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
          kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W",
        ],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
      ])
    // The fixture holds what the test says it does.
    let original = try #require(
      CGImageSourceCreateWithData(heic as CFData, nil).flatMap {
        CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
      })
    #expect(original[kCGImagePropertyOrientation] as? Int == 6)
    #expect(original[kCGImagePropertyGPSDictionary] != nil)
    #expect((original[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] != nil)

    let photo = try #require(Photo(file: heic, now: .distantPast, untitled: Self.untitled))

    #expect(photo.data.count <= Photo.byteLimit)
    let source = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    // Upright: the sides are swapped, and no tag turns them again.
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1800)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2400)
    #expect([nil, 1].contains(properties[kCGImagePropertyOrientation] as? Int))
    // None of the original's metadata goes: not where, not the phone, and not the time it was taken.
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
    #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
    // The title names the day from the photo's own metadata, not now.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    #expect(photo.untitled == Self.untitled(try #require(formatter.date(from: taken))))
  }

  @Test("A photo with no date in its file is titled by now, and a small one keeps its size")
  func smallPhotoKeepsItsSize() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let photo = try photo(now: now)
    #expect(photo.untitled == Self.untitled(now))
    let source = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 64)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 48)
  }

  /// An image file of the size, with a pattern that doesn't compress to nothing, the time it was taken, and more
  /// metadata.
  static func image(
    width: Int, height: Int, as type: UTType, taken: String? = nil, metadata: [CFString: Any] = [:]
  ) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let step = max(1, width / 64)
    for x in stride(from: 0, to: width, by: step) {
      for y in stride(from: 0, to: height, by: step) {
        let shade = CGFloat((x * 31 + y * 17) % 255) / 255
        context.setFillColor(red: shade, green: 1 - shade, blue: CGFloat(x % 7) / 7, alpha: 1)
        context.fill(CGRect(x: x, y: y, width: step, height: step))
      }
    }
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    var properties = metadata
    if let taken { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: taken] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return output as Data
  }
}
