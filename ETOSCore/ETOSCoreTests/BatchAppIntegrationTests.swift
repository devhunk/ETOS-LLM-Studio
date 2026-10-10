import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("Batch application integration")
struct BatchAppIntegrationTests {
    private func model(format: String = "openai-compatible", baseURL: String = "https://api.openai.com/v1") -> RunnableModel {
        let definition = Model(modelName: "gpt-fixture", displayName: "Fixture", isActivated: true)
        let provider = Provider(name: "Fixture", baseURL: baseURL, apiKeys: ["fixture-primary", "fixture-secondary"],
                                apiFormat: format, models: [definition])
        return RunnableModel(provider: provider, model: definition)
    }

    @Test("Preparation freezes the first credential and preserves separate prompts with shared context")
    func prepareRequests() throws {
        let source = model()
        let (target, items) = try BatchRequestPreparation.prepare(model: source, prompts: ["First", "Second"],
                                                                systemPrompt: "Common context", allowCompatibleProvider: false)
        #expect(target.credentialReference == BatchRequestPreparation.credentialReference("fixture-primary"))
        #expect(items.count == 2)
        #expect(items[0].prompt == "Common context\n\nFirst")
        #expect(items[1].prompt == "Common context\n\nSecond")
        for item in items {
            guard case .dictionary(let body) = item.body else { Issue.record("Missing request body"); return }
            #expect(body["stream"] == .bool(false))
            #expect(body[providerAPIKeyControlKey] == nil)
            #expect(!item.body.prettyPrintedCompact().contains("fixture-primary"))
        }
    }

    @Test("Compatible chat services require explicit Batch opt-in; unrelated formats remain unsupported")
    func compatibility() throws {
        let compatible = model(baseURL: "https://compatible.example/v1")
        #expect(throws: BatchError.self) {
            try BatchRequestPreparation.prepare(model: compatible, prompts: ["Question"], systemPrompt: "", allowCompatibleProvider: false)
        }
        let (target, _) = try BatchRequestPreparation.prepare(model: compatible, prompts: ["Question"], systemPrompt: "", allowCompatibleProvider: true)
        #expect(target.baseURL.host == "compatible.example")
        for format in ["anthropic", "gemini", "openai-responses"] {
            #expect(!BatchRequestPreparation.supports(model(format: format)))
        }
        var provider = compatible.provider
        provider.models[0].apiFormatOverride = "anthropic"
        #expect(!BatchRequestPreparation.supports(RunnableModel(provider: provider, model: provider.models[0])))
    }

    @Test("Responses-mode overrides cannot be mislabeled as Chat Completions batches")
    func endpointMode() {
        var source = model()
        var provider = source.provider
        provider.models[0].overrideParameters["use_responses_api"] = .bool(true)
        source = RunnableModel(provider: provider, model: provider.models[0])
        #expect(!BatchRequestPreparation.supports(source))
    }

    @Test("Credential references change when the project or authentication headers change")
    func projectBinding() {
        let original = BatchRequestPreparation.credentialReference("fixture", headerOverrides: ["OpenAI-Project": "original"])
        let changed = BatchRequestPreparation.credentialReference("fixture", headerOverrides: ["OpenAI-Project": "changed"])
        #expect(original != changed)
        #expect(original.count == 64)
        #expect(!original.contains("fixture"))
    }

    @Test("Config database upserts are idempotent and reopen with complete result snapshots")
    func databaseStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("batch-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("config-store.sqlite")
        let database = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "BatchTests")
        let store = BatchDatabaseJobStore(store: database)
        let (target, items) = try BatchRequestPreparation.prepare(model: model(), prompts: ["Question"], systemPrompt: "", allowCompatibleProvider: false)
        var job = BatchJob(target: target, items: items)
        try store.saveJob(job)
        job.remoteID = "batch-fixture"
        job.remoteStatus = BatchRemoteStatus(rawValue: "completed")
        job.items[0].state = .succeeded
        job.items[0].outputText = "Answer"
        job.resultsImported = true
        try store.saveJob(job)
        try store.saveJob(job)
        let reopened = BatchDatabaseJobStore(store: try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "BatchTestsReopen"))
        let rows = try reopened.loadJobs()
        #expect(rows.count == 1)
        #expect(rows.first?.remoteID == job.remoteID)
        #expect(rows.first?.items[0].outputText == "Answer")
        let data = try database.read { db in try #require(Data.fetchOne(db, sql: "SELECT json_data FROM json_blobs WHERE key LIKE 'batch.job.%'")) }
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-primary"))
    }
}
