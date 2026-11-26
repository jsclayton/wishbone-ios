import Foundation

/// A model on this machine, for a server that guesses at photos: an OpenAI-compatible Chat Completions endpoint
/// that gives one guess to every photo. A test server started with `environment` sends each photo of a search
/// there. With no model, a server finds nothing in a photo.
///
/// It is a network conditioner that answers every request itself, so the address behind it is never asked. It stops
/// when its last holder goes.
public final class PhotoModel: Sendable {
  /// The title that the model guesses.
  public let title: String

  private let conditioner: NetworkConditioner
  private static let completions = NetworkConditioner.Route("POST", "/model/chat/completions")

  /// A model that names every photo `title`, with no price.
  public init(title: String) async throws {
    let server = try await TestServer.shared()
    conditioner = try await NetworkConditioner(to: server.address)
    self.title = title
    // The reply is the JSON that the server's prompt asks for, as the message's text.
    let guess = try JSONSerialization.data(withJSONObject: ["title": title, "price": "", "currency": ""])
    let reply: JSON = [
      "choices": [["message": ["role": "assistant", "content": .string(String(decoding: guess, as: UTF8.self))]]],
      "usage": ["prompt_tokens": 50, "completion_tokens": 8],
    ]
    conditioner.answer(Self.completions, with: try .json(200, reply))
  }

  /// The server's settings that send its photo guesses to this model.
  public var environment: [String: String] {
    [
      "WISHBONE_LLM_PROVIDER": "openai",
      "WISHBONE_LLM_BASE_URL": conditioner.url("/model").absoluteString,
      "WISHBONE_LLM_MODEL": "test-model",
    ]
  }

  /// How many photos the model was asked about.
  public var guesses: Int {
    conditioner.requests.filter { $0.isOn(Self.completions) }.count
  }
}
