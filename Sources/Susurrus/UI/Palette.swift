import AppKit
import SwiftUI

/// The pastel accents borrowed from elsewhere: a dusty rose (`--warm`) and a slate blue (`--cool`),
/// each with its own value for dark and light appearance, plus elsewhere's dusk ochre for warnings.
enum Palette {
    /// The app's accent: active toggles, the now-playing mark, ratings, selection rings.
    static let warmNS = dynamic(dark: 0xB17C77, light: 0x9D6460)
    /// The quieter second accent: things in motion, like transfers under way.
    static let coolNS = dynamic(dark: 0x6E8494, light: 0x5B7484)
    /// Soft warnings: waiting, failed-but-retryable.
    static let ochreNS = dynamic(dark: 0xB8925C, light: 0x9A7238)
    /// Errors: a muted brick red.
    static let errorNS = dynamic(dark: 0xD08070, light: 0xA94A3F)
    /// Done and matched: a sage green.
    static let successNS = dynamic(dark: 0x8DAF86, light: 0x557F4E)

    static let warm = Color(nsColor: warmNS)
    static let cool = Color(nsColor: coolNS)
    static let ochre = Color(nsColor: ochreNS)
    static let error = Color(nsColor: errorNS)
    static let success = Color(nsColor: successNS)

    /// With Increase Contrast on, each colour moves further from the background: darker on light,
    /// lighter on dark.
    private static func dynamic(dark: Int, light: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: rgb(dark)
            case .accessibilityHighContrastDarkAqua?: rgb(dark).blended(withFraction: 0.35, of: .white) ?? rgb(dark)
            case .accessibilityHighContrastAqua?: rgb(light).blended(withFraction: 0.35, of: .black) ?? rgb(light)
            default: rgb(light)
            }
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Selection

extension Palette {
    /// The selection highlight: a slate wash, a little stronger while the list has focus.
    static func selectionNS(emphasized: Bool) -> NSColor {
        coolNS.withAlphaComponent(emphasized ? 0.42 : 0.24)
    }
}

/// Draws an AppKit table's selected rows in the slate wash, keeping the text in its normal colours.
final class PaletteRowView: NSTableRowView {
    private static let inset: CGFloat = 10
    private static let radius: CGFloat = 5

    /// The wash is light, so cells keep their normal ink rather than switching to white.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// Cells that draw differently on a selected row (the rating stars) need a redraw when it changes,
    /// since their background style stays the same.
    override var isSelected: Bool {
        didSet { if isSelected != oldValue { subviews.forEach { $0.needsDisplay = true } } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Self.inset, dy: 0)
        Palette.selectionNS(emphasized: isEmphasized).setFill()
        // Runs of selected rows join into one shape, rounded only at its ends.
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius)
        if isPreviousRowSelected { path.append(NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: Self.radius))) }
        if isNextRowSelected { path.append(NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - Self.radius, width: rect.width, height: Self.radius))) }
        path.fill()
    }
}

extension View {
    /// Swaps a SwiftUI `List` row's system selection highlight for the slate wash.
    func paletteSelection(_ isSelected: Bool) -> some View {
        listRowBackground(SelectionWash(isSelected: isSelected))
    }
}

private struct SelectionWash: View {
    let isSelected: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ZStack {
            NativeSelectionOff()
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: Palette.selectionNS(emphasized: activeState != .inactive)))
                    .padding(.horizontal, 10)
            }
        }
    }
}

/// SwiftUI has no say over a `List`'s selection colour, so this reaches the `NSTableView` behind
/// the row it sits in and turns its own highlight off; `SelectionWash` draws the replacement.
private struct NativeSelectionOff: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView, table.selectionHighlightStyle != .none else { return }
            table.selectionHighlightStyle = .none
        }
    }
}
