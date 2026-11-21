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

  /// A paste of something that is not a login link. A link that the device keeps stays kept, for Try again.
  case notALoginLink

  /// The instance can't be reached. The device keeps the link, for Try again.
  case unreachable(InstanceAddress)

  /// The server refused the redeem for too many tries (429 `rate_limited`). The device keeps the link, for Try
  /// again.
  case tooManyTries

  /// The device doesn't trust the instance's certificate. There is no way around it, so the link is not kept.
  case certificateNotTrusted(InstanceAddress)

  /// The address answered, and not as a Wishbone does.
  case noWishbone(InstanceAddress)

  /// The instance is older than the minimum server version. The link is not used.
  case instanceTooOld(InstanceAddress, version: String, minimum: String)

  /// The server refused the sign-in with another code.
  case refused(APIError.Refusal)

  /// A fault of the app.
  case failed

  /// The device signed out, and the instance could not be reached to revoke the session. So the device still shows
  /// in the user's Devices list.
  case signedOutUnreachable(InstanceAddress)

  /// The instance ended the session with the API's own 401, and the device forgot everything. The server doesn't
  /// say why: the session was revoked, went a year unused, or its user was deactivated.
  case signedOutByServer(InstanceAddress)
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

    /// The install marker in the app group's shared container.
    public var marker: any InstallMarker
    public var storage: SessionStorage

    /// The clock of every timeout.
    public var clock: any Clock<Duration>

    /// The device's time zone, which the session reports to the user's record.
    public var timeZone: TimeZoneSource

    public init(
      userAgent: UserAgent,
      keychain: any SessionKeychain,
      marker: any InstallMarker,
      storage: SessionStorage,
      clock: any Clock<Duration> = ContinuousClock(),
      timeZone: TimeZoneSource = .system
    ) {
      self.userAgent = userAgent
      self.keychain = keychain
      self.marker = marker
      self.storage = storage
      self.clock = clock
      self.timeZone = timeZone
    }
  }

  /// The session model of the session that the device holds. Nil while the device is signed out.
  public private(set) var session: SessionModel?

  /// What the signed-out screen shows.
  public private(set) var signInState = SignInState.plain

  private let setup: Setup

  /// Whether a sign-out is under way: the device is asking the instance to revoke the session, or is clearing
  /// itself after the API's own 401.
  public private(set) var isSigningOut = false

  /// The link that the device keeps while the instance can't be reached, or after too many tries, for Try again.
  private var keptLink: LoginLink?

  /// Whether the device keeps a link, so the signed-out screen shows Try again and Cancel.
  public var keepsLink: Bool {
    keptLink != nil
  }

  /// The revoke of a session that an earlier install left, while it runs.
  private var revokingLeftOver: Task<Void, Never>?

  /// Builds the device, with the session that the session keychain holds. Its screens show what is saved at once.
  ///
  /// A session with no install marker is left over from an earlier install of the app: the device forgets it at
  /// once, and asks its instance to revoke it. With no session, the device clears the local databases, which a
  /// backup restored onto a new device can bring with no Keychain item. See "A fresh install starts signed out" in
  /// `docs/spec.md`.
  public init(_ setup: Setup) {
    self.setup = setup
    let kept: Session?
    do {
      kept = try setup.keychain.read()
    } catch {
      // The item can't be read, for example before the first unlock. Nothing is forgotten.
      Log.fault(.session, "The session keychain can't be read.", detail: "\(error.status)")
      return
    }
    guard let kept else {
      LocalDatabase.removeAll(in: setup.storage)
      return
    }
    guard setup.marker.isPresent else {
      forgetLeftOver(kept)
      return
    }
    session = model(for: kept)
  }

  /// Waits until the device has done what it started at launch: the revoke of a session that an earlier install
  /// left. It returns at once when there is none.
  public func launchEnded() async {
    await revokingLeftOver?.value
  }

  /// Forgets a session that an earlier install left, and asks its instance once to revoke it. The device is
  /// signed out at once, whatever the instance answers, and shows no message.
  ///
  /// Diagnostics: never. A failed revoke is not captured, and not a breadcrumb: the client has logged the
  /// request's outcome.
  private func forgetLeftOver(_ leftOver: Session) {
    do {
      try setup.keychain.delete()
    } catch {
      Log.fault(.session, "The session keychain can't forget the session.", detail: "\(error.status)")
    }
    LocalDatabase.removeAll(in: setup.storage)
    let client = APIClient(session: leftOver, userAgent: setup.userAgent, clock: setup.clock)
    revokingLeftOver = Task {
      // A refusal and an unreachable instance end the same: the session stays in the user's Devices list until
      // someone revokes it, or it goes 365 days unused.
      try? await client.revokeCurrentSession()
    }
  }

  // MARK: - Signing in

  /// Signs in with the text that a person pasted. A text that is not a login link changes nothing but the message,
  /// and a link that the device keeps stays kept.
  ///
  /// It returns when the sign-in has ended. After a sign-in that worked, the first sync and the report of the time
  /// zone have ended too. Nothing on screen waits for the report.
  public func signIn(pasting text: String) async {
    guard canStartSignIn else { return }
    guard let link = LoginLink(text) else {
      signInState = .notALoginLink
      return
    }
    await signIn(with: link)
  }

  /// Signs in with a login link that the scanner read. The scanner ignores any other QR code, so it has no
  /// message for one.
  ///
  /// It returns when the sign-in has ended, as a paste does.
  public func signIn(scanned link: LoginLink) async {
    guard canStartSignIn else { return }
    await signIn(with: link)
  }

  /// Tries the kept link again, after the instance could not be reached, or after too many tries.
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

  /// The app never redeems a login link while it is signed in, or while a sign-out still clears the device, and
  /// one sign-in runs at a time.
  private var canStartSignIn: Bool {
    session == nil && !isSigningOut && signInState != .signingIn
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
      case .unreachable(.untrustedCertificate):
        signInState = .certificateNotTrusted(link.instance)
      case .unreachable:
        keptLink = link
        signInState = .unreachable(link.instance)
      case .cancelled:
        signInState = .plain
      case .refused(let refusal) where refusal.code == .loginLinkInvalid:
        signInState = .linkInvalid
      case .refused(let refusal) where refusal.code == .rateLimited:
        // The server refused the try before it looked at the link, so the link still works later.
        keptLink = link
        signInState = .tooManyTries
      case .refused(let refusal):
        signInState = .refused(refusal)
      case .unauthorized, .appTooOld, .undecodable:
        signInState = .failed
      }
      return
    }

    // The link is used now, so the session is saved at once. The marker comes first, so a saved session always
    // has one.
    do {
      try setup.marker.place()
    } catch {
      // The session works until the app ends. The next launch finds no marker, and revokes it.
      Log.fault(.session, "The install marker can't be placed.", detail: "\(error)")
    }
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
    await model.reportTimeZone()
  }

  // MARK: - Signing out

  /// Signs out: asks the instance once to revoke the session, then forgets it on the device, whatever the answer.
  /// See "Sign out" in `docs/spec.md`.
  ///
  /// The device then has no session, so every window shows the signed-out screen. When the instance could not be
  /// reached, that screen says the device still shows in the Devices list. The device keeps no token to try again
  /// with.
  ///
  /// It returns when the device is cleared.
  public func signOut() async {
    guard let model = session, !isSigningOut else { return }
    isSigningOut = true
    defer { isSigningOut = false }
    let wasReached = await model.revokeOnServer()
    session = nil
    await forget(model)
    keptLink = nil
    signInState = wasReached ? .plain : .signedOutUnreachable(model.session.instance)
  }

  /// Forgets the session after the instance ended it with the API's own 401, and says so: every window shows the
  /// signed-out screen with the message. See "The API's own 401 signs the device out" in `docs/spec.md`.
  ///
  /// The session model calls this from the request that got the 401. It does nothing for a session model that the
  /// device no longer holds, or while a sign-out clears the device: that sign-out forgets everything already.
  ///
  /// Diagnostics: never. The API's own 401 is not captured, and not a breadcrumb: it is no fault, and the client
  /// has logged the request's outcome.
  private func endedByServer(_ model: SessionModel) async {
    guard session === model, !isSigningOut else { return }
    isSigningOut = true
    defer { isSigningOut = false }
    session = nil
    await forget(model)
    keptLink = nil
    signInState = .signedOutByServer(model.session.instance)
  }

  /// Forgets everything of the session on the device: its session model, the session keychain's item, and the
  /// local databases. Nothing of the session is left.
  private func forget(_ model: SessionModel) async {
    await model.end()
    do {
      try setup.keychain.delete()
    } catch {
      // The next launch finds the item, and its token, which the server has revoked if it could be reached.
      Log.fault(.session, "The session keychain can't forget the session.", detail: "\(error.status)")
    }
    LocalDatabase.removeAll(in: setup.storage)
  }

  /// The session model of a session, with its local database and its client.
  private func model(for session: Session) -> SessionModel? {
    guard let database = LocalDatabase.of(session, in: setup.storage) else { return nil }
    let client = APIClient(session: session, userAgent: setup.userAgent, clock: setup.clock)
    return SessionModel(
      session: session, client: client, database: database, timeZone: setup.timeZone,
      endedByServer: { [weak self] model in await self?.endedByServer(model) })
  }
}
