import Foundation
import WishboneAPI

/// What the profile gate's form holds, as the person typed it. See `docs/screens/profile-gate.md`.
public struct ProfileDraft: Sendable, Equatable {
  /// The first name. Required.
  public var name: String

  /// The last name. Empty is no last name.
  public var lastName: String

  /// The month and day, and the year when the person gave one.
  public var birthday: PartialDate

  /// What becomes of the avatar.
  public var photo: Photo

  /// What becomes of the avatar.
  public enum Photo: Sendable, Equatable {
    /// The avatar stays as it is.
    case keep

    /// The avatar goes.
    case remove

    /// The bytes of a new image file, to upload and use as the avatar.
    case new(Data)
  }

  public init(name: String, lastName: String, birthday: PartialDate, photo: Photo = .keep) {
    self.name = name
    self.lastName = lastName
    self.birthday = birthday
    self.photo = photo
  }

  /// The draft that the form starts with: what the profile has, and the avatar kept.
  public init(_ user: UserRow) {
    name = user.name
    lastName = user.record?.lastName ?? ""
    birthday = user.record?.birthday ?? PartialDate(month: 1, day: 1)
    photo = .keep
  }

  /// The name with no space at either end. The gate needs one that is not empty.
  public var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The merge patch of the fields that differ from the user's, with no photo: the photo's ID comes from its
  /// upload.
  func changes(from user: UserRow) -> UserChanges {
    var changes = UserChanges()
    if trimmedName != user.name { changes.name = trimmedName }
    let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
    let newLast: String? = last.isEmpty ? nil : last
    if newLast != user.record?.lastName { changes.lastName = .some(newLast) }
    if birthday != user.record?.birthday { changes.birthday = birthday }
    if photo == .remove, user.avatar != nil { changes.avatarImageID = .some(nil) }
    return changes
  }
}

/// How Continue at the profile gate ended. See "States" in `docs/screens/profile-gate.md`.
public enum ProfileOutcome: Sendable, Equatable {
  /// The server confirmed the profile. The gate goes from every window.
  case confirmed

  /// The instance can't be reached. Nothing is confirmed, and the form keeps what was typed, for Try again.
  case unreachable

  /// The server refused the photo. Nothing else was sent, and the avatar stays as it was.
  case photoRefused(APIError.Refusal)

  /// The server refused the changes or the confirmation, such as a 422 `invalid_input` that names fields.
  case refused(APIError.Refusal)

  /// A fault of the app, such as an answer that it can't read.
  case failed
}

extension SessionModel {
  /// Whether every window shows the profile gate in place of the tabs: the user's `can_confirm_profile` is true.
  /// False until the copy holds the user. See "The profile gate" in `docs/spec.md`.
  public var needsProfileGate: Bool {
    user?.record?.canConfirmProfile == true
  }

  /// Continue at the profile gate: it uploads a new photo, saves the fields that differ from the profile with
  /// `PATCH /users/me`, and then confirms with `POST /users/me/confirm-profile`. It waits for the server, and is
  /// never an unsent change. See "Other writes that wait for the server" in `docs/spec.md`.
  ///
  /// Each answer goes into the copy as it comes. So after a save that worked and a confirmation that could not be
  /// sent, Try again sends only the confirmation.
  ///
  /// Diagnostics: never, for now. A refusal of a write that the app sent will be captured once `WishboneDiagnostics`
  /// holds the vocabulary (see `APIError`).
  public func confirmProfile(_ draft: ProfileDraft) async -> ProfileOutcome {
    guard !hasEnded, let user else { return .failed }
    var changes = draft.changes(from: user)
    if case .new(let file) = draft.photo {
      do {
        let image = try await client.uploadImage(file)
        changes.avatarImageID = .some(image.id)
      } catch {
        return outcome(of: error, photo: true)
      }
    }
    do {
      if !changes.isEmpty {
        try await keep(try await client.updateMe(changes))
      }
      try await keep(try await client.confirmProfile())
      return .confirmed
    } catch let error as APIError {
      return outcome(of: error, photo: false)
    } catch is CancellationError {
      // A sign-out ended the session during Continue. It is no fault of the copy.
      return .failed
    } catch {
      Log.fault(.session, "The copy can't take the user's record.", detail: "\(error)")
      return .failed
    }
  }

  /// The request for an image of the instance, with the session's token.
  public func imageRequest(_ image: ImageSummary) -> URLRequest? {
    client.imageRequest(image)
  }

  /// Puts an answer of the server about the session's own user into the copy, which every window reads.
  private func keep(_ user: Versioned<User>) async throws {
    guard !hasEnded else { throw CancellationError() }
    try await database.save([user])
  }

  private func outcome(of error: APIError, photo: Bool) -> ProfileOutcome {
    switch error {
    case .unreachable:
      .unreachable
    case .refused(let refusal):
      photo ? .photoRefused(refusal) : .refused(refusal)
    case .cancelled, .unauthorized, .appTooOld, .undecodable:
      // The API's own 401 and 410 have screens of their own, which are not built yet.
      .failed
    }
  }
}
