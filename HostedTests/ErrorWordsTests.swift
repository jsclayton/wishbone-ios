import Testing
import WishboneAPI
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
      "login_link_invalid": "That link was already used, or it has expired. Ask for a new one.",
    ]
    for (code, expected) in table {
      #expect(words(code) == expected, "\(code)")
    }

    // A code that is not in the table, and one that the table gives to the server.
    #expect(words("a_code_from_a_later_server", detail: "Something new happened.") == "Something new happened.")
    #expect(words("parent_loop", detail: "Robin can't be their own parent.") == "Robin can't be their own parent.")

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
}
