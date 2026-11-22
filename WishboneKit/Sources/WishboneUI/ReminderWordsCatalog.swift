import Foundation
import WishboneSession

nonisolated extension ReminderWords {
  /// The words of the reminders, from the String Catalog. Each names only the occasion and the person, and when it
  /// is. See `docs/screens/reminder.md`, which holds the table.
  public static let catalog = ReminderWords(
    title: { String(localized: "Wishbone", bundle: #bundle) },
    body: { phrase in
      switch phrase.early {
      case nil: onTheDay(phrase.subject)
      case .oneWeek: inOneWeek(phrase.subject)
      case .twoWeeks: inTwoWeeks(phrase.subject)
      case .fourWeeks: inFourWeeks(phrase.subject)
      }
    }
  )

  private static func onTheDay(_ subject: ReminderSubject) -> String {
    switch subject {
    case .birthday(let person):
      String(localized: "It's \(person)'s birthday today", bundle: #bundle)
    case .custom(let person, let occasion):
      String(localized: "It's \(person)'s \(occasion) today", bundle: #bundle)
    case .shared(let occasion):
      String(localized: "It's \(occasion) today", bundle: #bundle)
    case .ownBirthday:
      String(localized: "It's your birthday today", bundle: #bundle)
    case .ownCustom(let occasion):
      String(localized: "It's your \(occasion) today", bundle: #bundle)
    }
  }

  private static func inOneWeek(_ subject: ReminderSubject) -> String {
    switch subject {
    case .birthday(let person):
      String(localized: "\(person)'s birthday is in 1 week", bundle: #bundle)
    case .custom(let person, let occasion):
      String(localized: "\(person)'s \(occasion) is in 1 week", bundle: #bundle)
    case .shared(let occasion):
      String(localized: "\(occasion) is in 1 week", bundle: #bundle)
    case .ownBirthday:
      String(localized: "Your birthday is in 1 week", bundle: #bundle)
    case .ownCustom(let occasion):
      String(localized: "Your \(occasion) is in 1 week", bundle: #bundle)
    }
  }

  private static func inTwoWeeks(_ subject: ReminderSubject) -> String {
    switch subject {
    case .birthday(let person):
      String(localized: "\(person)'s birthday is in 2 weeks", bundle: #bundle)
    case .custom(let person, let occasion):
      String(localized: "\(person)'s \(occasion) is in 2 weeks", bundle: #bundle)
    case .shared(let occasion):
      String(localized: "\(occasion) is in 2 weeks", bundle: #bundle)
    case .ownBirthday:
      String(localized: "Your birthday is in 2 weeks", bundle: #bundle)
    case .ownCustom(let occasion):
      String(localized: "Your \(occasion) is in 2 weeks", bundle: #bundle)
    }
  }

  private static func inFourWeeks(_ subject: ReminderSubject) -> String {
    switch subject {
    case .birthday(let person):
      String(localized: "\(person)'s birthday is in 4 weeks", bundle: #bundle)
    case .custom(let person, let occasion):
      String(localized: "\(person)'s \(occasion) is in 4 weeks", bundle: #bundle)
    case .shared(let occasion):
      String(localized: "\(occasion) is in 4 weeks", bundle: #bundle)
    case .ownBirthday:
      String(localized: "Your birthday is in 4 weeks", bundle: #bundle)
    case .ownCustom(let occasion):
      String(localized: "Your \(occasion) is in 4 weeks", bundle: #bundle)
    }
  }
}
