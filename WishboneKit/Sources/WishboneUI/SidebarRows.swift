import SwiftUI

// The rows of the sidebar's shortcuts: a heading, and a row that opens a page. They sit under the tabs, in the
// sidebar's footer.
//
// On iOS they are the system's own views, not SwiftUI's text: a label, and the content of a sidebar's cell. The
// accessibility audit reports any SwiftUI text in a sidebar's footer as text that can't change its size, and it
// passes the system's views there. The system's cell content also gives a row the look and the sizes of the rows
// above it. The package also builds on macOS, for its tests, so each row has a plain SwiftUI form there.

/// The heading of a part of the sidebar's shortcuts, such as "Your lists".
struct SidebarHeading: View {
  let words: String

  var body: some View {
    #if os(iOS)
      SystemHeading(words: words)
    #else
      Text(words)
        .accessibilityAddTraits(.isHeader)
    #endif
  }
}

/// A shortcut's row in the sidebar. It reads its name: the name of its list, or of its page.
struct SidebarShortcut: View {
  let name: String
  let systemImage: String
  let open: () -> Void

  var body: some View {
    #if os(iOS)
      SystemShortcut(name: name, systemImage: systemImage, open: open)
    #else
      Button(action: open) {
        Label {
          Text(name)
        } icon: {
          Image(systemName: systemImage)
        }
      }
    #endif
  }
}

#if os(iOS)
  private struct SystemHeading: UIViewRepresentable {
    let words: String

    func makeUIView(context: Context) -> UILabel {
      let label = UILabel()
      let style = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .subheadline)
      label.font = UIFont(descriptor: style.withSymbolicTraits(.traitBold) ?? style, size: 0)
      label.adjustsFontForContentSizeCategory = true
      label.numberOfLines = 0
      label.accessibilityTraits = .header
      return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
      label.text = words
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
      SidebarRow.size(of: label, in: proposal)
    }
  }

  private struct SystemShortcut: UIViewRepresentable {
    let name: String
    let systemImage: String
    let open: () -> Void

    func makeUIView(context: Context) -> ShortcutControl {
      ShortcutControl()
    }

    func updateUIView(_ control: ShortcutControl, context: Context) {
      control.open = open
      control.show(name: name, systemImage: systemImage)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView control: ShortcutControl, context: Context) -> CGSize? {
      SidebarRow.size(of: control, in: proposal)
    }
  }

  /// A control with the content of a sidebar's cell, as the system lays it out: the symbol, then the name, on as
  /// many lines as the name needs.
  private final class ShortcutControl: UIControl {
    var open: () -> Void = {}

    private let content = UIListContentView(configuration: .cell())

    init() {
      super.init(frame: .zero)
      // The content is a cell's, as a sidebar shows it.
      traitOverrides.listEnvironment = .sidebar
      // The control is the one element: a button with the row's name.
      content.isUserInteractionEnabled = false
      content.translatesAutoresizingMaskIntoConstraints = false
      addSubview(content)
      NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: topAnchor),
        content.bottomAnchor.constraint(equalTo: bottomAnchor),
        content.leadingAnchor.constraint(equalTo: leadingAnchor),
        content.trailingAnchor.constraint(equalTo: trailingAnchor),
      ])
      isAccessibilityElement = true
      accessibilityTraits = .button
      addAction(UIAction { [weak self] _ in self?.open() }, for: .touchUpInside)
      // With a pointer, the row has the system's hover effect.
      addInteraction(UIPointerInteraction())
    }

    /// A shortcut's row is made in code, never from a file.
    required init?(coder: NSCoder) {
      nil
    }

    func show(name: String, systemImage: String) {
      var configuration = UIListContentConfiguration.cell()
      configuration.text = name
      configuration.image = UIImage(systemName: systemImage)
      // The sidebar's footer has the margins at the sides already.
      configuration.axesPreservingSuperviewLayoutMargins = []
      configuration.directionalLayoutMargins.leading = 0
      configuration.directionalLayoutMargins.trailing = 0
      content.configuration = configuration
      accessibilityLabel = name
    }

    /// VoiceOver's double tap opens the row, as a tap does.
    override func accessibilityActivate() -> Bool {
      open()
      return true
    }

    /// The row dims while a finger is on it.
    override var isHighlighted: Bool {
      didSet { content.alpha = isHighlighted ? 0.5 : 1 }
    }
  }

  private enum SidebarRow {
    /// The size of a row: as wide as the sidebar gives it, as high as its words need at that width, and never
    /// lower than a tap target.
    static func size(of view: UIView, in proposal: ProposedViewSize) -> CGSize {
      let width = proposal.width ?? view.intrinsicContentSize.width
      let fitting = view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      )
      return CGSize(width: width, height: max(44, fitting.height))
    }
  }
#endif
