import PhotosUI
import SwiftUI
import WishboneAPI
import WishboneSession

/// The profile gate: a new user checks their name, birthday and photo, and taps Continue. It replaces the whole
/// window while the user's `can_confirm_profile` is true. See `docs/screens/profile-gate.md`.
///
/// **Provisional.** The plain default: one system form with the profile's fields and a Continue button, and Sign
/// out in the toolbar.
struct ProfileGateScreen: View {
  let session: SessionModel

  /// What the form holds, as the person typed it. Each window has its own.
  @State private var draft: ProfileDraft

  /// How the last Continue ended. Nil before the first, and while one runs.
  @State private var outcome: ProfileOutcome?
  @State private var isSaving = false

  /// Whether Continue found the name empty.
  @State private var isNameMissing = false

  /// The new photo, as it shows on the form before it is saved.
  @State private var newPhoto: Image?

  @State private var isConfirmingSignOut = false
  @State private var isChoosingPhoto = false
  @State private var isTakingPhoto = false
  @State private var chosenPhoto: PhotosPickerItem?

  /// The width of the window, for the form's column of readable width.
  @State private var width: CGFloat = 0

  init(session: SessionModel, user: UserRow) {
    self.session = session
    _draft = State(initialValue: ProfileDraft(user))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          // The title is a row, where it wraps. In the bar, between Sign out and Continue, a long title is cut
          // short.
          Text("Finish your profile", bundle: #bundle)
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
          Text("Check your name and birthday. Your family sees them.", bundle: #bundle)
        }
        if let message {
          Section {
            Text(message)
          }
        }
        photo
        names
        birthday
      }
      .contentMargins(.horizontal, max(0, (width - Self.readableWidth) / 2), for: .scrollContent)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
      // The window's title. The bar doesn't draw it: the form's first row does.
      .navigationTitle(Text("Finish your profile", bundle: #bundle))
      .toolbar(removing: .title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            isConfirmingSignOut = true
          } label: {
            Text("Sign out", bundle: #bundle)
          }
          .disabled(isSaving)
        }
        // The form's main button, at the trailing end of the bar, as in every form of the app. It always shows,
        // at every text size, with no scrolling to reach it.
        ToolbarItem(placement: .confirmationAction) {
          continueButton
        }
      }
    }
    .signOutConfirmation(isPresented: $isConfirmingSignOut)
    .photosPicker(isPresented: $isChoosingPhoto, selection: $chosenPhoto, matching: .images)
    .task(id: chosenPhoto) { await takeChosenPhoto() }
    #if os(iOS)
      .fullScreenCover(isPresented: $isTakingPhoto) {
        CameraPicker { taken in use(PhotoFile(taken)) }
        .ignoresSafeArea()
      }
    #endif
  }

  /// The widest that the form's column gets in a wide window.
  private static let readableWidth: CGFloat = 640

  // MARK: - The photo

  private var hasPhoto: Bool {
    switch draft.photo {
    case .keep: session.user?.avatar != nil
    case .remove: false
    case .new: true
    }
  }

