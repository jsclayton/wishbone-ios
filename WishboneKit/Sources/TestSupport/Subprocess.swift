import Darwin
import Foundation

/// A child process that a test starts. It stops when its last holder goes.
///
/// The child gets only the environment that the caller names, and no open file of the test process: its input is
/// empty, and its output goes to one file, or nowhere.
public final class Subprocess: Sendable {
  public let identity: ProcessIdentity

  /// Starts `executable` in the folder `directory`.
  public init(
    _ executable: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    directory: URL,
    output: URL? = nil
  ) throws {
    // posix_spawn can't set the child's folder on iOS. The shell changes to the folder, and then becomes the
    // program, so the process keeps its ID.
    let command = ["/bin/sh", "-c", #"cd "$1" && shift && exec "$@""#, "sh", directory.path(percentEncoded: false)]
    let argv = command + [executable.path(percentEncoded: false)] + arguments
    let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    let sink = output?.path(percentEncoded: false) ?? "/dev/null"
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, sink, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // The child gets only the three files above. It also gets every signal as the system gives it: a test runner
    // can ignore a signal, and a child would then ignore it too, so a request to stop would do nothing.
    var every = sigset_t()
    sigfillset(&every)
    posix_spawnattr_setsigdefault(&attributes, &every)
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigmask(&attributes, &none)
    posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    var pid: pid_t = 0
    let result = Self.withCStrings(argv) { argv in
      Self.withCStrings(envp) { envp in
        posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
      }
    }
    guard result == 0 else { throw CouldNotStart(executable: executable, reason: String(cString: strerror(result))) }
    guard let identity = ProcessIdentity(pid: pid) else {
      throw CouldNotStart(executable: executable, reason: "the system has no record of the new process")
    }
    self.identity = identity
  }

  deinit {
    stop()
  }

  public var isRunning: Bool {
    identity.isRunning
  }

  /// Stops the process, and returns when it is gone.
  public func stop() {
    identity.stop()
  }

  public struct CouldNotStart: Error, CustomStringConvertible {
    public let executable: URL
    public let reason: String

    public var description: String {
      "Could not start \(executable.path(percentEncoded: false)): \(reason)"
    }
  }

  /// Calls `body` with the strings as a C array that ends with a null pointer.
  private static func withCStrings<Result>(
    _ strings: [String],
    _ body: ([UnsafeMutablePointer<CChar>?]) -> Result
  ) -> Result {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
  }
}
