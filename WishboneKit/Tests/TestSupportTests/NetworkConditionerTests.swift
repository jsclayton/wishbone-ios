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
    #expect(try await admin.all("/groups?limit=2").contains { $0["id"].string == id })

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
    let groups = try await server.admin().all("/groups")
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
    let before = try await server.admin().all("/groups")
    #expect(!before.contains { $0["name"].string == name })

    hold.release()
    #expect(try await answer.status == 201)
    let after = try await server.admin().all("/groups")
    #expect(after.contains { $0["name"].string == name })
  }

  @Test(
    "A request that a drop cut off never reaches the server, however its hold ends",
    arguments: [HoldEnd.release, .passEverything]
  )
  func cutOffRequestNeverArrives(end: HoldEnd) async throws {
    let hold = conditioner.hold(Route("POST", "/groups"), at: .request)
    let name = "Cut off \(UUID().uuidString.prefix(8))"
    async let answer = admin.send("POST", "/groups", json: ["name": .string(name)])
    await hold.waitUntilHeld()

    // The network goes while the request is on its way. The client sees it fail.
    conditioner.dropEverything()
    do {
      let answer = try await answer
      Issue.record("The request that was cut off got an answer: \(answer.status)")
    } catch {
      #expect(error is URLError)
    }

    // The network comes back.
    if end == .release { hold.release() }
    conditioner.passEverything()
    // A later write goes to the server and back, and the one that was cut off still hasn't arrived.
    let later = "Later \(UUID().uuidString.prefix(8))"
    #expect(try await admin.send("POST", "/groups", json: ["name": .string(later)]).status == 201)
    let names = try await server.admin().all("/groups").compactMap { $0["name"].string }
    #expect(names.contains(later))
    #expect(!names.contains(name))
  }

  enum HoldEnd: Sendable {
    case release
    case passEverything
  }

  @Test("A wait for more than one held request returns when the hold has held them all")
  func waitsForEveryHeldRequest() async throws {
    let hold = conditioner.hold(Route("GET", "/health"), at: .request)
    let heldThree = Mutex(false)
    let waiting = Task {
      await hold.waitUntilHeld(3)
      heldThree.withLock { $0 = true }
    }
    async let first = TestHTTP.send("GET", conditioner.url("/health"))
    async let second = TestHTTP.send("GET", conditioner.url("/health"))
    await hold.waitUntilHeld(2)
    // A wait for three that returned at two would set the flag about now, so the test gives it a moment.
    try await Task.sleep(for: .milliseconds(200))
    #expect(!heldThree.withLock { $0 })
    async let third = TestHTTP.send("GET", conditioner.url("/health"))
    await waiting.value
    #expect(heldThree.withLock { $0 })
    #expect(conditioner.requests.count == 3)
    hold.release()
    #expect(try await [first.status, second.status, third.status] == [200, 200, 200])
  }

  @Test("A released hold is over: it holds nothing more, and an older canned answer for its route shows again")
  func releasedHoldIsOver() async throws {
    conditioner.answer(Route("GET", "/health"), with: .init(status: 503))
    let hold = conditioner.hold(Route("GET", "/health"))
    async let held = TestHTTP.send("GET", conditioner.url("/health"))
    await hold.waitUntilHeld()
    hold.release()
    #expect(try await held.status == 200)

    #expect(try await TestHTTP.send("GET", conditioner.url("/health")).status == 503)
  }

  @Test("A wait for a request that never comes ends when its task is cancelled")
  func waitEndsWhenCancelled() async throws {
    let hold = conditioner.hold(Route("GET", "/health"))
    let waiting = Task { await hold.waitUntilHeld() }
    // The time limit of a test cancels the test's task, as this does.
    waiting.cancel()
    await waiting.value

    // The hold still holds: a request that comes later is held, and a wait for it returns.
    async let held = TestHTTP.send("GET", conditioner.url("/health"))
    await hold.waitUntilHeld()
    hold.release()
    #expect(try await held.status == 200)
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

  @Test("It loses the connection of the next requests on a route, which never reach the server, and then passes")
  func losesConnections() async throws {
    conditioner.loseConnection(Route("POST", "/groups"), count: 2)
    let name = "Lost \(UUID().uuidString.prefix(8))"
    for _ in 0..<2 {
      await #expect(throws: URLError.self) { try await admin.send("POST", "/groups", json: ["name": .string(name)]) }
    }
    // A request on another route passes.
    #expect(try await TestHTTP.send("GET", conditioner.url("/health")).status == 200)
    let groups = try await server.admin().all("/groups?limit=200")
    #expect(!groups.contains { $0["name"].string == name })

    let made = try await admin.send("POST", "/groups", json: ["name": .string(name)]).expecting(201)
    #expect(try made.json["name"].string == name)
    #expect(conditioner.requests.filter { $0.isOn(Route("POST", "/groups")) }.count == 3)
  }

  /// A test's `Instance` stops its conditioner when the test ends, and the session can still have requests on their
  /// way then. A forward that had made its session, and not yet its task, when a stop invalidated that session
  /// raised `Task created in a session that has been invalidated`, which aborts the test process. Seen on CI on
  /// 2026-11-23 (run 45131695827 attempt 1). The released requests race the stop, so each round puts some of them
  /// in a forward as the stop comes. Before the fix, the abort came in a round that differed from run to run (1, 5,
  /// 70, 99 and 116 in five of eight runs), so the test needs every round.
  ///
  /// The rounds wait only on the conditioner and the server. A round sends its requests on sessions of its own, not
  /// through `TestHTTP`, whose few slots every test in the process shares: the round held 8 of them until all 8
  /// arrived, so it waited on the other tests' requests, and they on its. A request goes to the round's own new
  /// listener, so the listen queue that the slots guard is not in its way.
  ///
  /// Each wait of a round has a limit of its own. A round that runs out of it fails by its number, with what each
  /// request got, and stops its conditioner. The test ran out of its minute on 2026-11-24 and 2026-11-25, and the
  /// limits found why: the round's conditioner had a port that another process listened on at `127.0.0.1`, so all
  /// 8 requests got that process's 404, and none reached the hold. The conditioner now listens at `127.0.0.1`
  /// exactly, where no other socket takes its connections.
  @Test("A stop while requests are on their way to the server ends them, and the test process goes on")
  func stopDuringForwards() async throws {
    let requests = 8
    let limit = Duration.seconds(10)
    for round in 0..<120 {
      let conditioner = try await NetworkConditioner(to: server.address)
      // A round that ends early, at its limit or at the test's, stops its conditioner, which releases the hold.
      defer { conditioner.stop() }
      let hold = conditioner.hold(Route("GET", "/health"), at: .request)
      let url = conditioner.url("/health")
      let ends = Ends(requests)
      let sent = (0..<requests).map { number in
        Task { await ends.record(number) { try await Self.status(of: url) } }
      }
      defer { sent.forEach { $0.cancel() } }
      let isHeld = await Self.ends(within: limit) { await hold.waitUntilHeld(requests) }
      // A wait that the test's time limit cancelled returns at once, so the round ends then too.
      try Task.checkCancellation()
      guard isHeld else {
        let got = conditioner.requests.count
        Issue.record("Round \(round): the conditioner got \(got) of the \(requests) requests in \(limit). \(ends)")
        return
      }
      hold.release()
      // The stop comes a little later in each round, so in some round it finds the forwards at each of their steps.
      for _ in 0..<round { await Task.yield() }
      conditioner.stop()
      let haveEnded = await Self.ends(within: limit) {
        await withTaskCancellationHandler {
          for request in sent { await request.value }
        } onCancel: {
          sent.forEach { $0.cancel() }
        }
      }
      try Task.checkCancellation()
      guard haveEnded else {
        Issue.record("Round \(round): the requests didn't all end in \(limit) after the stop. \(ends)")
        return
      }
      // Each ended: with the server's answer when its forward came before the stop, and with no answer after.
      for status in ends.statuses { #expect(status == 200, "Round \(round). \(ends)") }
    }
  }

  /// How each request of a round ended, by its number.
  private final class Ends: Sendable, CustomStringConvertible {
    private let count: Int
    private let results = Mutex<[Int: Result<Int, any Error>]>([:])

    init(_ count: Int) {
      self.count = count
    }

    /// Sends a request, and keeps how it ended.
    func record(_ number: Int, _ request: () async throws -> Int) async {
      let result: Result<Int, any Error>
      do {
        result = .success(try await request())
      } catch {
        result = .failure(error)
      }
      results.withLock { $0[number] = result }
    }

    /// The statuses of the requests that got an answer.
    var statuses: [Int] {
      results.withLock { $0.values.compactMap { try? $0.get() } }
    }

    var description: String {
      let results = results.withLock { $0 }
      let ends = (0..<count).map { number in
        switch results[number] {
        case .success(let status): "\(number + 1): \(status)"
        case .failure(let error as URLError): "\(number + 1): URLError \(error.code.rawValue)"
        case .failure(let error): "\(number + 1): \(error)"
        case nil: "\(number + 1): on its way"
        }
      }
      return "The requests: \(ends.joined(separator: ", "))."
    }
  }

  /// Whether `work` ends within `limit`. When it doesn't, the call cancels it, and returns when it has ended.
  private static func ends(within limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await work()
        return true
      }
      group.addTask {
        try? await Task.sleep(for: limit)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }

  /// The status of a GET, on a session of its own. A session opens at most 6 connections to a host at once, so
  /// requests that share one would wait for each other, and the 7th would never reach the hold.
  private static func status(of url: URL) async throws -> Int {
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.setValue("close", forHTTPHeaderField: "Connection")
    let (_, response) = try await session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
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
