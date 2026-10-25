import AppKit
import SwiftUI

/// Help ▸ Report a Bug: a short form that opens a new GitHub issue, filled in, in the browser.
/// Nothing is sent from here; the user reads it over and submits it on GitHub.
struct BugReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var whatHappened = ""
    @State private var steps = ""
    @State private var includesDiagnostics = true
    @State private var diagnostics = ""
    @State private var crash: BugReport.Crash?
    @State private var includesCrash = true
    @State private var showsDetails = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe what went wrong. susurrus opens a new issue on GitHub with this filled in, for you to read over and submit.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Summary", text: $title, prompt: Text("Short summary, like “Deck B stops after a crossfade”"))
                .textFieldStyle(.roundedBorder)

            field("What happened, and what did you expect?", text: $whatHappened, minHeight: 90)
            field("Steps to reproduce (optional)", text: $steps, minHeight: 56)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Include diagnostics", isOn: $includesDiagnostics)
                if let crash {
                    Toggle("Include the crash from \(crash.date.formatted(date: .abbreviated, time: .shortened))", isOn: $includesCrash)
                }
                DisclosureGroup("What's included", isExpanded: $showsDetails) {
                    TextEditor(text: $diagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 160)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                        .help("Edit anything you'd rather leave out.")
                        .disabled(!includesDiagnostics)
                        .opacity(includesDiagnostics ? 1 : 0.5)
                    if let crash, includesCrash {
                        ScrollView {
                            Text(crashText(crash))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 90)
                    }
                }
                .disabled(!includesDiagnostics && !(includesCrash && crash != nil))
            }

            Label("Issues on GitHub are public. File paths and your Mac's user and computer names are left out; read the details over before you send.",
                  systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Copy Report") { copy() }
                    .help("Copies the report as text, to send another way")
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open in GitHub…") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Opens a new issue in your browser (needs a GitHub account)")
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await prepare() }
    }

    private func field(_ label: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: minHeight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        }
    }

    private func prepare() async {
        crash = await Task.detached(priority: .userInitiated) { BugReport.latestCrash() }.value
        diagnostics = await Diagnostics.collect(from: model)
    }

    private func crashText(_ crash: BugReport.Crash) -> String {
        "Last crash (\(crash.date.formatted(.iso8601))):\n" + BugReport.redact(crash.summary)
    }

    private var draft: BugReport.Draft {
        var parts: [String] = []
        if includesDiagnostics { parts.append(diagnostics) }
        if includesCrash, let crash { parts.append(crashText(crash)) }
        return BugReport.Draft(title: title, whatHappened: whatHappened, steps: steps,
                               diagnostics: parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
    }

    private func copy() {
        let text = "# \(title)\n\n" + BugReport.body(draft)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Copied"
    }

    private func open() {
        let (url, trimmed) = BugReport.issueURL(draft)
        if trimmed {
            // The link can't hold everything; the whole report goes on the clipboard to paste in.
            copy()
            notice = nil
            model.notify("The diagnostics were too long for the link",
                         "The oldest events were left out of the issue. The whole report is on the clipboard if you want to paste it in instead.",
                         staysOpen: true)
        }
        NSWorkspace.shared.open(url)
        EventLog.shared.log("Opened a bug report", level: .info)
        dismiss()
    }
}
