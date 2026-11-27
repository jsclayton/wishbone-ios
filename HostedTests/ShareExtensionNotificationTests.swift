import Foundation
import Testing
import WishboneAPI
import WishboneSession

/// The word from the share extension: a Darwin notification after an add, which the app hears and syncs at once.
/// See "When the app syncs" in `docs/spec.md`.
@Suite("The share extension's notification", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ShareExtensionNotificationTests {
  @Test("In the app, the notification starts one sync")
  func notificationStartsOneSync() async throws {
    let instance = try await StandInInstance.start()
    // A name of the test's own, so that no other test's notification reaches it.
    let notification = ItemAddedNotification(appGroup: "group.test.\(UUID().uuidString)")
    let device = try signedInDevice(on: instance, addsFromShareExtension: notification)
    let session = try #require(device.session)
    await session.syncNow()
    #expect(instance.pullCount == 1)

    // The extension posts it, as after an add.
    notification.itemAdded()

    await until { instance.pullCount == 2 }
    // One sync, and no more after it.
    await session.syncNow()
    #expect(instance.pullCount == 3)
  }
}
