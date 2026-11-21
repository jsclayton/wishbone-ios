import Foundation

/// The app's page in the App Store, which Update Wishbone opens.
enum AppStorePage {
  /// From the build's `WISHBONE_APP_STORE_URL`. A build without one, before the app has its page, opens a search
  /// of the App Store for the app.
  static let url: URL? = {
    if let text = Bundle.main.object(forInfoDictionaryKey: "WishboneAppStoreURL") as? String, !text.isEmpty,
      let url = URL(string: text)
    {
      return url
    }
    return URL(string: "https://apps.apple.com/search?term=Wishbone")
  }()
}
