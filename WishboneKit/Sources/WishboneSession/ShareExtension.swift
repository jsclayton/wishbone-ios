import CoreFoundation
import Foundation
import Observation
import UniformTypeIdentifiers
import WishboneAPI

// The share extension: one link, one text or one image from another app, the add form, and Add. See "The share extension" in
// `docs/spec.md`, and `docs/screens/share-extension.md`.
//
// The extension builds its own session model, with a database in memory, fed from the API: `GET /users/me`, the
// lists that the user can edit, the user's children, and the items of those lists for the duplicate hint. Nothing is
// on disk, and nothing goes into the shared container. It keeps no journal and never syncs (ADR 0006), so an add that
// can't reach the instance is not sent later. After an add, it tells the app, which syncs at once.
//
// **Secrecy.** It shows the user's own add form and the lists that they can edit: no claim state, and nothing about a
// gift. Its copy holds no gift, because it never asks for one. It sends no diagnostics: an extension gives `.none`.

/// The one thing that another app shared: a link, a text, or an image. Wishbone is not offered when several things
/// are shared.
public enum SharedThing: Sendable, Equatable {
  /// A web address, from Safari or any app.
  case link(URL)

  /// A text, such as "Check out this toy! https://…".
  case text(String)

  /// A photo or a screenshot, made smaller as the extension sends it.
  case photo(Photo)

  /// Reads the one thing that the attachments of a share hold: a web link, a text, or an image. Several things, or
  /// a thing of another kind, give nil: Wishbone can't use them. The activation rule keeps Wishbone out of a share
  /// sheet for most of them already.
  ///
  /// An image is read from the file that the provider gives, and made smaller there (`Photo(fileAt:)`), so the
  /// extension never holds the image at its full size. An image that comes with a web link is not one thing, and
  /// gives nil, as the activation rule has it.
  ///
  /// - Parameter untitled: The title of a photo when no guess comes back, "Photo from {date}".
  public static func read(
    _ providers: [NSItemProvider], untitled: @escaping @Sendable (Date) -> String
  ) async -> SharedThing? {
    guard providers.count == 1, let provider = providers.first else { return nil }
    let isFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    let isWebLink = !isFile && provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    if let image = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
      guard !isWebLink else { return nil }
      return await withCheckedContinuation { continuation in
        // The file is there only until the handler returns, so the photo is made in it.
        _ = provider.loadFileRepresentation(forTypeIdentifier: image) { url, _ in
          let photo = url.flatMap { Photo(fileAt: $0, longestSide: Photo.sharedLongestSide, untitled: untitled) }
          continuation.resume(returning: photo.map(SharedThing.photo))
        }
      }
    }
    if isWebLink {
      let url: URL? = await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
      }
      return url.map(SharedThing.link)
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      let text: String? = await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
      }
      return text.map(SharedThing.text)
    }
    return nil
  }
}

extension SearchInput {
  /// What the search reads from the shared thing: a web link as a link, a text's first web link with the rest of the
  /// text ignored, any other text as typed words, and an image as a photo. Nil for a thing that Wishbone can't use: a link that is not a
  /// web address, or a text with nothing in it.
  public init?(shared thing: SharedThing) {
    switch thing {
    case .link(let url):
      guard let input = SearchInput(url.absoluteString), case .link = input else { return nil }
      self = input
    case .text(let text):
      if let link = Self.firstWebLink(in: text) {
        self = link
      } else if let words = SearchInput(text) {
        self = words
      } else {
        return nil
      }
    case .photo(let photo):
      self = .photo(photo)
    }
  }

  /// The first web link in the text, as a link. Store apps share "Check out this toy! https://…".
  private static func firstWebLink(in text: String) -> SearchInput? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
      return nil
    }
    let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
    for match in matches {
      guard let range = Range(match.range, in: text), let url = match.url,
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
      else { continue }
      // The link as the text has it, when it is a whole web address. A link that the text gives with no scheme,
      // such as "example.com/kite", is read as the detector completes it.
      let written = String(text[range])
      if let input = SearchInput(written), case .link = input { return input }
      if let input = SearchInput(url.absoluteString), case .link = input { return input }
    }
    return nil
  }
}

