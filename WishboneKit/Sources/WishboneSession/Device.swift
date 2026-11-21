import Foundation
import Observation
import WishboneAPI

/// Where a session's local database goes.
public enum SessionStorage: Sendable {
  /// In memory, for the share extension and for tests. Nothing is on disk.
  case memory

  /// Under this folder, which is the app's own Application Support folder. Each instance and user has a database
  /// file of its own there.
  case folder(URL)
}

/// What the signed-out screen shows. See "States" in `docs/screens/signed-out.md`.
public enum SignInState: Sendable, Equatable {
  /// No message.
  case plain
  case signingIn

  /// "Signed in as {name}" shows briefly, before the next screen.
  case signedIn(name: String)

  /// The link is used or expired. The server gives one answer for an unknown, a used, and an expired link.
  case linkInvalid

  /// A paste of something that is not a login link.
  case notALoginLink

  /// The instance can't be reached. The device keeps the link, for Try again.
  case unreachable(InstanceAddress)

  /// The address answered, and not as a Wishbone does.
  case noWishbone(InstanceAddress)

  /// The instance is older than the minimum server version. The link is not used.
  case instanceTooOld(InstanceAddress, version: String, minimum: String)

  /// The server refused the sign-in with another code.
  case refused(APIError.Refusal)

  /// A fault of the app.
  case failed
}

/// The device: it holds one session at most. It signs in with a login link, and it holds the session model while
/// it is signed in. See ADR 0010, and "Sign-in, instances and the session" in `docs/spec.md`.
///
/// The app's composition root builds one, and puts it in the environment of every window scene.
@Observable
@MainActor
public final class Device {
  /// What the composition root gives a device.
  public struct Setup: Sendable {
    public var userAgent: UserAgent
    public var keychain: any SessionKeychain
    public var storage: SessionStorage

    /// The clock of every timeout.
    public var clock: any Clock<Duration>

    public init(
      userAgent: UserAgent,
      keychain: any SessionKeychain,
      storage: SessionStorage,
      clock: any Clock<Duration> = ContinuousClock()
    ) {
      self.userAgent = userAgent
      self.keychain = keychain
      self.storage = storage
      self.clock = clock
    }
  }

  /// The session model of the session that the device holds. Nil while the device is signed out.
  public private(set) var session: SessionModel?

  /// What the signed-out screen shows.
  public private(set) var signInState = SignInState.plain

  private let setup: Setup

  /// The link that the device keeps while the instance can't be reached, for Try again.
  private var keptLink: LoginLink?

  /// Builds the device, with the session that the session keychain holds. Its screens show what is saved at once.
  public init(_ setup: Setup) {
    self.setup = setup
    do {
      if let kept = try setup.keychain.read() { session = model(for: kept) }
    } catch {
      // The item can't be read, for example before the first unlock. Nothing is forgotten.
      Log.fault(.session, "The session keychain can't be read.", detail: "\(error.status)")
    }
  }

  // MARK: - Signing in

  /// Signs in with the text that a person pasted. A text that is not a login link changes nothing but the message.
  ///
  /// It returns when the sign-in has ended. After a sign-in that worked, the first sync has ended too.
  public func signIn(pasting text: String) async {
    guard canStartSignIn else { return }
    guard let link = LoginLink(text) else {
      keptLink = nil
      signInState = .notALoginLink
      return
    }
    await signIn(with: link)
  }

  /// Tries the kept link again, after the instance could not be reached.
  public func tryAgain() async {
    guard canStartSignIn, let keptLink else { return }
    await signIn(with: keptLink)
  }

  /// Forgets the kept link, and returns to the plain state.
  public func cancelSignIn() {
    guard signInState != .signingIn else { return }
    keptLink = nil
    signInState = .plain
  }

  /// Ends "Signed in as {name}": the signed-out screen's state is plain again, under the next screen.
  public func finishWelcome() {
    if case .signedIn = signInState { signInState = .plain }
  }

  /// The app never redeems a login link while it is signed in, and one sign-in runs at a time.
  private var canStartSignIn: Bool {
    session == nil && signInState != .signingIn
  }

  private func signIn(with link: LoginLink) async {
    keptLink = nil
    signInState = .signingIn
    let client = APIClient(instance: link.instance, userAgent: setup.userAgent, clock: setup.clock)
    let redeemed: (session: Session, name: String)
    do {
      // The version check comes first, so a link is never used up on an instance that the app can't work with.
      switch try await client.checkVersion() {
      case .passes:
        break
      case .tooOld(let version, let minimum):
        signInState = .instanceTooOld(link.instance, version: version, minimum: minimum)
        return
      case .noWishbone:
        signInState = .noWishbone(link.instance)
        return
      }
      redeemed = try await client.redeem(link)
    } catch {
      switch error {
      case .unreachable:
        keptLink = link
        signInState = .unreachable(link.instance)
      case .cancelled:
        keptLink = link
        signInState = .plain
      case .refused(let refusal) where refusal.code == .loginLinkInvalid:
        signInState = .linkInvalid
      case .refused(let refusal):
        signInState = .refused(refusal)
      case .unauthorized, .appTooOld, .undecodable:
        signInState = .failed
      }
      return
    }

    // The link is used now, so the session is saved at once.
    do {
      try setup.keychain.save(redeemed.session)
    } catch {
      // The session works until the app ends. The next launch starts signed out.
      Log.fault(.session, "The session keychain can't keep the session.", detail: "\(error.status)")
    }
    guard let model = model(for: redeemed.session) else {
      signInState = .failed
      return
    }
    session = model
    signInState = .signedIn(name: redeemed.name)
    await model.sync()
  }

  /// The session model of a session, with its local database and its client.
  private func model(for session: Session) -> SessionModel? {
    guard let database = LocalDatabase.of(session, in: setup.storage) else { return nil }
    let client = APIClient(session: session, userAgent: setup.userAgent, clock: setup.clock)
    return SessionModel(session: session, client: client, database: database)
  }
}
