import Foundation

/// A message shown over the window without blocking it, so the mixer stays usable while it's up:
/// errors stay until they're dismissed, the rest go away on their own.
struct Notice: Identifiable, Equatable {
    enum Kind {
        case info
        case error
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

/// Telling the user what happened (AppModel+Notices.swift), and running database changes so that a
/// failure is said out loud instead of leaving the screen and the library out of step.
extension AppModel {
    /// Shows a notice. Info notices disappear after a while unless `staysOpen`.
    func notify(_ title: String, _ message: String = "", kind: Notice.Kind = .info, staysOpen: Bool = false) {
        let notice = Notice(kind: kind, title: title, message: message)
        notices.append(notice)
        if notices.count > 4 { notices.removeFirst(notices.count - 4) }
        guard kind == .info, !staysOpen else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.dismiss(notice)
        }
    }

    func dismiss(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
    }

    /// Logs the error and shows it.
    func report(_ title: String, _ error: Error) {
        EventLog.shared.log("\(title): \(error.localizedDescription)")
        notify(title, error.localizedDescription, kind: .error)
    }

    /// Runs a change to the library database. A failure is reported under `title` and gives nil,
    /// so callers only update what's on screen (and register undo) for changes that were saved.
    @discardableResult
    func perform<T>(_ title: String, _ change: (LibraryStore) throws -> T) -> T? {
        guard let store else { return nil }
        do {
            return try change(store)
        } catch {
            report(title, error)
            return nil
        }
    }

    /// Like `perform`, for bookkeeping the user didn't ask for: a failure is only logged.
    @discardableResult
    func performQuietly<T>(_ title: String, _ change: (LibraryStore) throws -> T) -> T? {
        guard let store else { return nil }
        do {
            return try change(store)
        } catch {
            EventLog.shared.log("\(title): \(error.localizedDescription)")
            return nil
        }
    }
}
