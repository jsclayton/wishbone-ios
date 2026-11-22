import CryptoKit
import Foundation
import Synchronization
import WishboneAPI

/// The session's image cache: the bytes of the instance's images, in memory and in a folder for this instance and
/// user. Images stay out of the database. See "Images" in `docs/spec.md`.
///
/// An image of the instance loads with the session's token, through the API client, which sends the token only to
/// the instance address. A store's image is not here: it loads with no token, through the system's default cache
/// (see `APIClient.storeImageRequest(_:)`).
///
/// Diagnostics: never. A failed load is not captured, and not a breadcrumb. With no image, a screen shows its tile
/// or the initials.
///
/// **Provisional.** The sizes: about 32 MB in memory and 512 MB on disk.
public final class ImageCache: Sendable {
  /// About how many bytes the cache keeps in memory.
  static let memoryLimit = 32 * 1024 * 1024

  /// About how many bytes the cache keeps on disk. Past it, the images used longest ago go first.
  static let diskLimit = 512 * 1024 * 1024

  private let client: APIClient

  /// The folder of the session's images. Nil keeps them in memory only, as the share extension and some tests do.
  let folder: URL?

  private let network: any NetworkChanges

  private struct State {
    /// The bytes in memory, by the image's address, each with when it was last used.
    var memory: [String: (data: Data, used: UInt64)] = [:]
    var memoryBytes = 0
    var clock: UInt64 = 0

    /// The bytes on disk, once the cache has counted them.
    var diskBytes: Int?

    /// The loads under way, by the image's address, so two asks for one image make one request.
    var loading: [String: Task<Data?, Never>] = [:]

    /// The writes of the images that the app keeps, such as an upload, so the end of the session waits for them.
    var writing: Set<Task<Void, Never>> = []

    /// The session is over: the cache keeps nothing more, and loads nothing.
    var hasEnded = false
  }

  private let state = Mutex(State())

  init(client: APIClient, folder: URL?, network: any NetworkChanges) {
    self.client = client
    self.folder = folder
    self.network = network
  }

  // MARK: - Where the folder goes

  /// The folder of one session's images, under the storage's folder. Its name is made from the instance address and
  /// the user's ID, so each instance and user has a folder of its own, and the name gives neither away. Nil for a
  /// storage in memory.
  static func folder(of session: Session, in storage: SessionStorage) -> URL? {
    guard case .folder(let base) = storage else { return nil }
    return images(under: base).appending(path: session.opaqueName, directoryHint: .isDirectory)
  }

  /// Removes every session's images under the storage, as sign-out, the API's own 401, and a fresh install do.
  static func removeAll(in storage: SessionStorage) {
    guard case .folder(let base) = storage else { return }
    do {
      try FileManager.default.removeItem(at: images(under: base))
    } catch CocoaError.fileNoSuchFile {
      // Nothing to remove.
    } catch {
      Log.fault(.session, "The image cache can't be removed.", detail: "\(error)")
    }
  }

  private static func images(under base: URL) -> URL {
    base.appending(path: "Images", directoryHint: .isDirectory)
  }

  // MARK: - Reading

  /// The bytes of the image, when the cache holds them in memory. It never waits, so a screen can show them at once.
  public func cached(_ image: ImageSummary) -> Data? {
    state.withLock { state in
      guard let kept = state.memory[image.url] else { return nil }
      state.clock += 1
      state.memory[image.url]?.used = state.clock
      return kept.data
    }
  }

  /// The bytes of the image: from memory, from disk, or from the instance. Nil when there are none, for example
  /// with no connection and no cached image: the screen then shows its tile or the initials, with no broken-image
  /// mark.
  public func data(for image: ImageSummary) async -> Data? {
    await load(image, onlyOnALowCostNetwork: false)
  }

  /// Fetches each image that the cache doesn't hold yet, but only on a network that is neither expensive nor
  /// constrained. The session calls it after each sync that succeeded, with each item's primary image and each
  /// avatar.
  func fetchAhead(_ images: [ImageSummary]) async {
    guard !network.isExpensiveOrConstrained else { return }
    var seen: Set<String> = []
    let wanted = images.filter { seen.insert($0.url).inserted }
    await withTaskGroup(of: Void.self) { group in
      // A few at a time, so the cache never floods the instance.
      var next = wanted.makeIterator()
      for _ in 0..<4 {
        guard let image = next.next() else { break }
        group.addTask { await self.fetchAheadOne(image) }
      }
      while await group.next() != nil {
        guard !Task.isCancelled, let image = next.next() else { continue }
        group.addTask { await self.fetchAheadOne(image) }
      }
    }
  }

  private func fetchAheadOne(_ image: ImageSummary) async {
    guard cached(image) == nil, !(await isOnDisk(image)) else { return }
    _ = await load(image, onlyOnALowCostNetwork: true)
  }

  /// The one load: memory, then disk, then the instance. Two loads of one image at once share one request.
  private func load(_ image: ImageSummary, onlyOnALowCostNetwork: Bool) async -> Data? {
    if let data = cached(image) { return data }
    let task: Task<Data?, Never>? = state.withLock { state in
      guard !state.hasEnded else { return nil }
      if let loading = state.loading[image.url] { return loading }
      let task = Task { [client] () -> Data? in
        if let data = await self.read(image) {
          _ = self.remember(data, for: image)
          return data
        }
        guard let data = await client.imageBytes(image, onlyOnALowCostNetwork: onlyOnALowCostNetwork) else {
          return nil
        }
        if self.remember(data, for: image) { await self.writeFile(data, for: image) }
        return data
      }
      state.loading[image.url] = task
      return task
    }
    guard let task else { return nil }
    let data = await task.value
    state.withLock { state in
      if state.loading[image.url] == task { state.loading[image.url] = nil }
    }
    return data
  }

