import CoreServices
import Foundation

/// File work for transfers, kept off the client actor: part files may sit on a slow disk and
/// shared files on a network share, and the actor has to keep answering the server meanwhile.
enum SlskTransferFiles {
    /// Runs blocking file work on a utility thread.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func remove(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Moves a finished part file to `destination` — or "name 2.ext", "name 3.ext", … when that's
    /// taken, so an existing file is never replaced — creating the folder, and marks it as
    /// downloaded from the internet. Returns where it landed.
    static func moveIntoPlace(_ part: URL, to destination: URL) async throws -> URL {
        try await perform {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            for candidate in candidates(for: destination) {
                do {
                    try fileManager.moveItem(at: part, to: candidate)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
                quarantine(candidate)
                return candidate
            }
            throw SlskError(message: "no free name for \(destination.lastPathComponent)")
        }
    }

    /// `url`, then "name 2.ext" … "name 99.ext", then one with a random suffix.
    private static func candidates(for url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func named(_ name: String) -> URL {
            folder.appendingPathComponent(ext.isEmpty ? name : name + "." + ext, isDirectory: false)
        }
        return [url] + (2 ... 99).map { named("\(base) \($0)") } + [named("\(base) \(UUID().uuidString.prefix(8))")]
    }

    /// The same mark a browser leaves on downloads, so Gatekeeper checks anything that would run.
    private static func quarantine(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "susurrus",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var url = url
        try? url.setResourceValues(values)
    }
}

/// A download's part file, written on its own queue.
final class SlskPartFile: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "susurrus.slsk.part-file", qos: .utility)

    private init(handle: FileHandle) {
        self.handle = handle
    }

    /// Opens the part file at `url` (creating it and its folder), positioned to resume at its
    /// current size. One larger than `expectedSize` belongs to some other file, so it's emptied.
    static func open(_ url: URL, expectedSize: UInt64) async throws -> (file: SlskPartFile, offset: UInt64) {
        try await SlskTransferFiles.perform {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: nil) else {
                    throw SlskError(message: "can't create \(url.lastPathComponent)")
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            var offset = try handle.seekToEnd()
            if offset > expectedSize {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                offset = 0
            }
            return (SlskPartFile(handle: handle), offset)
        }
    }

    func write(_ data: Data) async throws {
        try await run { try self.handle.write(contentsOf: data) }
    }

    /// Closes the file once everything written so far is on disk.
    func close() async {
        try? await run { try self.handle.close() }
    }

    private func run(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// A shared file being uploaded, read on its own queue one chunk ahead of the sender, so a slow
/// disk or network share overlaps with the network instead of adding to it.
final class SlskUploadFile: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "susurrus.slsk.upload-file", qos: .utility)
    /// The next chunk, read while the previous one was being sent. Touched on `queue` only.
    private var readAhead: Result<Data, Error>?

    private init(handle: FileHandle) {
        self.handle = handle
    }

    static func open(_ url: URL, at offset: UInt64) async throws -> SlskUploadFile {
        try await SlskTransferFiles.perform {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: offset)
            return SlskUploadFile(handle: handle)
        }
    }

    /// The next chunk of up to `count` bytes; empty at the end of the file.
    func read(upToCount count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                let result = self.readAhead ?? Result { try self.handle.read(upToCount: count) ?? Data() }
                self.readAhead = nil
                continuation.resume(with: result)
                if case .success(let chunk) = result, !chunk.isEmpty {
                    self.readAhead = Result { try self.handle.read(upToCount: count) ?? Data() }
                }
            }
        }
    }

    func close() {
        queue.async { try? self.handle.close() }
    }
}
