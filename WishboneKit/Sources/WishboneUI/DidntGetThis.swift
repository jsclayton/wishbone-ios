import SwiftUI
import WishboneAPI
import WishboneSession

// I didn't get this, on a given gift's page and a Received row. See `docs/screens/gift.md` and
// `docs/screens/gifts.md`.
//
// **The words promise nothing about the giver.** The confirmation is the same whether the giver is active,
// deactivated, or deleted: a recipient can't tell these apart. It says that the gift leaves Received, because the
// server hides it from the person who tapped it.

/// What I didn't get this asks about: the gift, and whom it speaks for.
struct RestoreAsk: Equatable, Identifiable {
  let gift: GiftRow
  let restorer: Restorer

  var id: String { gift.id }
}

/// The words of I didn't get this: the row, the confirmation, its button, and what a restore that didn't happen says.
enum RestoreWords {
  /// The row, the action, and the confirmation's button: "I didn't get this", or "Emma didn't get this" for a child.
  /// The words say what it does, so the row doesn't say it by color alone.
  static func action(of restorer: Restorer) -> String {
    switch restorer {
    case .sessionUser:
      String(localized: "I didn't get this", bundle: #bundle)
    case .child(let child):
      String(
        localized: "\(child.name) didn't get this", bundle: #bundle,
        comment: "I didn't get this, for a child: the child's name")
    }
  }

  /// The confirmation's question: "You didn't get Kite?", or "Emma didn't get Kite?" for a child.
  static func question(_ title: String, of restorer: Restorer) -> String {
    switch restorer {
    case .sessionUser:
      String(
        localized: "You didn't get \(title)?", bundle: #bundle,
        comment: "The confirmation of I didn't get this: the item's title")
    case .child(let child):
      String(
        localized: "\(child.name) didn't get \(title)?", bundle: #bundle,
        comment: "The confirmation of I didn't get this, for a child: the child's name, then the item's title")
    }
  }

  /// The confirmation's message, under the question. It is the same whatever the giver's state.
  static var message: String {
    String(
      localized: "It leaves your Received. If the giver still uses Wishbone, they see that, and can give it again.",
      bundle: #bundle)
  }

  /// What a restore that didn't happen says. Nil for a restore that happened, or that the copy no longer offers.
  static func result(of outcome: RestoreOutcome, address: InstanceAddress) -> String? {
    switch outcome {
    case .restored, .notOffered:
      nil
    case .unreachable:
      String(localized: "Can't reach \(address.text). Nothing changed.", bundle: #bundle)
    case .refused(let refusal):
      ErrorWords.words(for: refusal) ?? ErrorWords.fault
    case .failed:
      ErrorWords.fault
    }
  }
}

extension View {
  /// The confirmation of I didn't get this: "You didn't get {title}?", the message, and the button "I didn't get
  /// this". For a child, "{name} didn't get {title}?", with the button "{name} didn't get this". `confirm` runs on
  /// the button.
  func didntGetThisConfirmation(of ask: Binding<RestoreAsk?>, confirm: @escaping (RestoreAsk) -> Void) -> some View {
    confirmationDialog(
      ask.wrappedValue.map { RestoreWords.question($0.gift.title, of: $0.restorer) } ?? "",
      isPresented: Binding {
        ask.wrappedValue != nil
      } set: {
        if !$0 { ask.wrappedValue = nil }
      },
      titleVisibility: .visible,
      presenting: ask.wrappedValue
    ) { shown in
      Button(RestoreWords.action(of: shown.restorer), role: .destructive) {
        confirm(shown)
      }
    } message: { shown in
      if shown.restorer == .sessionUser {
        Text(RestoreWords.message)
      }
    }
  }
}
