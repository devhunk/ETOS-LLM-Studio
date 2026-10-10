import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BatchCredentials: Sendable {
    public let apiKey: String
    public let headerOverrides: [String: String]
    public init(apiKey: String, headerOverrides: [String: String] = [:]) {
        self.apiKey = apiKey
        self.headerOverrides = headerOverrides
    }
}

public struct BatchRemoteJob: Decodable, Sendable {
    public let id: String
    public let status: String
    public let input_file_id: String?
    public let endpoint: String?
    public let output_file_id: String?
    public let error_file_id: String?
    public let request_counts: Counts?
    public let errors: JSONValue?
    public struct Counts: Decodable, Sendable {
        public let completed: Int
        public let failed: Int
    }
}

public protocol BatchAPIAdapter: Sendable {
    func uploadRequest(target: BatchTarget, credentials: BatchCredentials, jsonl: Data) throws -> URLRequest
    func createRequest(target: BatchTarget, credentials: BatchCredentials, fileID: String) throws -> URLRequest
    func statusRequest(target: BatchTarget, credentials: BatchCredentials, remoteID: String) throws -> URLRequest
    func cancelRequest(target: BatchTarget, credentials: BatchCredentials, remoteID: String) throws -> URLRequest
    func downloadRequest(target: BatchTarget, credentials: BatchCredentials, fileID: String) throws -> URLRequest
}

public struct OpenAIBatchAdapter: BatchAPIAdapter {
    public init() {}

    private func request(target: BatchTarget, credentials: BatchCredentials, path: String, method: String) throws -> URLRequest {
        guard target.baseURL.scheme?.lowercased() == "https", target.baseURL.host != nil,
              target.baseURL.user == nil, target.baseURL.password == nil,
              target.baseURL.query == nil, target.baseURL.fragment == nil,
              !credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchError.unsupportedProvider
        }
        var request = URLRequest(url: target.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 300
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        for (name, value) in credentials.headerOverrides {
            // Content headers are set by this adapter, not copied from a chat request.
            if ["content-type", "content-length"].contains(name.lowercased()) { continue }
            request.setValue(value.replacingOccurrences(of: "{api_key}", with: credentials.apiKey), forHTTPHeaderField: name)
        }
        return request
    }

    public func uploadRequest(target: BatchTarget, credentials: BatchCredentials, jsonl: Data) throws -> URLRequest {
        var req = try request(target: target, credentials: credentials, path: "files", method: "POST")
        let boundary = "Batch-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\nbatch\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"batch.jsonl\"\r\nContent-Type: application/jsonl\r\n\r\n".utf8)
        data.append(jsonl)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = data
        return req
    }

    public func createRequest(target: BatchTarget, credentials: BatchCredentials, fileID: String) throws -> URLRequest {
        var req = try request(target: target, credentials: credentials, path: "batches", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "input_file_id": fileID, "endpoint": target.endpoint, "completion_window": "24h"
        ])
        return req
    }

    private func safeID(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw BatchError.invalidResponse(NSLocalizedString("厂商返回了无效的任务或文件编号。", comment: "Batch invalid remote identifier"))
        }
        return value
    }
    public func statusRequest(target: BatchTarget, credentials: BatchCredentials, remoteID: String) throws -> URLRequest {
        try request(target: target, credentials: credentials, path: "batches/\(safeID(remoteID))", method: "GET")
    }
    public func cancelRequest(target: BatchTarget, credentials: BatchCredentials, remoteID: String) throws -> URLRequest {
        try request(target: target, credentials: credentials, path: "batches/\(safeID(remoteID))/cancel", method: "POST")
    }
    public func downloadRequest(target: BatchTarget, credentials: BatchCredentials, fileID: String) throws -> URLRequest {
        try request(target: target, credentials: credentials, path: "files/\(safeID(fileID))/content", method: "GET")
    }
}
