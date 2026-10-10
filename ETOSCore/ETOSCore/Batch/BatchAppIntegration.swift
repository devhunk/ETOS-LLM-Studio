import Foundation
import Combine
import CryptoKit

public extension BatchService {
    static let shared = BatchService(
        store: BatchDatabaseJobStore(),
        transport: { request, target in
            let provider = try BatchRequestPreparation.resolveProvider(target)
            // Use the same proxy and connection-security policy as ordinary model requests.
            return try await ChatService.shared.fetchData(for: request, provider: provider)
        },
        credentials: { target in
            let provider = try BatchRequestPreparation.resolveProvider(target)
            guard let key = provider.apiKeys.first(where: {
                BatchRequestPreparation.credentialReference($0, headerOverrides: provider.headerOverrides) == target.credentialReference
            }) else { throw BatchError.missingCredentials }
            return BatchCredentials(apiKey: key, headerOverrides: provider.headerOverrides)
        }
    )
}

enum BatchRequestPreparation {
    static func credentialReference(_ key: String, headerOverrides: [String: String] = [:]) -> String {
        // Project/organization headers are part of the account binding, without persisting their values.
        var data = Data(key.utf8)
        data.append(0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let headers = try? encoder.encode(headerOverrides) { data.append(headers) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resolveProvider(_ target: BatchTarget) throws -> Provider {
        guard let provider = ChatService.shared.providersSubject.value.first(where: { $0.id == target.providerID }) else {
            throw BatchError.missingCredentials
        }
        guard URL(string: provider.baseURL) == target.baseURL else { throw BatchError.changedProvider }
        return provider
    }

    static func supports(_ model: RunnableModel) -> Bool {
        guard model.model.kind == .chat, model.effectiveAPIFormat == "openai-compatible",
              model.provider.normalizedChatEndpointPath == Provider.defaultChatEndpointPath,
              let url = URL(string: model.provider.baseURL), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let overrides = model.effectiveOverrideParameters.mapValues { $0.toAny() }
        switch OpenAIAdapter().resolvedConversationAPI(for: overrides) {
        case .chatCompletions: return true
        case .responses: return false
        }
    }

    static func prepare(model: RunnableModel, prompts: [String], systemPrompt: String,
                        allowCompatibleProvider: Bool) throws -> (BatchTarget, [BatchItem]) {
        guard supports(model), let baseURL = URL(string: model.provider.baseURL),
              baseURL.host?.lowercased() == "api.openai.com" || allowCompatibleProvider else {
            throw BatchError.unsupportedProvider
        }
        guard let key = model.provider.apiKeys.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BatchError.missingCredentials
        }
        let adapter = OpenAIAdapter()
        var items: [BatchItem] = []
        var requestModelName: String?
        for prompt in prompts {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BatchError.invalidInput(NSLocalizedString("问题不能为空。", comment: "Batch empty prompt"))
            }
            var messages: [ChatMessage] = []
            if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(ChatMessage(role: .system, content: systemPrompt))
            }
            messages.append(ChatMessage(role: .user, content: prompt))
            guard let request = adapter.buildChatRequest(
                for: model,
                commonPayload: ["stream": false, providerAPIKeyControlKey: key, requestLogSuppressionControlKey: true],
                messages: messages, tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]
            ), let data = request.httpBody,
                  case .dictionary(let body) = try JSONDecoder().decode(JSONValue.self, from: data),
                  case .string(let name) = body["model"] else {
                throw BatchError.invalidInput(NSLocalizedString("无法构建批量请求。", comment: "Batch build request failed"))
            }
            if let previous = requestModelName, previous != name { throw BatchError.unsupportedProvider }
            requestModelName = name
            items.append(BatchItem(body: .dictionary(body)))
        }
        guard let name = requestModelName else {
            throw BatchError.invalidInput(NSLocalizedString("请至少输入一个问题。", comment: "Batch missing prompts"))
        }
        let target = BatchTarget(providerID: model.provider.id, providerName: model.provider.name,
                                 modelID: model.model.id, modelName: name, baseURL: baseURL,
                                 credentialReference: credentialReference(key, headerOverrides: model.provider.headerOverrides))
        return (target, try BatchService.normalizedItems(items, target: target))
    }
}

@MainActor
public final class BatchTaskViewModel: ObservableObject {
    @Published public private(set) var jobs: [BatchJob] = []
    @Published public private(set) var models: [RunnableModel] = []
    @Published public private(set) var isBusy = false
    @Published public var errorMessage: String?
    private let service: BatchService

    public init(service: BatchService = .shared) { self.service = service }

    public func reload() async {
        models = ChatService.shared.providersSubject.value.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }.filter(BatchRequestPreparation.supports)
        do { jobs = try await service.jobs() } catch { errorMessage = error.localizedDescription }
    }
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
            await reload()
            return true
        } catch {
            await reload()
            errorMessage = error.localizedDescription
            return false
        }
    }
    public func submit(model: RunnableModel, prompts: [String], systemPrompt: String, allowCompatibleProvider: Bool) async -> Bool {
        await perform {
            let (target, items) = try BatchRequestPreparation.prepare(model: model, prompts: prompts,
                                                                     systemPrompt: systemPrompt,
                                                                     allowCompatibleProvider: allowCompatibleProvider)
            _ = try await service.submit(target: target, items: items)
        }
    }
    public func refresh(_ id: UUID) async { _ = await perform { _ = try await service.refresh(id) } }
    public func refreshAll() async {
        _ = await perform {
            let current = try await service.jobs()
            var firstError: Error?
            for job in current where job.remoteID != nil && !job.resultsImported {
                do { _ = try await service.refresh(job.id) } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
    public func cancel(_ id: UUID) async { _ = await perform { _ = try await service.cancel(id) } }
    public func retryFailed(_ id: UUID) async { _ = await perform { _ = try await service.retryFailedItems(id) } }
    public func recover(_ id: UUID, remoteID: String) async {
        _ = await perform { _ = try await service.recoverSubmission(id, remoteID: remoteID.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    public func export(_ id: UUID) async throws -> String { try await service.exportJSONL(id) }
}
