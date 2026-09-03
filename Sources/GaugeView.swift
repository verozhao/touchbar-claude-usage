import AppKit

/// A compact Touch Bar tile: title on the left, value on the right, a thin progress bar underneath.
final class GaugeView: NSView {
    var title: String { didSet { needsDisplay = true } }
    var valueText: String = "–" { didSet { needsDisplay = true } }
    var shortValueText: String? = nil { didSet { needsDisplay = true } }   // used when valueText does not fit
    var percent: Double? = nil { didSet { needsDisplay = true } }
    var accent: NSColor? = nil { didSet { needsDisplay = true } }   // nil = severity colours
    var dimmed: Bool = false { didSet { needsDisplay = true } }
    let fixedWidth: CGFloat

    init(title: String, width: CGFloat) {
        self.title = title
        self.fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: fixedWidth, height: 30) }
    override var isFlipped: Bool { true }

    static func severityColor(_ pct: Double) -> NSColor {
        switch pct {
        case ..<50: return NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)   // green
        case ..<75: return NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)   // yellow
        case ..<90: return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)   // orange
        default:    return NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)   // red
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        // Tile bezel, like a Touch Bar button.
        NSColor(white: 1, alpha: dimmed ? 0.07 : 0.13).setFill()
        NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.45 : 1
        let inset: CGFloat = 8
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.white.withAlphaComponent(alpha * 0.9)]

        let t = NSAttributedString(string: title, attributes: titleAttrs)
        var v = NSAttributedString(string: valueText, attributes: valueAttrs)
        let available = b.width - inset * 2 - t.size().width - 6
        if v.size().width > available, let short = shortValueText {
            v = NSAttributedString(string: short, attributes: valueAttrs)
        }
        let textY: CGFloat = 4
        t.draw(at: NSPoint(x: inset, y: textY))
        let vw = v.size().width
        v.draw(at: NSPoint(x: b.width - inset - vw, y: textY))

        // Bar
        let barH: CGFloat = 4
        let barRect = NSRect(x: inset, y: b.height - 6 - barH, width: b.width - inset * 2, height: barH)
        NSColor(white: 1, alpha: 0.18 * alpha).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2).fill()
        if let p = percent {
            let frac = CGFloat(min(100, max(0, p)) / 100)
            let w = max(barH, barRect.width * frac)
            let fill = (accent ?? GaugeView.severityColor(p)).withAlphaComponent(alpha)
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY, width: w, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
        }
    }
}

/// A fixed-width text tile (status / pending prompt headline) with middle truncation.
final class InfoView: NSView {
    let label = NSTextField(labelWithString: "")
    let fixedWidth: CGFloat
    var highlighted: Bool = false { didSet { needsDisplay = true } }

    init(width: CGFloat) {
        fixedWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: fixedWidth, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        (highlighted ? NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 0.28) : NSColor(white: 1, alpha: 0.08)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    func set(_ text: String, color: NSColor = .white) {
        label.stringValue = text
        label.textColor = color
        label.toolTip = text
    }
}
