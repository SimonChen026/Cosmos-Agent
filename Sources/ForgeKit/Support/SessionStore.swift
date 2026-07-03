import Foundation

/// One pretty-printed JSON file per session under
/// ~/Library/Application Support/Forge/Sessions. Corrupt files are skipped,
/// never fatal; writes are atomic.
final class FileSessionStore: SessionStoreProtocol, @unchecked Sendable {
    private let baseDir: URL
    private let lock = NSLock()

    init(baseDir: URL? = nil) {
        if let baseDir {
            self.baseDir = baseDir
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
            self.baseDir = support.appendingPathComponent("Cosmos/Sessions", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.baseDir, withIntermediateDirectories: true)
    }

    func listSessions() throws -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil)) ?? []
        var records: [SessionRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else {
                continue   // corrupt file — skip, do not fail the listing
            }
            records.append(record)
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) throws -> SessionRecord? {
        lock.lock(); defer { lock.unlock() }
        let file = fileURL(id)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SessionRecord.self, from: data)
    }

    func save(_ session: SessionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try data.write(to: fileURL(session.id), options: .atomic)
    }

    func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let file = fileURL(id)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(_ id: UUID) -> URL {
        baseDir.appendingPathComponent(id.uuidString + ".json")
    }
}