  private var photo: some View {
    Section {
      Menu {
        #if os(iOS)
          if PhotoFile.canTakePhotos {
            Button {
              isTakingPhoto = true
            } label: {
              Label {
                Text("Take a photo", bundle: #bundle)
              } icon: {
                Image(systemName: "camera")
              }
            }
          }
        #endif
        Button {
          isChoosingPhoto = true
        } label: {
          Label {
            Text("Choose a photo", bundle: #bundle)
          } icon: {
            Image(systemName: "photo.on.rectangle")
          }
        }
        if hasPhoto {
          Button(role: .destructive) {
            draft.photo = .remove
            newPhoto = nil
          } label: {
            Label {
              Text("Remove photo", bundle: #bundle)
            } icon: {
              Image(systemName: "trash")
            }
          }
        }
      } label: {
        HStack(spacing: 12) {
          PhotoPreview(session: session, photo: draft.photo, newPhoto: newPhoto)
          if hasPhoto {
            Text("Photo", bundle: #bundle)
          } else {
            Text("Add a photo", bundle: #bundle)
          }
        }
        .frame(minHeight: 44)
      }
      .accessibilityLabel(photoLabel)
      .disabled(isSaving)
      // A row, not the section's footer: a form draws a footer in the system's secondary gray, which is below
      // 4.5:1, whatever color the app gives it.
      Text("A photo is optional.", bundle: #bundle)
    }
  }

  /// "Photo, {name}" or "Add a photo".
  private var photoLabel: Text {
    hasPhoto ? Text("Photo, \(draft.trimmedName)", bundle: #bundle) : Text("Add a photo", bundle: #bundle)
  }

  /// Takes the photo that the person chose in the system photo picker.
  private func takeChosenPhoto() async {
    guard let chosenPhoto else { return }
    defer { self.chosenPhoto = nil }
    // A photo that can't be loaded changes nothing.
    guard let data = try? await chosenPhoto.loadTransferable(type: Data.self) else { return }
    use(PhotoFile(data))
  }

  private func use(_ file: PhotoFile) {
    draft.photo = .new(file.data)
    newPhoto = file.preview
    if case .photoRefused = outcome { outcome = nil }
  }

  // MARK: - The names

  private var names: some View {
    Section {
      FormRow(label: Text("Name", bundle: #bundle)) {
        TextField(text: $draft.name, prompt: Self.noPrompt) {
          Text("Name", bundle: #bundle)
        }
        .font(.body)
        .accessibilityLabel(Text("Name", bundle: #bundle))
        #if os(iOS)
          .textContentType(.givenName)
        #endif
        .onChange(of: draft.name) { isNameMissing = false }
      }
      if isNameMissing {
        FieldMark(words: Text("Enter your name.", bundle: #bundle))
      } else if isMarked(.name) {
        FieldMark(words: Text("Check your name.", bundle: #bundle))
      }
      FormRow(label: Text("Last name", bundle: #bundle)) {
        TextField(text: $draft.lastName, prompt: Self.noPrompt) {
          Text("Last name", bundle: #bundle)
        }
        .font(.body)
        .accessibilityLabel(Text("Last name", bundle: #bundle))
        #if os(iOS)
          .textContentType(.familyName)
        #endif
      }
      if isMarked(.lastName) {
        FieldMark(words: Text("Check your last name.", bundle: #bundle))
      }
    }
    .disabled(isSaving)
  }

  /// A name field shows no placeholder. Its label is above it, and the system's placeholder gray is far below
  /// 4.5:1. The field's label still names it for VoiceOver.
  private static let noPrompt = Text(String())

  // MARK: - The birthday

  private var birthday: some View {
    Section {
      // The section's title is a row: a form draws a header in the system's secondary gray, below 4.5:1.
      Text("Birthday", bundle: #bundle)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      MenuRow(label: Text("Month", bundle: #bundle), value: Text(Self.monthName(draft.birthday.month))) {
        Picker(selection: month) {
          ForEach(1...12, id: \.self) { month in
            Text(Self.monthName(month)).tag(month)
          }
        } label: {
          Text("Month", bundle: #bundle)
        }
      }
      MenuRow(label: Text("Day", bundle: #bundle), value: Text(draft.birthday.day, format: .number)) {
        Picker(selection: day) {
          ForEach(1...Self.days(in: draft.birthday.month), id: \.self) { day in
            Text(day, format: .number).tag(day)
          }
        } label: {
          Text("Day", bundle: #bundle)
        }
      }
      MenuRow(label: Text("Year (optional)", bundle: #bundle), value: yearWords) {
        Picker(selection: year) {
          Text("No year", bundle: #bundle).tag(Int?.none)
          ForEach(Self.years, id: \.self) { year in
            Text(year, format: .number.grouping(.never)).tag(Int?.some(year))
          }
        } label: {
          Text("Year (optional)", bundle: #bundle)
        }
      }
      Text("With a year, your family sees the age you're turning.", bundle: #bundle)
        .font(.footnote)
      if isMarked(.birthday) {
        FieldMark(words: Text("Check your birthday.", bundle: #bundle))
      }
    }
    .disabled(isSaving)
  }

  /// The year, or "No year".
  private var yearWords: Text {
    if let year = draft.birthday.year {
      Text(year, format: .number.grouping(.never))
    } else {
      Text("No year", bundle: #bundle)
    }
  }

  private var month: Binding<Int> {
    Binding {
      draft.birthday.month
    } set: { month in
      // A day that the new month doesn't have becomes its last.
      let day = min(draft.birthday.day, Self.days(in: month))
      draft.birthday = PartialDate(month: month, day: day, year: draft.birthday.year)
    }
  }

  private var day: Binding<Int> {
    Binding {
      draft.birthday.day
    } set: { day in
      draft.birthday = PartialDate(month: draft.birthday.month, day: day, year: draft.birthday.year)
    }
  }

  private var year: Binding<Int?> {
    Binding {
      draft.birthday.year
    } set: { year in
      draft.birthday = PartialDate(month: draft.birthday.month, day: draft.birthday.day, year: year)
    }
  }

  /// The month's name in the person's language, such as "June".
  private static func monthName(_ month: Int) -> String {
    let names = Calendar.current.standaloneMonthSymbols
    return names.indices.contains(month - 1) ? names[month - 1] : ""
  }

  /// The days that a birthday can have in the month, with February 29.
  private static func days(in month: Int) -> Int {
    switch month {
    case 2: 29
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// The years that a birthday can have, the latest first.
  private static var years: [Int] {
    let now = Calendar.current.component(.year, from: .now)
    return Array((now - 120...now).reversed())
  }

  // MARK: - Continue

  private var continueButton: some View {
    Button {
      Task { await confirm() }
    } label: {
      if isSaving {
        ProgressView()
      } else if case .unreachable = outcome {
        Text("Try again", bundle: #bundle)
      } else {
        Text("Continue", bundle: #bundle)
      }
    }
    .keyboardShortcut(.defaultAction)
    .disabled(isSaving)
  }

  private func confirm() async {
    guard !isSaving else { return }
    guard !draft.trimmedName.isEmpty else {
      isNameMissing = true
      return
    }
    isSaving = true
    outcome = nil
    let ended = await session.confirmProfile(draft)
    // A confirmed profile takes the gate away, in every window, when the copy has the answer. Until then, Continue
    // stays disabled.
    guard ended != .confirmed else { return }
    isSaving = false
    outcome = ended
    if case .photoRefused = ended {
      // The form keeps the old photo.
      draft.photo = .keep
      newPhoto = nil
    }
  }

  /// The words of the last Continue's outcome. Nil when it has none to show.
  private var message: String? {
    switch outcome {
    case nil, .confirmed:
      nil
    case .unreachable:
      String(localized: "Can't reach \(session.session.instance.text)", bundle: #bundle)
    case .refused(let refusal), .photoRefused(let refusal):
      ErrorWords.words(for: refusal)
    case .failed:
      ErrorWords.fault
    }
  }

  /// The fields of the form, by their names in the body of `PATCH /users/me`.
  private enum Field: String {
    case name
    case lastName = "last_name"
    case birthday
  }

  /// Whether a 422 `invalid_input` named the field.
  private func isMarked(_ field: Field) -> Bool {
    guard case .refused(let refusal) = outcome, refusal.code == .invalidInput else { return false }
    return refusal.fields.contains(field.rawValue)
  }
}

/// A text field's row: its label above the field. The label is hidden from VoiceOver, because the field carries
/// the same words as its own label.
private struct FormRow<Field: View>: View {
  let label: Text
  @ViewBuilder let field: Field

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      label
        .accessibilityHidden(true)
      field
    }
  }
}

/// A birthday row: a system menu with a system picker in it. Its label and its value are words that the app draws
/// in the primary color, because a form draws a picker's value in the system's secondary gray, which is below
/// 4.5:1. The value sits beside the label, and under it at the largest text sizes. VoiceOver reads the row as one
/// button, with its label and its value.
private struct MenuRow<Options: View>: View {
  let label: Text
  let value: Text
  @ViewBuilder let options: Options

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    Menu {
      options
        .pickerStyle(.inline)
    } label: {
      Group {
        if size.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 4) {
            label
            selected
          }
        } else {
          HStack {
            label
            Spacer()
            selected
          }
        }
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .foregroundStyle(.primary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(value)
    .accessibilityAddTraits(.isButton)
  }

  private var selected: some View {
    HStack(spacing: 4) {
      value
      Image(systemName: "chevron.up.chevron.down")
        .imageScale(.small)
        .accessibilityHidden(true)
    }
  }
}

/// The mark on a field that is not valid: what to do, under the field.
private struct FieldMark: View {
  let words: Text

  var body: some View {
    Label {
      words
    } icon: {
      Image(systemName: "exclamationmark.circle")
    }
    .font(.callout)
  }
}

/// The photo on the form: the new one, the saved avatar, or a person's outline.
private struct PhotoPreview: View {
  let session: SessionModel
  let photo: ProfileDraft.Photo
  let newPhoto: Image?

  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 44

  var body: some View {
    Group {
      if case .new = photo, let newPhoto {
        newPhoto.resizable().scaledToFill()
      } else if case .keep = photo, let avatar = session.user?.avatar, let request = session.imageRequest(avatar) {
        AsyncImage(request: request) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          outline
        }
      } else {
        outline
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  private var outline: some View {
    Image(systemName: "person.crop.circle")
      .resizable()
      .scaledToFit()
      .foregroundStyle(.primary)
  }
}
