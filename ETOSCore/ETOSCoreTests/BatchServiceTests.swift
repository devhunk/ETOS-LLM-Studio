import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ETOSCore)
@testable import ETOSCore
#else
@testable import ETOSBatchCore
#endif

private func batchTarget() -> BatchTarget {
    BatchTarget(providerID: UUID(), providerName: "Fixture", modelID: UUID(), modelName: "fixture-model",
                baseURL: URL(string: "https://api.openai.com/v1")!, credentialReference: "fixture-reference")
}
private func batchInput(_ prompt: String = "Question") -> BatchItem {
    BatchItem(body: .dictionary([
        "model": .string("fixture-model"), "stream": .bool(true),
        "messages": .array([
            .dictionary(["role": .string("system"), "content": .string("System instruction")]),
            .dictionary(["role": .string("user"), "content": .string(prompt)])
        ])
    ]))
}
private func batchResult(_ item: BatchItem, answer: String) throws -> Data {
    let body: JSONValue = .dictionary([
        "custom_id": .string(item.customID),
        "response": .dictionary([
            "status_code": .int(200),
            "body": .dictionary([
                "choices": .array([.dictionary(["message": .dictionary(["content": .string(answer)])])]),
                "usage": .dictionary(["total_tokens": .int(12)])
            ])
        ]), "error": .null
    ])
    var data = try JSONEncoder().encode(body)
    data.append(0x0a)
    return data
}
private func batchFailure(_ item: BatchItem) throws -> Data {
    var data = try JSONEncoder().encode(JSONValue.dictionary([
        "custom_id": .string(item.customID), "response": .null,
        "error": .dictionary(["code": .string("rate_limit"), "message": .string("Retry later")])
    ]))
    data.append(0x0a)
    return data
}

