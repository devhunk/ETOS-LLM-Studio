import Foundation
import GRDB

/// Config database snapshots already participate in backup and iPhone/watchOS database sync.
/// Store each job separately so importing one result does not rewrite every task.
final class BatchDatabaseJobStore: BatchJobStoring, @unchecked Sendable {
    private let testingStore: PersistenceAuxiliaryGRDBStore?
    init(store: PersistenceAuxiliaryGRDBStore? = nil) { testingStore = store }

    private func database() throws -> PersistenceAuxiliaryGRDBStore {
        guard let store = testingStore ?? Persistence.activeAuxiliaryStore(kind: .config) else {
            throw BatchError.persistence(NSLocalizedString("配置数据库尚不可用，请解锁后再打开批量任务。", comment: "Batch database unavailable"))
        }
        return store
    }
    func loadJobs() throws -> [BatchJob] {
        let rows = try database().read { db in
            try Data.fetchAll(db, sql: "SELECT json_data FROM json_blobs WHERE key LIKE 'batch.job.%'")
        }
        return try rows.map { try JSONDecoder().decode(BatchJob.self, from: $0) }.sorted { $0.createdAt > $1.createdAt }
    }
    func saveJob(_ job: BatchJob) throws {
        let data = try JSONEncoder().encode(job)
        try database().write { db in
            try db.execute(sql: """
                INSERT INTO json_blobs (key, json_data, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET json_data = excluded.json_data, updated_at = excluded.updated_at
                """, arguments: ["batch.job.\(job.id.uuidString)", data, job.updatedAt.timeIntervalSince1970])
        }
        Persistence.postCloudSyncLocalDataDidChange()
    }
}
