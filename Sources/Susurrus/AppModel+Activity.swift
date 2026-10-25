import Foundation

/// Something running in the background, for the toolbar's activity button and the subtitle.
struct Activity: Identifiable {
    let id: String
    let title: String
    var done = 0
    /// 0 while the amount of work isn't known yet.
    var total = 0
    /// Stops it, for jobs that can stop part way.
    var stop: (() -> Void)?

    /// "Writing tags 3/20", for the subtitle.
    var summary: String {
        total > 0 ? "\(title) \(done.formatted())/\(total.formatted())" : title
    }
}

extension AppModel {
    /// Everything running in the background right now.
    var activities: [Activity] {
        var result: [Activity] = []
        switch scanState {
        case .running(let done, let total):
            result.append(Activity(id: "scan", title: total == 0 ? "Looking for new files" : "Adding files",
                                   done: done, total: total, stop: { [weak self] in self?.stopScanning() }))
        default:
            if queuedScans > 0 {
                result.append(Activity(id: "scan", title: "Waiting to add files", stop: { [weak self] in self?.stopScanning() }))
            }
        }
        if tagWriter.isRunning {
            result.append(Activity(id: "tags", title: "Writing tags", done: tagWriter.done, total: tagWriter.total))
        }
        if bpmAnalyzer.isRunning {
            result.append(Activity(id: "bpm", title: "Detecting BPM", done: bpmAnalyzer.done, total: bpmAnalyzer.total,
                                   stop: { [weak self] in self?.bpmAnalyzer.cancel() }))
        }
        if keyAnalyzer.isRunning {
            result.append(Activity(id: "keys", title: "Detecting keys", done: keyAnalyzer.done, total: keyAnalyzer.total,
                                   stop: { [weak self] in self?.keyAnalyzer.cancel() }))
        }
        if let search = coverSearch {
            result.append(Activity(id: "covers", title: "Finding covers", done: search.done, total: search.total,
                                   stop: { [weak self] in self?.stopFindingCovers() }))
        }
        if let move = albumMoveProgress {
            result.append(Activity(id: "move", title: "Moving “\(move.title)” to the library", done: move.done, total: move.total,
                                   stop: { [weak self] in self?.stopMovingAlbums() }))
        } else if isWaitingForLibraryFolder, !queuedAlbumMoves.isEmpty {
            let count = queuedAlbumMoves.count
            result.append(Activity(id: "move", title: "\(count) \(count == 1 ? "album waits" : "albums wait") for the library folder",
                                   stop: { [weak self] in self?.stopMovingAlbums() }))
        }
        if isCheckingForMissingFiles {
            result.append(Activity(id: "missing", title: "Checking for missing files",
                                   stop: { [weak self] in self?.stopCheckingForMissingFiles() }))
        }
        if let status = exchange.status {
            result.append(Activity(id: "exchange", title: status))
        }
        return result
    }
}
