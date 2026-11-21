import Foundation
import Synchronization
import TestSupport
import Testing

@Suite("The network conditioner", .timeLimit(.minutes(1)))
struct NetworkConditionerTests {
  typealias Route = NetworkConditioner.Route

  let server: TestServer
  let conditioner: NetworkConditioner
  let admin: BearerSession

  init() async throws {
    server = try await TestServer.shared()
    conditioner = try await NetworkConditioner(to: server.address)
    // The admin's session, with the conditioner's address as its instance address.
    let session = try await server.admin()
    admin = BearerSession(instance: conditioner.address, token: session.token, userID: session.userID)
  }

  @Test("It passes a request through to the real server, and the answer back")
  func passesThrough() async throws {
    let direct = try await TestHTTP.send("GET", server.url("/health")).expecting(200)
    let through = try await TestHTTP.send("GET", conditioner.url("/health")).expecting(200)
    #expect(try through.json["version"] == direct.json["version"])
    #expect(through.headers["content-type"] == direct.headers["content-type"])

    // A write with a body and a bearer token, and then a read with a query.
    let name = "Through \(UUID().uuidString.prefix(8))"
    let made = try await admin.send("POST", "/groups", json: ["name": .string(name)]).expecting(201)
    let id = try #require(try made.json["id"].string)
    #expect(made.headers["location"] == "/api/v2/groups/\(id)")
    #expect(try await server.admin().get("/groups/\(id)")["name"].string == name)
    #expect(try await admin.get("/groups?limit=200")["data"].array?.contains { $0["id"].string == id } == true)

    // The server's own errors pass through too.
    let missing = try await admin.send("GET", "/groups/0")
    #expect(missing.status == 404)
    #expect(try missing.json["code"] == "not_found")
    #expect(try await TestHTTP.send("GET", conditioner.url("/users/me")).status == 401)
  }

  @Test("It drops everything, and passes everything again")
  func dropsEverything() async throws {
    conditioner.dropEverything()
    await #expect(throws: URLError.self) { try await TestHTTP.send("GET", conditioner.url("/health")) }
    await #expect(throws: URLError.self) { try await admin.send("POST", "/groups", json: ["name": "Never made"]) }

    conditioner.passEverything()
    #expect(try await TestHTTP.send("GET", conditioner.url("/health")).status == 200)
  }

  @Test("It holds an answer until the test releases it, with the change already made")
  func holdsAnAnswer() async throws {
    let hold = conditioner.hold(Route("POST", "/groups"))
    let name = "Held \(UUID().uuidString.prefix(8))"
    let hasAnswered = Mutex(false)
    async let answer = {
      let answer = try await admin.send("POST", "/groups", json: ["name": .string(name)])
      hasAnswered.withLock { $0 = true }
      return answer
    }()

    await hold.waitUntilHeld()
    // The answer is in flight, and the server has made the group: a read that races it sees the group.
    let groups = try await server.admin().get("/groups?limit=200")["data"].array ?? []
    #expect(groups.contains { $0["name"].string == name })
    // A request on another route is not held. It goes through the conditioner and back while the answer waits.
    #expect(try await TestHTTP.send("GET", conditioner.url("/health")).status == 200)
    #expect(!hasAnswered.withLock { $0 })

    hold.release()
    #expect(try await answer.status == 201)
    #expect(hasAnswered.withLock { $0 })
  }

  @Test("It holds a request until the test releases it, before it reaches the server")
  func holdsARequest() async throws {
    let hold = conditioner.hold(Route("POST", "/groups"), at: .request)
    let name = "Late \(UUID().uuidString.prefix(8))"
    async let answer = admin.send("POST", "/groups", json: ["name": .string(name)])

    await hold.waitUntilHeld()
    // Other requests go through the conditioner and back, and the held one is still not at the server.
    #expect(try await TestHTTP.send("GET", conditioner.url("/health")).status == 200)
    let before = try await server.admin().get("/groups?limit=200")["data"].array ?? []
    #expect(!before.contains { $0["name"].string == name })

    hold.release()
    #expect(try await answer.status == 201)
    let after = try await server.admin().get("/groups?limit=200")["data"].array ?? []
    #expect(after.contains { $0["name"].string == name })
  }

  @Test("It answers a route with a canned response, and the request never reaches the server")
  func answersARoute() async throws {
    conditioner.answer(
      Route("GET", "/health"), with: try .json(200, ["status": "ok", "version": "1.0.0", "commit": "old"]))
    conditioner.answer(Route("DELETE", "/groups/{id}"), with: try .problem(410, code: "api_version_removed"))
    conditioner.answer(Route("GET", "/users/me"), with: .init(status: 503))

    #expect(try await TestHTTP.send("GET", conditioner.url("/health")).json["version"] == "1.0.0")
    #expect(try await admin.send("GET", "/users/me").status == 503)

    let group = try await server.admin().post("/groups", ["name": .string("Kept \(UUID().uuidString.prefix(8))")])
    let id = try #require(group["id"].string)
    let removed = try await admin.send("DELETE", "/groups/\(id)")
    #expect(removed.status == 410)
    #expect(removed.headers["content-type"] == "application/problem+json")
    #expect(try removed.json["code"] == "api_version_removed")
    // The server never got the delete.
    #expect(try await server.admin().status(of: "/groups/\(id)") == 200)

    // A route that has no canned answer still passes through, and so does every route after a reset.
    #expect(try await admin.get("/groups/\(id)")["id"].string == id)
    conditioner.passEverything()
    #expect(try await TestHTTP.send("GET", conditioner.url("/health")).json["version"] != "1.0.0")
  }

  @Test("A route matches its method, and its path under /api/v2 with any ID")
  func routes() {
    let route = Route("post", "/items/{id}/gifts")
    #expect(route.matches(method: "POST", target: "/api/v2/items/12/gifts"))
    #expect(route.matches(method: "POST", target: "/api/v2/items/12/gifts?sort=name"))
    #expect(!route.matches(method: "GET", target: "/api/v2/items/12/gifts"))
    #expect(!route.matches(method: "POST", target: "/api/v2/items/12"))
    #expect(!route.matches(method: "POST", target: "/api/v2/items/12/gifts/3"))
    #expect(!route.matches(method: "POST", target: "/items/12/gifts"))
  }
}
