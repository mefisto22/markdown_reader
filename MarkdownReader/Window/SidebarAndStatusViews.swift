import AppKit
import SwiftUI
import Observation

@Observable
final class OutlineModel {
    var headings: [OutlineHeading] = []
    @ObservationIgnored var onSelect: ((OutlineHeading) -> Void)?
}

/// Document outline built from the headings, shown in the window's sidebar.
struct OutlineView: View {
    let model: OutlineModel

    var body: some View {
        Group {
            if model.headings.isEmpty {
                Text("No Headings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.headings) { heading in
                    Button {
                        model.onSelect?(heading)
                    } label: {
                        Text(heading.title)
                            .font(heading.level <= 1 ? .body.weight(.semibold) : .body)
                            .foregroundStyle(heading.level >= 4 ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, CGFloat(max(heading.level - 1, 0)) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(heading.title)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 160)
    }
}

/// Thin bar at the bottom of the window: counts, cursor position, encoding.
/// Plain AppKit labels: this view is on the launch path, and avoiding a
/// SwiftUI hosting view here measurably shortens time to first window.
final class StatusBarView: NSView {
    var statistics = TextStatistics() { didSet { if statistics != oldValue { updateLeft() } } }
    var cursor: (line: Int, column: Int)? { didSet { updateRight() } }
    var encoding = "UTF-8" { didSet { if encoding != oldValue { updateRight() } } }

    private let left = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        separator.boxType = .separator
        for label in [left, right] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        right.alignment = .right
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        right.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
        updateLeft()
        updateRight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func updateLeft() {
        left.stringValue = "\(statistics.words.formatted()) words    "
            + "\(statistics.characters.formatted()) characters    "
            + "\(statistics.lines.formatted()) lines"
    }

    private func updateRight() {
        if let cursor {
            right.stringValue = "Ln \(cursor.line), Col \(cursor.column)    \(encoding)"
        } else {
            right.stringValue = encoding
        }
    }
}

/// Sidebar container that creates the SwiftUI outline only when the sidebar
/// is first shown, keeping SwiftUI off the launch path.
final class LazyOutlineViewController: NSViewController {
    private let model: OutlineModel
    private var host: NSHostingController<OutlineView>?

    init(model: OutlineModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
    }

    func loadOutlineIfNeeded() {
        guard host == nil else { return }
        let controller = NSHostingController(rootView: OutlineView(model: model))
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host = controller
    }
}
