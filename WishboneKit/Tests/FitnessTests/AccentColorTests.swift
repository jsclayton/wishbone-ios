import Foundation
import Testing

@Suite("One accent color", .timeLimit(.minutes(1)))
struct AccentColorTests {
  @Test("The three AccentColor assets are equal")
  func equal() throws {
    let colors = try Repo.targets.map { target in
      let file = Repo.url("\(target)/Assets.xcassets/AccentColor.colorset/Contents.json")
      return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
    }
    #expect(colors.count == 3)
    let first = try #require(colors[0])
    #expect(colors.allSatisfy { $0 == first })
  }
}
