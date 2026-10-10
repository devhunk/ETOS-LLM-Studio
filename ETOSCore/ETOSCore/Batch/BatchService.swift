import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// No perpetual polling: remote work survives suspension; clients refresh when active.
public actor BatchService {
    public typealias Transport = @Sendable (URLRequest, BatchTarget) async throws -> Data
    public typealias CredentialResolver = @Sendable (BatchTarget) async throws -> BatchCredentials
    private let store: any BatchJobStoring
    private let adapter: any BatchAPIAdapter
    private let transport: Transport
    private let credentials: CredentialResolver
    private var operations = Set<UUID>()

    public init(store: any BatchJobStoring, adapter: any BatchAPIAdapter = OpenAIBatchAdapter(),
                transport: @escaping Transport, credentials: @escaping CredentialResolver) {
        self.store = store
        self.adapter = adapter
        self.transport = transport
        self.credentials = credentials
    }

    public func jobs() throws -> [BatchJob] { try store.loadJobs() }
    private func job(_ id: UUID) throws -> BatchJob {
        guard let job = try store.loadJobs().first(where: { $0.id == id }) else { throw BatchError.missingJob }
        return job
    }
    private func begin(_ id: UUID) throws {
        guard operations.insert(id).inserted else { throw BatchError.busy }
    }
    private func save(_ job: inout BatchJob) throws {
        job.updatedAt = Date()
        try store.saveJob(job)
    }

    /// Each entry is a complete independent text conversation, never a slice of a chat history.
    public static func normalizedItems(_ items: [BatchItem], target: BatchTarget) throws -> [BatchItem] {
        guard target.endpoint == "/v1/chat/completions", !items.isEmpty, items.count <= 50_000,
              Set(items.map(\.id)).count == items.count else {
            throw BatchError.invalidInput(NSLocalizedString("请输入 1 至 50000 条互不重复的文本请求。", comment: "Batch request count validation"))
        }
        return try items.map { item in
            guard case .dictionary(var body) = item.body,
                  body["model"] == .string(target.modelName),
                  case .array(let messages) = body["messages"], !messages.isEmpty,
                  body["tools"] == nil, body["functions"] == nil,
                  body["tool_choice"] == nil, body["function_call"] == nil else {
                throw BatchError.invalidInput(NSLocalizedString("批量请求必须使用同一模型，每项包含完整文本消息，且不包含工具调用。", comment: "Batch text request validation"))
            }
            for message in messages {
                guard case .dictionary(let fields) = message,
                      case .string(let role) = fields["role"], ["system", "developer", "user", "assistant"].contains(role),
                      case .string = fields["content"], fields["tool_calls"] == nil else {
                    throw BatchError.invalidInput(NSLocalizedString("首版批量任务仅支持文本消息。", comment: "Batch text only validation"))
                }
            }
            if let count = body["n"], count != .int(1) {
                throw BatchError.invalidInput(NSLocalizedString("批量任务每条请求仅支持一个回答，请将 n 设置为 1。", comment: "Batch single completion validation"))
            }
            body["stream"] = .bool(false)
            body.removeValue(forKey: "stream_options")
            return BatchItem(id: item.id, sourceItemID: item.sourceItemID, body: .dictionary(body))
        }
    }

    public static func jsonl(items: [BatchItem], target: BatchTarget) throws -> Data {
        let normalized = try normalizedItems(items, target: target)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for item in normalized {
            let line: JSONValue = .dictionary([
                "custom_id": .string(item.customID), "method": .string("POST"),
                "url": .string(target.endpoint), "body": item.body
            ])
            data.append(try encoder.encode(line))
            data.append(0x0a)
            guard data.count <= 200_000_000 else {
                throw BatchError.invalidInput(NSLocalizedString("批量请求文件不能超过 200 MB。", comment: "Batch file size validation"))
            }
        }
        return data
    }

    public func submit(target: BatchTarget, items: [BatchItem]) async throws -> BatchJob {
        let normalized = try Self.normalizedItems(items, target: target)
        let data = try Self.jsonl(items: normalized, target: target)
        let auth = try await credentials(target)
        var job = BatchJob(target: target, items: normalized)
        try begin(job.id)
        defer { operations.remove(job.id) }
        try save(&job) // Persist intent before any potentially billable operation.
        do {
            let upload = try adapter.uploadRequest(target: target, credentials: auth, jsonl: data)
            struct FileResponse: Decodable { let id: String }
            let uploaded = try JSONDecoder().decode(FileResponse.self, from: await transport(upload, target))
            _ = try adapter.downloadRequest(target: target, credentials: auth, fileID: uploaded.id)
            job.inputFileID = uploaded.id
            job.submissionState = .uploaded
            try save(&job)
            let create = try adapter.createRequest(target: target, credentials: auth, fileID: uploaded.id)
            job.submissionState = .submitting
            try save(&job)
            let remote = try JSONDecoder().decode(BatchRemoteJob.self, from: await transport(create, target))
            _ = try adapter.statusRequest(target: target, credentials: auth, remoteID: remote.id)
            job.remoteID = remote.id
            job.submissionState = .submitted
            apply(remote, to: &job)
            try save(&job)
            return job
        } catch {
            // A lost create response may already have created a paid remote job. Never auto-resubmit.
            job.submissionState = job.submissionState == .submitting ? .uncertain : job.submissionState
            if job.submissionState == .preparing || job.submissionState == .uploaded { job.submissionState = .failed }
            job.lastError = error.localizedDescription
            try save(&job)
            throw error
        }
    }

    private func apply(_ remote: BatchRemoteJob, to job: inout BatchJob) {
        job.remoteStatus = BatchRemoteStatus(rawValue: remote.status)
        job.outputFileID = remote.output_file_id
        job.errorFileID = remote.error_file_id
        job.serverCompletedCount = remote.request_counts?.completed ?? 0
        job.serverFailedCount = remote.request_counts?.failed ?? 0
    }

    public func refresh(_ id: UUID) async throws -> BatchJob {
        try begin(id)
        defer { operations.remove(id) }
        var job = try job(id)
        guard let remoteID = job.remoteID else { throw BatchError.uncertainSubmission }
        do {
            let auth = try await credentials(job.target)
            let request = try adapter.statusRequest(target: job.target, credentials: auth, remoteID: remoteID)
            let remote = try JSONDecoder().decode(BatchRemoteJob.self, from: await transport(request, job.target))
            guard remote.id == remoteID else { throw BatchError.invalidResponse("Batch ID mismatch") }
            apply(remote, to: &job)
            job.lastError = nil
            try save(&job) // Server completion and successful local import are independent states.
            if job.remoteStatus?.isTerminal == true && !job.resultsImported {
                if remote.status == "completed" && job.outputFileID == nil && job.errorFileID == nil {
                    throw BatchError.invalidResponse(NSLocalizedString("厂商尚未返回结果文件，请稍后再次刷新。", comment: "Batch missing result files"))
                }
                var files: [Data] = []
                for fileID in [job.outputFileID, job.errorFileID].compactMap({ $0 }) {
                    let request = try adapter.downloadRequest(target: job.target, credentials: auth, fileID: fileID)
                    files.append(try await transport(request, job.target))
                }
                job.items = try Self.importResults(files: files, items: job.items, terminalStatus: remote.status,
                                                  batchError: remote.errors)
                job.resultsImported = true
                try save(&job)
            }
            return job
        } catch {
            job.lastError = error.localizedDescription
            try save(&job)
            throw error
        }
    }

    public func cancel(_ id: UUID) async throws -> BatchJob {
        try begin(id)
        defer { operations.remove(id) }
        var job = try job(id)
        guard let remoteID = job.remoteID else { throw BatchError.uncertainSubmission }
        if job.remoteStatus?.isTerminal == true { return job }
        let auth = try await credentials(job.target)
        let request = try adapter.cancelRequest(target: job.target, credentials: auth, remoteID: remoteID)
        let remote = try JSONDecoder().decode(BatchRemoteJob.self, from: await transport(request, job.target))
        guard remote.id == remoteID else { throw BatchError.invalidResponse("Batch ID mismatch") }
        apply(remote, to: &job)
        job.lastError = nil
        try save(&job)
        return job
    }

    /// Manually reconcile a lost submission response using the provider's dashboard batch ID.
    public func recoverSubmission(_ id: UUID, remoteID: String) async throws -> BatchJob {
        try begin(id)
        defer { operations.remove(id) }
        var job = try job(id)
        guard job.remoteID == nil, [.submitting, .uncertain].contains(job.submissionState),
              let inputFileID = job.inputFileID else { throw BatchError.uncertainSubmission }
        let auth = try await credentials(job.target)
        let request = try adapter.statusRequest(target: job.target, credentials: auth, remoteID: remoteID)
        let remote = try JSONDecoder().decode(BatchRemoteJob.self, from: await transport(request, job.target))
        guard remote.id == remoteID, remote.input_file_id == inputFileID, remote.endpoint == job.target.endpoint else {
            throw BatchError.invalidResponse(NSLocalizedString("该远端任务与本地输入文件或端点不匹配。", comment: "Batch recovery mismatch"))
        }
        job.remoteID = remote.id
        job.submissionState = .submitted
        apply(remote, to: &job)
        job.lastError = nil
        try save(&job)
        return job
    }

    public func retryFailedItems(_ id: UUID) async throws -> BatchJob {
        try begin(id)
        defer { operations.remove(id) }
        let original = try job(id)
        guard original.canRetryFailedItems else { throw BatchError.invalidInput("No imported failed requests to retry") }
        let items = original.items.filter { $0.state == .failed }.map {
            BatchItem(sourceItemID: $0.id, body: $0.body)
        }
        return try await submit(target: original.target, items: items)
    }

    public static func importResults(files: [Data], items: [BatchItem], terminalStatus: String,
                                     batchError: JSONValue? = nil) throws -> [BatchItem] {
        struct ResponseLine: Decodable {
            struct Response: Decodable { let status_code: Int; let body: JSONValue }
            let custom_id: String
            let response: Response?
            let error: JSONValue?
        }
        guard Set(items.map(\.id)).count == items.count else {
            throw BatchError.invalidResponse("Duplicate local request IDs")
        }
        var result = items
        let index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.customID, $0.offset) })
        var seen = Set<String>()
        for file in files {
            guard let text = String(data: file, encoding: .utf8) else { throw BatchError.invalidResponse("Invalid UTF-8 in batch results") }
            for line in text.split(whereSeparator: { $0.isNewline }) {
                let row = try JSONDecoder().decode(ResponseLine.self, from: Data(line.utf8))
                guard let offset = index[row.custom_id], seen.insert(row.custom_id).inserted else {
                    throw BatchError.invalidResponse(NSLocalizedString("结果包含未知或重复的 custom_id，尚未导入。", comment: "Batch invalid result mapping"))
                }
                result[offset].response = row.response?.body
                if let error = row.error, error != .null {
                    result[offset].state = .failed
                    result[offset].error = error.prettyPrintedCompact()
                } else if let response = row.response, (200...299).contains(response.status_code),
                          case .dictionary(let body) = response.body,
                          case .array(let choices) = body["choices"],
                          case .dictionary(let choice) = choices.first,
                          case .dictionary(let message) = choice["message"],
                          let content = completionText(message) {
                    result[offset].state = .succeeded
                    result[offset].outputText = content
                    result[offset].error = nil
                } else {
                    result[offset].state = .failed
                    result[offset].error = row.response?.body.prettyPrintedCompact() ?? "Missing response body"
                }
            }
        }
        for offset in result.indices where result[offset].state == .pending {
            result[offset].state = .failed
            result[offset].error = batchError?.prettyPrintedCompact() ?? "No result returned (\(terminalStatus))"
        }
        return result
    }

    private static func completionText(_ message: [String: JSONValue]) -> String? {
        if case .string(let content) = message["content"] { return content }
        // A refusal is a completed, potentially billable response, not a transport failure to retry.
        if case .string(let refusal) = message["refusal"] { return refusal }
        return nil
    }

    public func exportJSONL(_ id: UUID) throws -> String {
        let job = try job(id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try job.items.map { item in
            let row: JSONValue = .dictionary([
                "custom_id": .string(item.customID), "input": item.body,
                "status": .string(item.state.rawValue), "response": item.response ?? .null,
                "error": item.error.map(JSONValue.string) ?? .null
            ])
            return String(decoding: try encoder.encode(row), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }
}
