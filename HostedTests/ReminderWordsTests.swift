import Testing
import WishboneSession
import WishboneUI

/// The words of the reminders, from the String Catalog: they name the occasion and the person, and when it is, and
/// nothing more. See `docs/screens/reminder.md`, which holds the table.
@Suite("The words of the reminders", .timeLimit(.minutes(1)))
@MainActor
struct ReminderWordsTests {
  private func words(_ subject: ReminderSubject, _ early: EarlyReminder?) -> String {
    ReminderWords.catalog.body(ReminderPhrase(subject: subject, early: early))
  }

  @Test("The early reminder and the one on the day, for each kind of occasion, as the table has them")
  func table() {
    let table: [(ReminderSubject, early: String, onTheDay: String)] = [
      (.birthday(person: "Emma"), "Emma's birthday is in 2 weeks", "It's Emma's birthday today"),
      (
        .custom(person: "Emma", occasion: "graduation"), "Emma's graduation is in 2 weeks",
        "It's Emma's graduation today"
      ),
      (.shared(occasion: "Christmas"), "Christmas is in 2 weeks", "It's Christmas today"),
      (.ownBirthday, "Your birthday is in 2 weeks", "It's your birthday today"),
      (.ownCustom(occasion: "recital"), "Your recital is in 2 weeks", "It's your recital today"),
    ]
    for (subject, early, onTheDay) in table {
      #expect(words(subject, .twoWeeks) == early)
      #expect(words(subject, nil) == onTheDay)
    }
    #expect(ReminderWords.catalog.title() == "Wishbone")
  }

  @Test("The time in the early reminder follows the setting")
  func timing() {
    let subject = ReminderSubject.birthday(person: "Emma")
    #expect(words(subject, .oneWeek) == "Emma's birthday is in 1 week")
    #expect(words(subject, .twoWeeks) == "Emma's birthday is in 2 weeks")
    #expect(words(subject, .fourWeeks) == "Emma's birthday is in 4 weeks")
    #expect(words(.custom(person: "Emma", occasion: "graduation"), .oneWeek) == "Emma's graduation is in 1 week")
    #expect(words(.shared(occasion: "Christmas"), .fourWeeks) == "Christmas is in 4 weeks")
    #expect(words(.ownBirthday, .oneWeek) == "Your birthday is in 1 week")
    #expect(words(.ownCustom(occasion: "recital"), .fourWeeks) == "Your recital is in 4 weeks")
  }
}