private actor BatchFixtureServer {
    private var requests: [URLRequest] = []
    private var status = "in_progress"
    private var output: Data?
    private var errors: Data?
    private var downloadFailures = 0
    private var failCreation = false
    private var recoveryFileID = "file_input"

    func configure(status: String, output: Data? = nil, errors: Data? = nil, downloadFailures: Int = 0) {
        self.status = status; self.output = output; self.errors = errors; self.downloadFailures = downloadFailures
    }
    func failCreate() { failCreation = true }
    func recoveryInput(_ value: String) { recoveryFileID = value }
    func calls() -> [URLRequest] { requests }

    func send(_ request: URLRequest, target: BatchTarget) throws -> Data {
        requests.append(request)
        let path = request.url!.path
        if path == "/v1/files", request.httpMethod == "POST" {
            return Data(#"{"id":"file_input"}"#.utf8)
        }
        if path == "/v1/batches", request.httpMethod == "POST", failCreation { throw URLError(.timedOut) }
        if path.hasSuffix("/content") {
            if downloadFailures > 0 { downloadFailures -= 1; throw URLError(.networkConnectionLost) }
            return path.contains("file_output") ? (output ?? Data()) : (errors ?? Data())
        }
        if path.hasSuffix("/cancel") { status = "cancelling" }
        return try JSONEncoder().encode(JSONValue.dictionary([
            "id": .string("batch_fixture"), "status": .string(status),
            "input_file_id": .string(recoveryFileID), "endpoint": .string(target.endpoint),
            "output_file_id": output == nil ? .null : .string("file_output"),
            "error_file_id": errors == nil ? .null : .string("file_errors"),
            "request_counts": .dictionary(["completed": .int(output == nil ? 0 : 1), "failed": .int(errors == nil ? 0 : 1)])
        ]))
    }
}

private func batchService(store: any BatchJobStoring, server: BatchFixtureServer) -> BatchService {
    BatchService(store: store, transport: { try await server.send($0, target: $1) },
                 credentials: { _ in BatchCredentials(apiKey: "fixture-key", headerOverrides: ["X-Project": "fixture-project"]) })
}
private func batchStore() -> (BatchJobStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("batch-test-\(UUID().uuidString)")
    return (BatchJobStore(directory: directory), directory)
}

private actor BatchRefreshGate {
    private var paused = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        paused = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    func waitUntilPaused() async {
        if !paused { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

@Suite("OpenAI Batch lifecycle")
struct BatchServiceTests {
    @Test("JSONL preserves complete conversations, escapes multiline input and disables streaming")
    func jsonlSnapshot() throws {
        let item = batchInput("Line one\nLine two \"quoted\"")
        let data = try BatchService.jsonl(items: [item], target: batchTarget())
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(object["custom_id"] as? String == item.customID)
        #expect(object["url"] as? String == "/v1/chat/completions")
        let body = try #require(object["body"] as? [String: Any])
        #expect(body["stream"] as? Bool == false)
        #expect((body["messages"] as? [[String: Any]])?.count == 2)
        #expect(body["custom_id"] == nil)
    }

    @Test("Empty, duplicate, wrong-model and tool requests are rejected before upload")
    func invalidInputs() throws {
        let target = batchTarget()
        let item = batchInput()
        #expect(throws: BatchError.self) { try BatchService.jsonl(items: [], target: target) }
        #expect(throws: BatchError.self) { try BatchService.jsonl(items: [item, item], target: target) }
        for extra in ["model": JSONValue.string("another-model"), "tools": .array([]), "n": .int(2)] {
            guard case .dictionary(var body) = item.body else { return }
            body[extra.key] = extra.value
            #expect(throws: BatchError.self) { try BatchService.jsonl(items: [BatchItem(body: .dictionary(body))], target: target) }
        }
    }

    @Test("Multipart upload, create, status and cancel preserve authentication and project headers")
    func adapterRequests() throws {
        let adapter = OpenAIBatchAdapter(), target = batchTarget()
        let auth = BatchCredentials(apiKey: "fixture-key", headerOverrides: ["OpenAI-Project": "project", "X-Key": "{api_key}", "Content-Type": "wrong"])
        let upload = try adapter.uploadRequest(target: target, credentials: auth, jsonl: Data("{}\n".utf8))
        #expect(upload.url?.path == "/v1/files")
        #expect(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        #expect(String(decoding: upload.httpBody!, as: UTF8.self).contains("name=\"purpose\"\r\n\r\nbatch"))
        let create = try adapter.createRequest(target: target, credentials: auth, fileID: "file_input")
        let body = try #require(JSONSerialization.jsonObject(with: create.httpBody!) as? [String: String])
        #expect(body["completion_window"] == "24h")
        #expect(body["endpoint"] == "/v1/chat/completions")
        for request in [upload, create,
                        try adapter.statusRequest(target: target, credentials: auth, remoteID: "batch_fixture"),
                        try adapter.cancelRequest(target: target, credentials: auth, remoteID: "batch_fixture")] {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "OpenAI-Project") == "project")
            #expect(request.value(forHTTPHeaderField: "X-Key") == "fixture-key")
        }
        #expect(throws: BatchError.self) {
            try adapter.statusRequest(target: target, credentials: auth, remoteID: "../files/leak")
        }
    }

    @Test("Finalizing and unknown states remain nonterminal and survive restart")
    func intermediateStatus() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), target = batchTarget()
        let service = batchService(store: store, server: server)
        let job = try await service.submit(target: target, items: [batchInput()])
        await server.configure(status: "finalizing")
        let finalizing = try await service.refresh(job.id)
        #expect(finalizing.remoteStatus?.rawValue == "finalizing")
        #expect(finalizing.remoteStatus?.isTerminal == false)
        #expect(!finalizing.resultsImported)
        let restored = batchService(store: BatchJobStore(directory: directory), server: server)
        #expect(try await restored.jobs().first?.remoteID == "batch_fixture")
        await server.configure(status: "future_server_state")
        let unknown = try await restored.refresh(job.id)
        #expect(unknown.remoteStatus?.isTerminal == false)
        #expect(unknown.remoteStatus?.rawValue == "future_server_state")
    }

    @Test("Out-of-order results map by custom_id, with usage and per-item failures")
    func unorderedResults() throws {
        let first = batchInput("First"), second = batchInput("Second"), failed = batchInput("Third")
        var output = try batchResult(second, answer: "Second answer")
        output.append(try batchResult(first, answer: "First answer"))
        let result = try BatchService.importResults(files: [output, batchFailure(failed)], items: [first, second, failed], terminalStatus: "completed")
        #expect(result[0].outputText == "First answer")
        #expect(result[1].outputText == "Second answer")
        #expect(result[0].usage == .dictionary(["total_tokens": .int(12)]))
        #expect(result[2].state == .failed)
        #expect(result[2].error?.contains("rate_limit") == true)
    }

    @Test("Unknown or duplicate result IDs and malformed JSON never silently import")
    func invalidResults() throws {
        let item = batchInput(), other = batchInput()
        let data = try batchResult(item, answer: "Answer")
        #expect(throws: BatchError.self) {
            try BatchService.importResults(files: [data, data], items: [item], terminalStatus: "completed")
        }
        #expect(throws: BatchError.self) {
            try BatchService.importResults(files: [batchResult(other, answer: "Other")], items: [item], terminalStatus: "completed")
        }
        #expect(throws: (any Error).self) {
            try BatchService.importResults(files: [Data("broken JSON\n".utf8)], items: [item], terminalStatus: "completed")
        }
    }

    @Test("Expired jobs preserve successful partial outputs and make missing requests retryable")
    func partialExpiration() throws {
        let done = batchInput(), missing = batchInput()
        let result = try BatchService.importResults(files: [batchResult(done, answer: "Done")], items: [done, missing], terminalStatus: "expired")
        #expect(result[0].state == .succeeded)
        #expect(result[1].state == .failed)
        #expect(result[1].error?.contains("expired") == true)
    }

    @Test("HTTP errors in output rows do not count as successful completions")
    func httpFailure() throws {
        let item = batchInput()
        let row: JSONValue = .dictionary([
            "custom_id": .string(item.customID), "response": .dictionary([
                "status_code": .int(400), "body": .dictionary(["error": .string("invalid request")])
            ]), "error": .null
        ])
        let result = try BatchService.importResults(files: [JSONEncoder().encode(row)], items: [item], terminalStatus: "completed")
        #expect(result[0].state == .failed)
    }

    @Test("A valid refusal is a completed answer and is not automatically made retryable")
    func refusalResult() throws {
        let item = batchInput()
        let row: JSONValue = .dictionary([
            "custom_id": .string(item.customID),
            "response": .dictionary([
                "status_code": .int(200), "body": .dictionary([
                    "choices": .array([.dictionary(["message": .dictionary([
                        "content": .null, "refusal": .string("Unable to answer")
                    ])])])
                ])
            ]), "error": .null
        ])
        let result = try BatchService.importResults(files: [JSONEncoder().encode(row)], items: [item], terminalStatus: "completed")
        #expect(result[0].state == .succeeded)
        #expect(result[0].outputText == "Unable to answer")
        #expect(result[0].error == nil)
    }

    @Test("Download failure preserves completion and retries import after a new client starts")
    func recoverResultDownload() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        let item = batchInput(), job = try await service.submit(target: batchTarget(), items: [item])
        try await server.configure(status: "completed", output: batchResult(item, answer: "Recovered"), downloadFailures: 1)
        await #expect(throws: URLError.self) { try await service.refresh(job.id) }
        let saved = try #require(store.loadJobs().first)
        #expect(saved.remoteStatus?.rawValue == "completed")
        #expect(!saved.resultsImported)
        #expect(saved.lastError != nil)
        let restored = batchService(store: BatchJobStore(directory: directory), server: server)
        let imported = try await restored.refresh(job.id)
        #expect(imported.resultsImported)
        #expect(imported.items[0].outputText == "Recovered")
        let countBefore = await server.calls().filter { $0.url?.path.hasSuffix("/content") == true }.count
        _ = try await restored.refresh(job.id)
        let countAfter = await server.calls().filter { $0.url?.path.hasSuffix("/content") == true }.count
        #expect(countAfter == countBefore)
        #expect(try store.loadJobs().first?.items.count == 1)
    }

    @Test("Lost create response is uncertain and cannot be automatically resubmitted")
    func uncertainCreation() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        await server.failCreate()
        await #expect(throws: URLError.self) { try await service.submit(target: batchTarget(), items: [batchInput()]) }
        let saved = try #require(store.loadJobs().first)
        #expect(saved.submissionState == .uncertain)
        #expect(saved.inputFileID == "file_input")
        await #expect(throws: BatchError.self) { try await service.refresh(saved.id) }
        let creates = await server.calls().filter { $0.url?.path == "/v1/batches" && $0.httpMethod == "POST" }
        #expect(creates.count == 1)
        let recovered = try await service.recoverSubmission(saved.id, remoteID: "batch_fixture")
        #expect(recovered.remoteID == "batch_fixture")
        #expect(recovered.submissionState == .submitted)
    }

    @Test("Recovery refuses a remote job with a different input file")
    func recoveryMismatch() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        await server.failCreate()
        await #expect(throws: URLError.self) { try await service.submit(target: batchTarget(), items: [batchInput()]) }
        let saved = try #require(store.loadJobs().first)
        await server.recoveryInput("file_unrelated")
        await #expect(throws: BatchError.self) { try await service.recoverSubmission(saved.id, remoteID: "batch_fixture") }
        #expect(try store.loadJobs().first?.remoteID == nil)
    }

    @Test("Only failed items become a new job; the original successful result stays untouched")
    func retryFailedOnly() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        let first = batchInput("First"), second = batchInput("Second")
        let job = try await service.submit(target: batchTarget(), items: [first, second])
        try await server.configure(status: "completed", output: batchResult(first, answer: "Done"), errors: batchFailure(second))
        _ = try await service.refresh(job.id)
        let retry = try await service.retryFailedItems(job.id)
        #expect(retry.id != job.id)
        #expect(retry.items.count == 1)
        #expect(retry.items[0].sourceItemID == second.id)
        #expect(retry.items[0].id != second.id)
        let original = try #require(store.loadJobs().first { $0.id == job.id })
        #expect(original.items[0].outputText == "Done")
        #expect(original.items.count == 2)
    }

    @Test("Task persistence and export contain no API key or authorization headers")
    func credentialFreePersistence() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        let item = batchInput(), job = try await service.submit(target: batchTarget(), items: [item])
        let file = directory.appendingPathComponent("\(job.id.uuidString).json")
        let persisted = try String(contentsOf: file, encoding: .utf8)
        #expect(!persisted.contains("fixture-key"))
        #expect(!persisted.contains("Authorization"))
        let exported = try await service.exportJSONL(job.id)
        #expect(!exported.contains("fixture-key"))
        #expect(exported.contains(item.customID))
        let requests = await server.calls()
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" })
    }

    @Test("Cancelling requests the server's cancellation endpoint and preserves cancelling state")
    func cancellation() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        let job = try await service.submit(target: batchTarget(), items: [batchInput()])
        let cancelled = try await service.cancel(job.id)
        #expect(cancelled.remoteStatus?.rawValue == "cancelling")
        #expect(cancelled.remoteStatus?.isTerminal == false)
        let requests = await server.calls()
        #expect(requests.last?.url?.path == "/v1/batches/batch_fixture/cancel")
        #expect(requests.last?.httpMethod == "POST")
    }

    @Test("A completed task without any result file stays recoverable instead of marking all items failed")
    func missingResultFiles() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        let item = batchInput(), job = try await service.submit(target: batchTarget(), items: [item])
        await server.configure(status: "completed")
        await #expect(throws: BatchError.self) { try await service.refresh(job.id) }
        let saved = try #require(store.loadJobs().first)
        #expect(!saved.resultsImported)
        #expect(saved.items[0].state == .pending)
        #expect(!saved.canRetryFailedItems)
        try await server.configure(status: "completed", output: batchResult(item, answer: "Later"))
        let recovered = try await service.refresh(job.id)
        #expect(recovered.items[0].outputText == "Later")
    }

    @Test("Corrupt persisted jobs fail visibly rather than appearing as an empty history")
    func corruptPersistence() throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("broken.json"))
        #expect(throws: (any Error).self) { try store.loadJobs() }
    }

    @Test("Failure to persist submission intent prevents every network operation")
    func writeAheadPersistence() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file cannot act as the task directory, exercising an actual filesystem failure.
        try Data("occupied".utf8).write(to: directory)
        let server = BatchFixtureServer(), service = batchService(store: store, server: server)
        await #expect(throws: (any Error).self) { try await service.submit(target: batchTarget(), items: [batchInput()]) }
        #expect(await server.calls().isEmpty)
    }

    @Test("A suspended refresh prevents concurrent refresh or cancellation from overwriting the job")
    func concurrentOperations() async throws {
        let (store, directory) = batchStore(); defer { try? FileManager.default.removeItem(at: directory) }
        let server = BatchFixtureServer(), gate = BatchRefreshGate()
        var job = BatchJob(target: batchTarget(), items: [batchInput()])
        job.remoteID = "batch_fixture"
        job.submissionState = .submitted
        try store.saveJob(job)
        let service = BatchService(store: store, transport: { request, target in
            if request.httpMethod == "GET" { await gate.pause() }
            return try await server.send(request, target: target)
        }, credentials: { _ in BatchCredentials(apiKey: "fixture-key") })
        let refresh = Task { try await service.refresh(job.id) }
        await gate.waitUntilPaused()
        await #expect(throws: BatchError.self) { try await service.refresh(job.id) }
        await #expect(throws: BatchError.self) { try await service.cancel(job.id) }
        await gate.release()
        let refreshed = try await refresh.value
        #expect(refreshed.remoteStatus?.rawValue == "in_progress")
        #expect(await server.calls().count == 1)
    }
}
