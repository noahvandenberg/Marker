import AppKit

/// A slim strip across the top of the document, shown when a newer release
/// exists on GitHub.
///
/// Deliberately unobtrusive: one line, dismissible, and it never steals focus
/// or blocks the text underneath.
final class UpdateBar: NSView {

    private let label = NSTextField(labelWithString: "")
    private let viewButton = NSButton()
    private let dismissButton = NSButton()
    private let separator = NSBox()

    var onView: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let material = NSVisualEffectView()
        material.material = .headerView
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        viewButton.title = "View Release"
        viewButton.bezelStyle = .accessoryBarAction
        viewButton.controlSize = .small
        viewButton.target = self
        viewButton.action = #selector(viewTapped)
        viewButton.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.image = NSImage(systemSymbolName: "xmark",
                                      accessibilityDescription: "Dismiss")
        dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(viewButton)
        addSubview(dismissButton)
        addSubview(separator)

        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            viewButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor,
                                                constant: 12),
            viewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            viewButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor,
                                                 constant: -10),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 16),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    func present(_ update: AvailableUpdate) {
        label.stringValue = "Marker \(update.version) is available."
        toolTip = update.url.absoluteString
    }

    @objc private func viewTapped() { onView?() }
    @objc private func dismissTapped() { onDismiss?() }
}
