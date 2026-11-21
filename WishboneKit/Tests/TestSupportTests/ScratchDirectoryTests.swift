import Foundation
import TestSupport
import Testing

@Suite("ScratchDirectory", .timeLimit(.minutes(1)))
struct ScratchDirectoryTests {
  private let files = FileManager.default

  private func exists(_ url: URL) -> Bool {
    files.fileExists(atPath: url.path(percentEncoded: false))
  }

  @Test("A folder goes when its last holder goes")
  func goesWithItsLastHolder() throws {
    var first: ScratchDirectory? = try ScratchDirectory("held")
    var second = first
    let url = try #require(first?.url)
    try Data("kept".utf8).write(to: url.appending(path: "file"))

    first = nil
    #expect(exists(url))

    second = nil
    #expect(!exists(url))
    _ = second
  }

  @Test("Two folders have different places, under one root for the test process")
  func oneRoot() throws {
    let first = try ScratchDirectory()
    let second = try ScratchDirectory()
    #expect(first.url != second.url)
    #expect(first.url.deletingLastPathComponent() == second.url.deletingLastPathComponent())
    #expect(first.url.path().hasPrefix(ScratchDirectory.base.path()))
  }

  @Test("A folder stops the process that it adopted, before it goes")
  func stopsItsProcess() throws {
    let folder = try ScratchDirectory("adopter")
    let process = try Subprocess(URL(filePath: "/bin/sleep"), arguments: ["600"], directory: folder.url)
    try folder.adopt(process.identity)
    #expect(process.isRunning)

    folder.remove()
    #expect(!process.isRunning)
    #expect(!exists(folder.url))
  }

  @Test("The root of a dead process is swept, with its server stopped first")
  func sweepsTheRootOfADeadProcess() throws {
    let base = try ScratchDirectory("base")
    let outside = try ScratchDirectory("outside")

    // A test process that was killed: it has ended, and its root is still there.
    let owner = try Subprocess(URL(filePath: "/bin/sleep"), arguments: ["600"], directory: base.url)
    let root = try ScratchDirectory.makeRoot(in: base.url, owner: owner.identity)
    owner.stop()

    // Its server still runs. When it is asked to stop, it notes whether its data folder is still there.
    let dataFolder = root.appending(path: "server-1", directoryHint: .isDirectory)
    try files.createDirectory(at: dataFolder, withIntermediateDirectories: false)
    let note = outside.url.appending(path: "the-data-folder-was-there")
    let ready = outside.url.appending(path: "ready")
    let script = """
      trap 'test -d "$0" && touch "$1"; exit 0' TERM
      touch "$2"
      while :; do sleep 0.05; done
      """
    let server = try Subprocess(
      URL(filePath: "/bin/sh"),
      arguments: ["-c", script, dataFolder.path(), note.path(), ready.path()],
      environment: ["PATH": "/usr/bin:/bin"],
      directory: root
    )
    try ScratchDirectory.record([server.identity], beside: dataFolder)
    while !exists(ready) {
      #expect(server.isRunning)
      usleep(10_000)
    }

    let swept = ScratchDirectory.sweep(base.url)

    #expect(swept.map(\.lastPathComponent) == [root.lastPathComponent])
    #expect(!server.isRunning)
    #expect(exists(note), "The server was stopped after its data folder was removed, or was not asked to stop.")
    #expect(!exists(root))
  }

  @Test("The root of a live process stays, and so does its server")
  func keepsTheRootOfALiveProcess() throws {
    let base = try ScratchDirectory("base")
    let owner = try Subprocess(URL(filePath: "/bin/sleep"), arguments: ["600"], directory: base.url)
    let root = try ScratchDirectory.makeRoot(in: base.url, owner: owner.identity)
    let dataFolder = root.appending(path: "server-1", directoryHint: .isDirectory)
    try files.createDirectory(at: dataFolder, withIntermediateDirectories: false)
    let server = try Subprocess(URL(filePath: "/bin/sleep"), arguments: ["600"], directory: root)
    try ScratchDirectory.record([server.identity], beside: dataFolder)
    // Something that is not a root is never swept.
    let other = base.url.appending(path: "notes", directoryHint: .isDirectory)
    try files.createDirectory(at: other, withIntermediateDirectories: false)

    #expect(ScratchDirectory.sweep(base.url).isEmpty)
    #expect(server.isRunning)
    #expect(exists(dataFolder))
    #expect(exists(other))
  }

  @Test("A record of a process doesn't stop another process that got its ID later")
  func identityIsNotOnlyTheID() throws {
    let folder = try ScratchDirectory()
    let process = try Subprocess(URL(filePath: "/bin/sleep"), arguments: ["600"], directory: folder.url)
    let earlier = ProcessIdentity(pid: process.identity.pid, started: process.identity.started - 1_000_000)
    #expect(!earlier.isRunning)
    #expect(earlier.hasEnded)
    #expect(!process.identity.hasEnded)
    #expect(!ProcessIdentity.current.hasEnded)

    earlier.stop()
    #expect(process.isRunning)
  }
}