// MARK: - Telling the app

/// Where the share extension tells the app that it added an item. The extension gives the Darwin notification's.
public protocol TellsTheApp: Sendable {
  /// Says that an item was added. It carries nothing: the app's sync finds the item.
  func itemAdded()
}

/// Where the app hears that the share extension added an item, so it syncs at once. The default hears nothing: only
/// the app gives the Darwin notification's.
public protocol AddsFromShareExtension: Sendable {
  /// Yields once for each add after the call, or for several that came close together. The stream ends when the task
  /// that reads it is cancelled.
  func adds() -> AsyncStream<Void>
}

/// No one to tell, and nothing to hear.
public struct NoAdds: TellsTheApp, AddsFromShareExtension {
  public init() {}

  public func itemAdded() {}

  public func adds() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }
}

extension TellsTheApp where Self == NoAdds {
  /// No one to tell.
  public static var none: NoAdds { NoAdds() }
}

extension AddsFromShareExtension where Self == NoAdds {
  /// Nothing to hear.
  public static var none: NoAdds { NoAdds() }
}

/// The Darwin notification that the share extension posts after an add, and that the app listens for. It carries
/// no data: a Darwin notification is a name only, so nothing about the item or the family goes with it.
public struct ItemAddedNotification: TellsTheApp, AddsFromShareExtension {
  /// The notification's name. The app and the extension make it from the app group that they share, so another
  /// app's notification never has it.
  public let name: String

  public init(appGroup: String) {
    name = "\(appGroup).item-added"
  }

  public func itemAdded() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
  }

  public func adds() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let listener = Listener(continuation: continuation)
    let name = name
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(listener).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<Listener>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
      }, name as CFString, nil, .deliverImmediately)
    // The closure holds the listener until the stream ends, and then stops the observation.
    continuation.onTermination = { _ in
      CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(listener).toOpaque(),
        CFNotificationName(name as CFString), nil)
    }
    return stream
  }

  /// What the Darwin center calls back: the stream's continuation.
  private final class Listener: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
      self.continuation = continuation
    }
  }
}

// MARK: - The session model's role

extension SessionModel {
  /// Whose session model it is.
  enum Role: Sendable {
    /// The app's: it keeps a journal of unsent changes, and syncs.
    case app

    /// The share extension's: its copy is in memory, fed from the API. It keeps no journal and never syncs. After an
    /// add, it tells the app.
    case shareExtension(tellsTheApp: any TellsTheApp)

    var isApp: Bool {
      if case .app = self { true } else { false }
    }

    /// Tells the app that the extension added an item. The app's own adds tell no one.
    func itemAdded() {
      if case .shareExtension(let app) = self { app.itemAdded() }
    }
  }

  /// How a read of the API for the share extension ended.
  enum ReadEnd: Sendable, Equatable {
    case read
    case unreachable

    /// The instance refused, with an answer that is neither the API's own 401 nor its 410, or the answer can't be
    /// decoded.
    case refused

    /// The copy in memory can't take it.
    case faulted

    /// The API's own 401 or its 410: the session model has done what it asks.
    case stopped
  }

  /// Reads what the share extension's form needs, into the copy in memory: the user's own record with
  /// `GET /users/me`, the lists that the user can edit, and the user's children in full, for Add to. See "Where the
  /// database lives" in `docs/spec.md`.
  ///
  /// The lists come before the users, so the copy has the user and the children in full, not as the summaries in
  /// the lists' bodies.
  func readListsForShareExtension() async -> ReadEnd {
    guard !hasEnded else { return .stopped }
    do {
      let me = try await client.me()
      let lists = try await client.lists().rows.filter(\.resource.canEdit)
      var children: [Versioned<User>] = []
      for child in me.resource.children {
        // A child whom the user can't read in full is left out, and so is the child's part of Add to.
        guard let read = try await ifNotRefused({ () async throws(APIError) in try await client.user(child.id) })
        else { continue }
        children.append(read)
      }
      guard !hasEnded else { return .stopped }
      // Each summary in a list's body, with no version: the extension never asks `GET /versions`.
      let summaries = Dictionary(
        lists.flatMap(\.resource.recipients).map { ($0.id, "") }, uniquingKeysWith: { first, _ in first })
      try await database.save(lists, summaries: summaries)
      try await database.save([me] + children)
      return .read
    } catch {
      return await readEnded(with: error)
    }
  }

