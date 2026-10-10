import Foundation

public enum BatchSubmissionState: String, Codable, Sendable {
    case preparing, uploaded, submitting, submitted, uncertain, failed
}

/// Preserve the server's raw status, including future states, instead of treating them as failures.
public struct BatchRemoteStatus: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var isTerminal: Bool {
        ["completed", "failed", "expired", "cancelled"].contains(rawValue)
    }
}

public enum BatchItemState: String, Codable, Sendable {
    case pending, succeeded, failed
}

/// No API keys or authentication headers are stored with a job.
public struct BatchTarget: Codable, Hashable, Sendable {
    public let providerID: UUID
    public let providerName: String
    public let modelID: UUID
    public let modelName: String
    public let baseURL: URL
    public let credentialReference: String
    public let endpoint: String

    public init(providerID: UUID, providerName: String, modelID: UUID, modelName: String,
                baseURL: URL, credentialReference: String, endpoint: String = "/v1/chat/completions") {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.modelName = modelName
        self.baseURL = baseURL
        self.credentialReference = credentialReference
        self.endpoint = endpoint
    }
}

public struct BatchItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sourceItemID: UUID?
    public let body: JSONValue
    public var state: BatchItemState = .pending
    public var response: JSONValue?
    public var error: String?
    public var outputText: String?

    public init(id: UUID = UUID(), sourceItemID: UUID? = nil, body: JSONValue) {
        self.id = id
        self.sourceItemID = sourceItemID
        self.body = body
    }
    public var customID: String { id.uuidString }
    public var prompt: String {
        guard case .dictionary(let body) = body,
              case .array(let messages) = body["messages"] else { return "" }
        return messages.compactMap { message in
            guard case .dictionary(let fields) = message,
                  case .string(let content) = fields["content"] else { return nil }
            return content
        }.joined(separator: "\n\n")
    }
    public var usage: JSONValue? {
        guard case .dictionary(let fields) = response else { return nil }
        return fields["usage"]
    }
}

public struct BatchJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let target: BatchTarget
    public var items: [BatchItem]
    public var submissionState: BatchSubmissionState = .preparing
    public var remoteID: String?
    public var remoteStatus: BatchRemoteStatus?
    public var inputFileID: String?
    public var outputFileID: String?
    public var errorFileID: String?
    public var serverCompletedCount: Int = 0
    public var serverFailedCount: Int = 0
    public var resultsImported: Bool = false
    public var lastError: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), target: BatchTarget, items: [BatchItem], createdAt: Date = Date()) {
        self.id = id
        self.target = target
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
    public var succeededCount: Int { items.filter { $0.state == .succeeded }.count }
    public var failedCount: Int { items.filter { $0.state == .failed }.count }
    public var canRetryFailedItems: Bool {
        remoteStatus?.isTerminal == true && resultsImported && failedCount > 0
    }
}

public enum BatchError: LocalizedError {
    case invalidInput(String), unsupportedProvider, missingCredentials, changedProvider
    case missingJob, busy, invalidResponse(String), persistence(String), uncertainSubmission

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let reason), .invalidResponse(let reason), .persistence(let reason): return reason
        case .unsupportedProvider:
            return NSLocalizedString("此提供商或模型不支持当前的 OpenAI Batch 文本聊天格式。", comment: "Batch unsupported provider")
        case .missingCredentials:
            return NSLocalizedString("批量任务使用的 API Key 或请求头配置已改变，请恢复原账号的凭据与配置。", comment: "Batch missing credential")
        case .changedProvider:
            return NSLocalizedString("提供商地址已改变，请恢复提交任务时使用的地址后再查询。", comment: "Batch changed provider")
        case .missingJob: return NSLocalizedString("找不到批量任务。", comment: "Batch job missing")
        case .busy: return NSLocalizedString("此批量任务正在处理中。", comment: "Batch busy")
        case .uncertainSubmission:
            return NSLocalizedString("提交结果尚不确定，请先在厂商控制台确认任务，避免重复提交计费。", comment: "Batch uncertain submission")
        }
    }
}
