import SwiftUI

/// A form's row that picks one choice: a system menu with a system picker in it, as the birthday rows of the profile
/// gate and Remind me early have. Its label and its value are words that the app draws in the primary color,
/// because a form draws a picker's value in the system's secondary gray, which is below 4.5:1. The value sits beside
/// the label, and under it at the largest text sizes. VoiceOver reads the row as one button, with its label and its
/// value: "Remind me early, 2 weeks".
struct MenuRow<Options: View>: View {
  let label: Text
  let value: Text
  @ViewBuilder let options: Options

  @Environment(\.dynamicTypeSize) private var size

  var body: some View {
    Menu {
      options
        .pickerStyle(.inline)
    } label: {
      Group {
        if size.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 4) {
            label
            selected
          }
        } else {
          HStack {
            label
            Spacer()
            selected
          }
        }
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .foregroundStyle(.primary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(value)
    .accessibilityAddTraits(.isButton)
  }

  private var selected: some View {
    HStack(spacing: 4) {
      value
      Image(systemName: "chevron.up.chevron.down")
        .imageScale(.small)
        .accessibilityHidden(true)
    }
  }
}
