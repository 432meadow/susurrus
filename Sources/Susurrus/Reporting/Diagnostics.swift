import Foundation

/// What a bug report says about the Mac, the app and its state, already redacted. Counts and
/// switches only: no track names, paths, device names or Soulseek user names.
@MainActor
enum Diagnostics {
    static func collect(from model: AppModel, events: [EventLog.Entry] = EventLog.shared.recent(40)) async -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        if let version = info["CFBundleShortVersionString"] as? String {
            lines.append("susurrus \(version) (\(info["CFBundleVersion"] as? String ?? "?"))")
        } else {
            lines.append("susurrus (development build)")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(machine()), "
            + "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")

        // Library
        let tracks = model.tracks
        let kinds = Dictionary(grouping: tracks, by: \.fileType).mapValues(\.count).sorted { $0.value > $1.value }
        let mix = kinds.prefix(4).map { "\($0.key.isEmpty ? "?" : $0.key) \(percent($0.value, of: tracks.count))" }.joined(separator: ", ")
        lines.append("Library: \(tracks.count.formatted()) tracks\(mix.isEmpty ? "" : " (\(mix))"), \(model.playlistsByID.count) playlists, "
            + "\(model.missingTrackCount) missing")
        let folders = model.watchedFolders
        let volumes = await Task.detached(priority: .userInitiated) { folders.map(volumeDescription) }.value
        if !volumes.isEmpty {
            let counted = Dictionary(grouping: volumes, by: { $0 }).map { "\($0.value.count) on \($0.key)" }.sorted()
            lines.append("Music folders: " + counted.joined(separator: ", "))
        }

        // Settings and state
        let player = model.player
        let playing = player.currentTrack == nil ? "stopped" : player.isPlaying ? "playing" : "paused"
        var playback = "Player: \(playing)"
        if player.isWaitingForShare { playback += ", waiting for the share" }
        playback += "; output: \(player.outputDeviceUID == nil ? "system" : "chosen device")"
        playback += "; EQ \(player.equalizer.isEnabled ? "on" : "off")"
        lines.append(playback)
        let decks = model.mixer.decks.map { deck in
            "\(deck.side.name) " + (deck.track == nil ? "empty" : deck.isPlaying ? "playing" : "loaded")
        }
        lines.append("Mixer: \(model.isShowingMixer ? "shown" : "hidden"), decks \(decks.joined(separator: ", "))")
        lines.append("Tags written to files: \(model.writesTagsToFiles ? "on" : "off")"
            + (model.tagWriter.failures.isEmpty ? "" : ", \(model.tagWriter.failures.count) failed writes")
            + (model.tagWriter.waiting.isEmpty ? "" : ", \(model.tagWriter.waiting.count) waiting"))
        let soulseek = switch model.soulseek.state {
        case .disconnected: "not connected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        }
        lines.append("Soulseek: \(soulseek)")

        if !events.isEmpty {
            lines.append("")
            lines.append("Recent events:")
            for entry in events {
                var redacted = entry
                redacted.message = BugReport.redact(entry.message)
                lines.append("  " + redacted.line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func percent(_ part: Int, of whole: Int) -> String {
        whole > 0 ? "\(Int((Double(part) / Double(whole) * 100).rounded()))%" : "0%"
    }

    /// "Mac14,15 (Apple silicon)"
    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        return "\(String(cString: model)) (\(chip))"
    }

    /// "a local disk (apfs)", "a network share (smbfs)" or "a missing folder", never the path.
    nonisolated static func volumeDescription(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeTypeNameKey]) else {
            return "a missing folder"
        }
        let kind = values.volumeIsLocal == false ? "a network share" : "a local disk"
        return values.volumeTypeName.map { "\(kind) (\($0))" } ?? kind
    }
}