  /// Reads the items of each list that the user can edit, the primary list first, into the copy in memory, for the
  /// duplicate hint. A list whose items can't be read gets no hint. The form doesn't wait for this.
  func readItemsForShareExtension() async -> ReadEnd {
    let primaryID = user?.record?.primaryListID
    let ids = lists.filter(\.canEdit).map(\.id).sorted { first, second in
      first == primaryID && second != primaryID
    }
    for id in ids {
      guard !hasEnded else { return .stopped }
      do {
        let items = try await client.items(ofList: id)
        guard !hasEnded else { return .stopped }
        try await database.save(items.rows)
      } catch {
        let end = await readEnded(with: error)
        if end == .stopped || end == .unreachable { return end }
      }
    }
    return .read
  }

  /// What a read's error means, after the session model has done what it asks: the API's own 401 ends the session,
  /// and its 410 shows the block for an app that is too old.
  ///
  /// Diagnostics: never. The extension sends none, and the client has logged the request's outcome.
  private func readEnded(with error: any Error) async -> ReadEnd {
    switch error {
    case APIError.unreachable:
      return .unreachable
    case APIError.unauthorized:
      await endedByServer(self)
      return .stopped
    case APIError.appTooOld:
      blockAppTooOld()
      return .stopped
    case APIError.cancelled, is CancellationError:
      return .stopped
    case is APIError:
      return .refused
    default:
      guard !hasEnded else { return .stopped }
      Log.fault(.session, "The share extension's copy can't take what it read.", detail: "\(error)")
      return .faulted
    }
  }

  /// What the request gave, or nil when the instance refused it with an answer of its own, such as a 404 for a
  /// user who is hidden now. Every other error is thrown.
  private func ifNotRefused<Answer>(_ request: () async throws(APIError) -> Answer) async throws(APIError) -> Answer? {
    do {
      return try await request()
    } catch .refused {
      return nil
    }
  }
}

// MARK: - The share extension's device

/// The share extension's device: it reads the one session from the session keychain, builds its session model with
/// a database in memory, and feeds it from the API. See "The extensions and the control" and "The share extension"
/// in `docs/spec.md`.
///
/// It never signs in or out. With no session it shows its signed-out state, and so it does with no install marker:
/// the app clears a left-over session when it next runs. After the API's own 401, it deletes the Keychain item, and
/// nothing else: the app clears the rest when it next runs and finds no item.
@Observable
@MainActor
public final class ShareDevice {
  /// What the extension's entry point gives the device.
  public struct Setup: Sendable {
    public var userAgent: UserAgent
    public var keychain: any SessionKeychain

    /// The install marker in the app group's shared container. Nil when the container is missing: the extension
    /// can't tell whether the session is left over, so it forgets nothing, and shows its signed-out state.
    public var marker: (any InstallMarker)?

    /// The clock of every timeout.
    public var clock: any Clock<Duration>

    /// Where the extension tells the app that it added an item.
    public var tellsTheApp: any TellsTheApp

    public init(
      userAgent: UserAgent,
      keychain: any SessionKeychain,
      marker: (any InstallMarker)?,
      clock: any Clock<Duration> = ContinuousClock(),
      tellsTheApp: any TellsTheApp = .none
    ) {
      self.userAgent = userAgent
      self.keychain = keychain
      self.marker = marker
      self.clock = clock
      self.tellsTheApp = tellsTheApp
    }
  }