  // MARK: - Keeping

  /// Keeps the bytes of an image, in memory and on disk. An image that the user just uploaded goes in under its new
  /// address, so it shows with no download.
  ///
  /// The write is one that `end()` waits for, so nothing is written after the session ended.
  func keep(_ data: Data, for image: ImageSummary) async {
    let task: Task<Void, Never>? = state.withLock { state in
      guard Self.remember(data, for: image, in: &state) else { return nil }
      let task = Task { await self.writeFile(data, for: image) }
      state.writing.insert(task)
      return task
    }
    guard let task else { return }
    await task.value
    state.withLock { _ = $0.writing.remove(task) }
  }

  /// Keeps the bytes in memory. False after the session ended, when nothing is kept.
  private func remember(_ data: Data, for image: ImageSummary) -> Bool {
    state.withLock { Self.remember(data, for: image, in: &$0) }
  }

  /// Keeps the bytes in memory. Past the limit, the images used longest ago go first. False after the session
  /// ended, when nothing is kept.
  private static func remember(_ data: Data, for image: ImageSummary, in state: inout State) -> Bool {
    guard !state.hasEnded else { return false }
    if let earlier = state.memory[image.url] { state.memoryBytes -= earlier.data.count }
    state.clock += 1
    state.memory[image.url] = (data, state.clock)
    state.memoryBytes += data.count
    while state.memoryBytes > memoryLimit, state.memory.count > 1,
      let oldest = state.memory.min(by: { $0.value.used < $1.value.used })
    {
      state.memory[oldest.key] = nil
      state.memoryBytes -= oldest.value.data.count
    }
    return true
  }

  /// Ends the cache with its session: it keeps nothing more, and forgets what it holds in memory. It cancels the
  /// loads in flight, and waits for them and for every write, so the device can then remove the folder.
  func end() async {
    let (loads, writes) = state.withLock { state in
      state.hasEnded = true
      state.memory = [:]
      state.memoryBytes = 0
      defer {
        state.loading = [:]
        state.writing = []
      }
      return (Array(state.loading.values), Array(state.writing))
    }
    for load in loads { load.cancel() }
    for load in loads { _ = await load.value }
    for write in writes { await write.value }
  }

  // MARK: - The folder

  /// The file of an image: its address, hashed, so the name gives nothing away.
  private func file(of image: ImageSummary) -> URL? {
    guard let folder else { return nil }
    let name = SHA256.hash(data: Data(image.url.utf8)).map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0\(hex)" : hex
    }.joined()
    return folder.appending(path: name, directoryHint: .notDirectory)
  }

  @concurrent
  private func isOnDisk(_ image: ImageSummary) async -> Bool {
    guard let file = file(of: image) else { return false }
    return FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
  }

  /// The bytes of the image on disk. A read marks the file as used now, so it goes last.
  @concurrent
  private func read(_ image: ImageSummary) async -> Data? {
    guard let file = file(of: image), let data = try? Data(contentsOf: file) else { return nil }
    try? FileManager.default.setAttributes(
      [.modificationDate: Date.now], ofItemAtPath: file.path(percentEncoded: false))
    return data
  }

  /// Writes the bytes to the folder, which it makes the first time. Past the limit, the files used longest ago go
  /// first. A write that fails leaves the image in memory only.
  @concurrent
  private func writeFile(_ data: Data, for image: ImageSummary) async {
    guard var folder, let file = file(of: image) else { return }
    do {
      if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The images come from the instance again, so they stay out of backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
      }
      let earlier = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      // Through the file manager, which replaces the file whole. A `write` of the data reads as a database write to
      // the fitness scan of the local copy's rules.
      guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: data) else {
        throw CocoaError(.fileWriteUnknown)
      }
      let total = state.withLock { state -> Int? in
        guard let bytes = state.diskBytes else { return nil }
        state.diskBytes = bytes - earlier + data.count
        return state.diskBytes
      }
      let bytes = total ?? countDisk()
      if bytes > Self.diskLimit { trimDisk() }
    } catch {
      Log.notice(.session, "An image can't be written to the image cache.", detail: "\(error)")
    }
  }

  /// Counts the bytes in the folder, and keeps the count.
  private func countDisk() -> Int {
    let bytes = filesOnDisk().reduce(0) { $0 + $1.size }
    state.withLock { $0.diskBytes = bytes }
    return bytes
  }

  /// Removes the files used longest ago, until the folder is under the limit.
  private func trimDisk() {
    var files = filesOnDisk().sorted { $0.used < $1.used }
    var bytes = files.reduce(0) { $0 + $1.size }
    while bytes > Self.diskLimit, !files.isEmpty {
      let oldest = files.removeFirst()
      try? FileManager.default.removeItem(at: oldest.url)
      bytes -= oldest.size
    }
    state.withLock { $0.diskBytes = bytes }
  }

  private func filesOnDisk() -> [(url: URL, size: Int, used: Date)] {
    guard let folder else { return [] }
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
    return urls.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
    }
  }
}
