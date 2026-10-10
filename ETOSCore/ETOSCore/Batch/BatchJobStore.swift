import Foundation

public protocol BatchJobStoring: Sendable {
    func loadJobs() throws -> [BatchJob]
    func saveJob(_ job: BatchJob) throws
}

/// Atomic per-job files keep an interrupted result import from replacing other jobs.
public final class BatchJobStore: BatchJobStoring, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }

    public func loadJobs() throws -> [BatchJob] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(BatchJob.self, from: Data(contentsOf: $0))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveJob(_ job: BatchJob) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(job).write(to: directory.appendingPathComponent("\(job.id.uuidString).json"), options: .atomic)
    }
}
