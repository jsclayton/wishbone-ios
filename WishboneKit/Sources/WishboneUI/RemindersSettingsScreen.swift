import SwiftUI
import WishboneSession

#if canImport(UIKit)
  import UIKit
#endif

/// The Reminders screen: the one switch, how early, the one on the day, and Show on Lock Screen. Pushed from
/// Settings. See `docs/screens/reminders-settings.md`, and "One switch, and the timing" and "Turning them on" in
/// `docs/spec.md`.
///
/// Each change rebuilds the whole set. The reminders are made from the local copy, so the screen works with no
/// connection.
///
/// **Provisional.** Plain default: a system form.
struct RemindersSettingsScreen: View {
  let session: SessionModel

  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Form {
      Section {
        Toggle(isOn: setting(\.isOn)) {
          Text("Reminders", bundle: #bundle)
        }
        if settings.isOn {
          MenuRow(label: Text("Remind me early", bundle: #bundle), value: Text(Self.words(of: settings.early))) {
            Picker(selection: setting(\.early)) {
              ForEach(EarlyReminder.allCases, id: \.self) { early in
                Text(Self.words(of: early)).tag(early)
              }
            } label: {
              Text("Remind me early", bundle: #bundle)
            }
          }
          Toggle(isOn: setting(\.onTheDay)) {
            Text("On the day", bundle: #bundle)
          }
        }
      } footer: {
        if settings.isOn {
          // Read after the switches. The primary color: the system's secondary gray of a footer is below 4.5:1.
          Text("Reminders arrive at 9:00 in the morning.", bundle: #bundle)
            .foregroundStyle(Color.primary)
        }
      }
      .disabled(isOff)

      permission

      Section {
      } footer: {
        Text(
          "A reminder names the occasion and the person. It never says anything about gifts.", bundle: #bundle
        )
        .foregroundStyle(Color.primary)
      }
    }
    .navigationTitle(Text("Reminders", bundle: #bundle))
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await session.readReminderAuthorization() }
    .onChange(of: scenePhase) { _, phase in
      // The user can change notifications in iOS Settings while the app is away.
      if phase == .active { Task { await session.readReminderAuthorization() } }
    }
  }

  private var settings: ReminderSettings {
    session.reminderSettings
  }

  /// Whether notifications are off for the app in iOS. The switches are disabled, and the app never asks again.
  private var isOff: Bool {
    session.reminderAuthorization == .denied
  }

  /// What iOS lets the app do: Show on Lock Screen while it is provisional, a line once it is full, and a line with
  /// Open Settings while notifications are off. Nothing before the app has asked.
  @ViewBuilder private var permission: some View {
    switch session.reminderAuthorization {
    case .provisional:
      Section {
        Button {
          Task { await session.showRemindersOnLockScreen() }
        } label: {
          Text("Show on Lock Screen", bundle: #bundle)
        }
      } footer: {
        Text("Reminders arrive quietly in Notification Center.", bundle: #bundle)
          .foregroundStyle(Color.primary)
      }
    case .authorized:
      Section {
        Text("Reminders show on the Lock Screen.", bundle: #bundle)
      }
    case .denied:
      Section {
        Text(
          "Notifications are off for Wishbone. Turn them on in Settings to get reminders.", bundle: #bundle)
        Button {
          if let url = Self.notificationSettings { openURL(url) }
        } label: {
          Text("Open Settings", bundle: #bundle)
        }
      }
    case .notDetermined, nil:
      EmptyView()
    }
  }

  /// A binding to one of the settings. A change rebuilds the set.
  private func setting<Value>(_ keyPath: WritableKeyPath<ReminderSettings, Value>) -> Binding<Value> {
    Binding {
      session.reminderSettings[keyPath: keyPath]
    } set: { value in
      var settings = session.reminderSettings
      settings[keyPath: keyPath] = value
      session.changeReminderSettings(settings)
    }
  }

  /// The app's page of notifications in iOS Settings.
  private static var notificationSettings: URL? {
    #if os(iOS)
      URL(string: UIApplication.openNotificationSettingsURLString)
    #else
      nil
    #endif
  }

  /// The words of a choice of Remind me early.
  static func words(of early: EarlyReminder) -> String {
    switch early {
    case .oneWeek: String(localized: "1 week", bundle: #bundle)
    case .twoWeeks: String(localized: "2 weeks", bundle: #bundle)
    case .fourWeeks: String(localized: "4 weeks", bundle: #bundle)
    }
  }
}
