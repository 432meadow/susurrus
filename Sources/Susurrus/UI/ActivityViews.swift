import AppKit
import SwiftUI

/// The toolbar's activity button, there while anything runs in the background: a ring for the
/// overall progress, and a popover listing each job with Stop where it can stop.
struct ActivityButton: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingList = false

    var body: some View {
        let activities = model.activities
        Button { isShowingList.toggle() } label: {
            ProgressView(value: Self.fraction(activities))
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
        .help(activities.map(\.summary).joined(separator: "\n"))
        .accessibilityLabel("Background activity")
        .accessibilityValue(activities.map(\.summary).joined(separator: ", "))
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(activities) { activity in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.summary).font(.callout)
                            if activity.total > 0 {
                                ProgressView(value: Double(activity.done), total: Double(activity.total))
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                        }
                        if let stop = activity.stop {
                            Button(action: stop) { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Stop")
                                .accessibilityLabel("Stop \(activity.title.lowercased())")
                        }
                    }
                }
                if activities.isEmpty {
                    Text("Nothing running").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }

    /// Overall progress across the jobs whose size is known (nil spins).
    private static func fraction(_ activities: [Activity]) -> Double? {
        let sized = activities.filter { $0.total > 0 }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(0) { $0 + $1.total }
        return Double(sized.reduce(0) { $0 + $1.done }) / Double(total)
    }
}

/// Notices stacked in a corner of the window (see `AppModel.notify`). They don't block anything:
/// the mixer and the track list stay usable while one is up.
struct NoticeStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.notices) { notice in
                NoticeView(notice: notice) { model.dismiss(notice) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notices)
    }
}

private struct NoticeView: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.kind == .error ? Palette.error : Palette.cool)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.headline)
                if !notice.message.isEmpty {
                    ScrollView {
                        Text(notice.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Dismiss", dismiss)
    }
}

/// Hands over the window a view is in, once it's in one.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

/// Views that use Space themselves (the track list: play/pause, or type-to-select), so the
/// window-wide Space shortcut leaves it to them.
protocol HandlesSpaceKey {}

/// Keys the main window handles wherever the focus is: Space plays and pauses (except while
/// typing, or on a focused button, which Space presses), and ⌘F starts a search.
@MainActor
enum WindowKeys {
    private static var monitor: Any?

    static func install(for model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            let (window, keyCode, characters) = (event.window, event.keyCode, event.charactersIgnoringModifiers)
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let model, let window, window === model.mainWindow, window.attachedSheet == nil else { return false }
                let responder = window.firstResponder
                if keyCode == 49, modifiers.isEmpty, !(responder is NSText), !(responder is HandlesSpaceKey),
                   !(responder is NSControl) || responder is NSTableView {
                    model.player.togglePlayPause()
                    return true
                }
                return modifiers == .command && characters == "f" && focusSearchField(in: window)
            }
            return handled ? nil : event
        }
    }

    /// Starts typing in the toolbar's search field, if the window shows one.
    private static func focusSearchField(in window: NSWindow) -> Bool {
        guard let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first else { return false }
        item.beginSearchInteraction()
        return true
    }
}
