import Foundation
import Testing
import WishboneAPI
import WishboneSession
import WishboneUI

/// The app's words for each error code of the API: the one lookup that every screen uses. See "Words for error
/// codes" in `docs/screens/README.md`.
@Suite("The words for error codes", .timeLimit(.minutes(1)))
@MainActor
struct ErrorWordsTests {
  private func words(_ code: String, status: Int = 422, detail: String = "The server's own words.") -> String? {
    ErrorWords.words(for: APIError.Refusal(route: .updateMe, status: status, code: ErrorCode(code), detail: detail))
  }

  @Test("A code in the table gives the app's words, one that is not gives the server's detail, and success none")
  func lookup() {
    // Each code in the table so far.
    let table: [String: String] = [
      "rate_limited": "Too many tries. Wait a minute, then try again.",
      "invalid_input": "Some fields need another look.",
      "not_found": "This is gone, or it isn't shared with you.",
      "reference_not_found": "This is gone, or it isn't shared with you.",
      "forbidden": "You can't do this any more.",
      "field_not_writable": "You can't do this any more.",
      "request_too_large": "That photo is too large. Choose a smaller one.",
      "image_too_large": "That photo is too large. Choose a smaller one.",
      "image_invalid": "Wishbone can't use that file. Choose a JPEG, PNG, GIF, or WebP photo.",
      "birthday_required": "A birthday is required.",
      "admin_has_no_parents": "The admin can't have parents.",
      "primary_list": "You can't do this to a primary list.",
      "login_link_invalid": "That link was already used, or it has expired. Ask for a new one.",
      "item_fully_claimed": "Someone else just got this.",
      "recipient_cannot_claim": "You can't claim on a list that is for you.",
      "quantity_raise_not_allowed": "You can only lower how many, because this list is now for you too.",
      "occasion_not_allowed": "That occasion can't be used for this gift. Pick another.",
      "occasion_locked": "The occasion for this gift can't be changed.",
      "gift_given": "This gift was already given.",
    ]
    for (code, expected) in table {
      #expect(words(code) == expected, "\(code)")
    }

    // A code that is not in the table, and one that the table gives to the server.
    #expect(words("a_code_from_a_later_server", detail: "Something new happened.") == "Something new happened.")
    #expect(words("parent_loop", detail: "Robin can't be their own parent.") == "Robin can't be their own parent.")

    // A photo that the device itself can't read gets the words of `image_invalid`, with nothing sent.
    #expect(ErrorWords.notAnImage == words("image_invalid"))

    // The codes whose words name a list or a person: the screen that meets them gives the name.
    #expect(
      ErrorWords.lastRecipient(of: "Our house")
        == "You're the only recipient of Our house, so you can't leave it. You can delete it.")
    #expect(
      ErrorWords.deactivated("Sam")
        == "Only the admin can reactivate Sam. Until then, you can't change anything for Sam.")

    // The codes that count as success show nothing.
    for code in [
      "already_claimed", "already_invited", "already_recipient", "already_in_group", "already_attached",
      "already_blocked",
    ] {
      #expect(words(code, status: 409) == nil, "\(code)")
    }

    // The codes that only a fault in the app can cause.
    for code in ["unknown_filter", "unknown_sort", "cursor_mismatch", "image_attached", "resource_changed"] {
      #expect(words(code, status: 400) == "Something went wrong in Wishbone. Try again.", "\(code)")
    }
  }

  @Test("A claim's line names the occasion, or the reveal date, and a claim that made no gift says why, never who")
  func claimWords() throws {
    let christmas = ItemPage.ClaimLine(id: "1", quantity: 1, occasion: .named("Christmas"))
    #expect(ClaimWords.line(christmas) == "You claimed 1 for Christmas")
    let march = try #require(Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 4, hour: 12)))
    let hidden = ItemPage.ClaimLine(id: "2", quantity: 1, occasion: .hiddenUntil(march))
    #expect(ClaimWords.line(hidden) == "You claimed 1 · hidden until Mar 4")

    let address = try #require(InstanceAddress("https://wishbone.example"))
    #expect(ClaimWords.result(of: .claimed, address: address, recipients: []) == nil)
    #expect(
      ClaimWords.result(of: .someoneElseGotIt, address: address, recipients: []) == "Someone else just got this.")
    #expect(
      ClaimWords.result(of: .unreachable, address: address, recipients: [])
        == "Can't reach \(address.text). Nothing was claimed.")
    let refusal = APIError.Refusal(
      route: .claim, status: 403, code: ErrorCode("recipient_cannot_claim"), detail: "The server's own words.")
    #expect(
      ClaimWords.result(of: .refused(refusal), address: address, recipients: [])
        == "You can't claim on a list that is for you.")
  }
}