  /// What the extension shows, apart from the form's own states. See "States" in
  /// `docs/screens/share-extension.md`.
  public enum State: Sendable, Equatable {
    /// "Sign in to Wishbone first.": no session, no install marker, or the API's own 401.
    case signedOut

    /// The lists are being read.
    case loading

    /// "Can't reach {address}", with Try again and Copy the link.
    case cantReach(InstanceAddress)

    /// The instance answered with something that the extension can't use, or the copy in memory failed.
    case failed

    /// "Open Wishbone": the API's own 410 `api_version_removed`.
    case appTooOld

    /// The form can show: the copy has the user and the lists they can edit.
    case ready
  }

  /// The session model, with the copy in memory. Nil while signed out.
  public private(set) var session: SessionModel?

  private enum Read: Equatable {
    case loading, unreachable, failed, ready
  }

  private var read = Read.loading
  private let setup: Setup

  /// The read of the items for the duplicate hint, while it runs.
  private var readingItems: Task<Void, Never>?

  public var state: State {
    guard let session else { return .signedOut }
    if session.versionBlock == .appTooOld { return .appTooOld }
    switch read {
    case .loading: return .loading
    case .unreachable: return .cantReach(session.session.instance)
    case .failed: return .failed
    case .ready: return .ready
    }
  }

  public init(_ setup: Setup) {
    self.setup = setup
    guard let marker = setup.marker else {
      // Like a Keychain read that fails: the extension can't tell, so it forgets nothing.
      Log.fault(.session, "The share extension can't find the app group's shared container.")
      return
    }
    let kept: Session?
    do {
      kept = try setup.keychain.read()
    } catch {
      Log.fault(.session, "The session keychain can't be read.", detail: "\(error.status)")
      return
    }
    // A session with no marker is left over from an earlier install. The app forgets it when it next runs.
    guard let kept, marker.isPresent else { return }
    session = model(for: kept)
  }

  /// Reads the lists that the user can edit, and then, while the form shows, their items for the duplicate hint.
  /// Try again calls it too. It returns when both reads have ended.
  public func load() async {
    guard let session, read != .ready else { return }
    read = .loading
    switch await session.readListsForShareExtension() {
    case .read: read = .ready
    case .unreachable: read = .unreachable
    case .refused, .faulted: read = .failed
    case .stopped: return
    }
    guard read == .ready else { return }
    let task = Task { _ = await session.readItemsForShareExtension() }
    readingItems = task
    await task.value
  }

  /// Ends the session model, after Cancel or an add: nothing is kept. The extension then closes.
  public func end() async {
    readingItems?.cancel()
    guard let session else { return }
    self.session = nil
    await session.end()
  }

  /// The API's own 401: the extension deletes the Keychain item, and nothing else, and shows its signed-out state.
  ///
  /// Diagnostics: never. The extension sends none.
  private func endedByServer(_ model: SessionModel) async {
    guard session === model else { return }
    do {
      try setup.keychain.delete()
    } catch {
      Log.fault(.session, "The session keychain can't forget the session.", detail: "\(error.status)")
    }
    session = nil
    readingItems?.cancel()
    await model.end()
  }

  /// The session model of the session, with its copy in memory and its client. It schedules nothing, watches no
  /// network, and sends no diagnostics.
  private func model(for session: Session) -> SessionModel? {
    guard let database = try? LocalDatabase.inMemory() else {
      Log.fault(.session, "The share extension's database will not open in memory.")
      return nil
    }
    let client = APIClient(session: session, userAgent: setup.userAgent, clock: setup.clock, diagnostics: .none)
    return SessionModel(
      session: session, client: client, database: database, imageFolder: nil, timeZone: .system,
      timerClock: setup.clock, network: .unchanging, refresh: .none, diagnostics: .none, reminders: .none,
      reminderSettingsFile: ReminderSettingsFile(of: session, in: .memory),
      role: .shareExtension(tellsTheApp: setup.tellsTheApp),
      endedByServer: { [weak self] model in await self?.endedByServer(model) })
  }
}
