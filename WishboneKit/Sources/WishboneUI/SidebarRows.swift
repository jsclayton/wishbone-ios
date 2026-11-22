import SwiftUI

// The rows of the sidebar's shortcuts: a heading, and a row that opens a page. They sit under the tabs, in the
// sidebar's footer.
//
// On iOS they are the system's own views, not SwiftUI's text: a label, and the content of a sidebar's cell. The
// accessibility audit reports any SwiftUI text in a sidebar's footer as text that can't change its size, and it
// passes the system's views there. The system's cell content also gives a row the look and the sizes of the rows
// above it. The package also builds on macOS, for its tests, so each row has a plain SwiftUI form there.

/// The heading of a part of the sidebar's shortcuts, such as "Your lists", or a group's name. `detail` is a line
/// under it, such as "through {group}".
struct SidebarHeading: View {
  let words: String
  var detail: String?

  var body: some View {
    #if os(iOS)
      SystemHeading(words: words, detail: detail)
    #else
      VStack(alignment: .leading) {
        Text(words)
        if let detail { Text(detail) }
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
    #endif
  }
}

/// A shortcut's row in the sidebar. It reads its name: the name of its list, of its user, or of its page. `detail`
/// is a line under the name, such as "Deactivated", which VoiceOver reads after it.
struct SidebarShortcut: View {
  let name: String
  let systemImage: String
  var detail: String?
  let open: () -> Void

  var body: some View {
    #if os(iOS)
      SystemShortcut(name: name, systemImage: systemImage, detail: detail, open: open)
    #else
      Button(action: open) {
        Label {
          Text(name)
          if let detail { Text(detail) }
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
    let detail: String?

    func makeUIView(context: Context) -> HeadingView {
      HeadingView()
    }

    func updateUIView(_ heading: HeadingView, context: Context) {
      heading.show(words: words, detail: detail)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView heading: HeadingView, context: Context) -> CGSize? {
      SidebarRow.size(of: heading, in: proposal)
    }
  }

  /// A heading, and the line under it when it has one. It is one element: a header, with both lines' words.
  private final class HeadingView: UIView {
    private let label = UILabel()
    private let detailLabel = UILabel()

    init() {
      super.init(frame: .zero)
      let style = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .subheadline)
      label.font = UIFont(descriptor: style.withSymbolicTraits(.traitBold) ?? style, size: 0)
      detailLabel.font = .preferredFont(forTextStyle: .footnote)
      detailLabel.textColor = .secondaryLabel
      let stack = UIStackView(arrangedSubviews: [label, detailLabel])
      stack.axis = .vertical
      stack.alignment = .leading
      stack.translatesAutoresizingMaskIntoConstraints = false
      for line in [label, detailLabel] {
        line.adjustsFontForContentSizeCategory = true
        line.numberOfLines = 0
      }
      addSubview(stack)
      NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: topAnchor),
        stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        stack.leadingAnchor.constraint(equalTo: leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      ])
      isAccessibilityElement = true
      accessibilityTraits = .header
    }

    /// A heading is made in code, never from a file.
    required init?(coder: NSCoder) {
      nil
    }

    func show(words: String, detail: String?) {
      label.text = words
      detailLabel.text = detail
      detailLabel.isHidden = detail == nil
      accessibilityLabel = words
      accessibilityValue = detail
    }
  }

  private struct SystemShortcut: UIViewRepresentable {
    let name: String
    let systemImage: String
    let detail: String?
    let open: () -> Void

    func makeUIView(context: Context) -> ShortcutControl {
      ShortcutControl()
    }

    func updateUIView(_ control: ShortcutControl, context: Context) {
      control.open = open
      control.show(name: name, systemImage: systemImage, detail: detail)
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

    func show(name: String, systemImage: String, detail: String?) {
      var configuration = detail == nil ? UIListContentConfiguration.cell() : .subtitleCell()
      configuration.text = name
      configuration.secondaryText = detail
      configuration.image = UIImage(systemName: systemImage)
      // The sidebar's footer has the margins at the sides already.
      configuration.axesPreservingSuperviewLayoutMargins = []
      configuration.directionalLayoutMargins.leading = 0
      configuration.directionalLayoutMargins.trailing = 0
      content.configuration = configuration
      accessibilityLabel = name
      accessibilityValue = detail
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
