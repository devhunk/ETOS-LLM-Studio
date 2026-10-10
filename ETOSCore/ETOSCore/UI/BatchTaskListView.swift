import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

@MainActor
public struct BatchTaskListView: View {
    @StateObject private var model = BatchTaskViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsCreation = false
    private let allowsCreation: Bool

    public init(allowsCreation: Bool = true) { self.allowsCreation = allowsCreation }

    public var body: some View {
        List {
            Section {
                Text(NSLocalizedString("任务在厂商服务器执行，离开页面后仍可继续。重新打开时刷新状态。", comment: "Batch remote execution explanation"))
                    .font(.footnote).foregroundStyle(.secondary)
                #if os(watchOS)
                Text(NSLocalizedString("请在 iPhone 创建批量任务，并同步配置数据库后在此查看。", comment: "Batch watch synced tasks explanation"))
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            }
            if model.jobs.isEmpty {
                Text(NSLocalizedString("暂无批量任务", comment: "Batch empty list"))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.jobs) { job in
                NavigationLink {
                    BatchTaskDetailView(id: job.id, model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.target.modelName).font(.headline)
                        Text(job.target.providerName).font(.caption).foregroundStyle(.secondary)
                        Text(BatchTaskPresentation.status(job)).font(.caption)
                        Text("\(job.serverCompletedCount + job.serverFailedCount) / \(job.items.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(job.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(NSLocalizedString("批量任务", comment: "Batch task list title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button { Task { await model.refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(NSLocalizedString("刷新批量任务", comment: "Batch refresh accessibility"))
                    .disabled(model.isBusy)
                    #if os(iOS)
                    if allowsCreation {
                        Button { showsCreation = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel(NSLocalizedString("创建批量任务", comment: "Batch create accessibility"))
                            .disabled(model.isBusy)
                    }
                    #endif
                }
            }
        }
        .task { await model.reload(); await model.refreshAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.reload(); await model.refreshAll() } }
        }
        #if os(iOS)
        .sheet(isPresented: $showsCreation) {
            NavigationStack { BatchTaskCreationView(model: model) }
                .interactiveDismissDisabled(model.isBusy)
        }
        #endif
    }
}

enum BatchTaskPresentation {
    static func status(_ job: BatchJob) -> String {
        if job.resultsImported { return NSLocalizedString("结果已保存", comment: "Batch results imported") }
        if let status = job.remoteStatus {
            switch status.rawValue {
            case "validating": return NSLocalizedString("正在校验", comment: "Batch validating")
            case "in_progress": return NSLocalizedString("正在处理", comment: "Batch in progress")
            case "finalizing": return NSLocalizedString("正在整理结果", comment: "Batch finalizing")
            case "completed": return NSLocalizedString("已完成，等待下载结果", comment: "Batch completed awaiting import")
            case "failed": return NSLocalizedString("任务失败", comment: "Batch failed")
            case "expired": return NSLocalizedString("任务已过期", comment: "Batch expired")
            case "cancelling": return NSLocalizedString("正在取消", comment: "Batch cancelling")
            case "cancelled": return NSLocalizedString("任务已取消", comment: "Batch cancelled")
            default: return status.rawValue
            }
        }
        switch job.submissionState {
        case .preparing: return NSLocalizedString("准备上传", comment: "Batch preparing")
        case .uploaded: return NSLocalizedString("输入文件已上传", comment: "Batch uploaded")
        case .submitting, .uncertain: return NSLocalizedString("请确认远端提交结果", comment: "Batch submission uncertain")
        case .submitted: return NSLocalizedString("已提交", comment: "Batch submitted")
        case .failed: return NSLocalizedString("提交失败", comment: "Batch submission failed")
        }
    }
}

@MainActor
private struct BatchTaskDetailView: View {
    let id: UUID
    @ObservedObject var model: BatchTaskViewModel
    @State private var confirmsCancel = false
    @State private var confirmsRetry = false
    @State private var recoveryID = ""
    #if os(iOS)
    @State private var exportDocument: BatchResultDocument?
    @State private var showsExporter = false
    #endif
    private var job: BatchJob? { model.jobs.first { $0.id == id } }

    var body: some View {
        List {
            if let job {
                Section(NSLocalizedString("任务状态", comment: "Batch status section")) {
                    Text(job.target.providerName)
                    Text(job.target.modelName)
                    Text(BatchTaskPresentation.status(job))
                    if let remoteID = job.remoteID { Text(remoteID).font(.caption).batchTextSelection() }
                    Text(String(format: NSLocalizedString("成功 %d · 失败 %d · 总计 %d", comment: "Batch result counts"),
                                job.succeededCount, job.failedCount, job.items.count))
                    if let error = job.lastError { Text(error).foregroundStyle(.red) }
                }
                Section {
                    if job.remoteID != nil {
                        Button(NSLocalizedString("刷新状态与结果", comment: "Batch refresh details")) {
                            Task { await model.refresh(id) }
                        }
                        #if os(iOS)
                        if job.remoteStatus?.isTerminal != true {
                            Button(NSLocalizedString("取消远端任务", comment: "Batch cancel task"), role: .destructive) {
                                confirmsCancel = true
                            }
                        }
                        #endif
                    }
                    #if os(iOS)
                    if job.canRetryFailedItems {
                        Button(NSLocalizedString("仅重试失败项", comment: "Batch retry failed items")) { confirmsRetry = true }
                    }
                    if job.resultsImported {
                        Button(NSLocalizedString("导出结果 JSONL", comment: "Batch export results")) {
                            Task {
                                do {
                                    exportDocument = BatchResultDocument(text: try await model.export(id))
                                    showsExporter = true
                                } catch { model.errorMessage = error.localizedDescription }
                            }
                        }
                    }
                    #endif
                }.disabled(model.isBusy)
                #if os(iOS)
                if job.remoteID == nil && [.uncertain, .submitting].contains(job.submissionState) {
                    Section(NSLocalizedString("恢复远端任务", comment: "Batch recover section")) {
                        Text(NSLocalizedString("请在厂商控制台核对提交结果，并填入对应任务编号。此操作不会重新提交请求。", comment: "Batch recovery explanation"))
                            .font(.footnote)
                        TextField("batch_…", text: $recoveryID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(NSLocalizedString("关联远端任务", comment: "Batch attach remote task")) {
                            Task { await model.recover(id, remoteID: recoveryID) }
                        }.disabled(model.isBusy || recoveryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                #endif
                if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                Section(NSLocalizedString("请求与结果", comment: "Batch results section")) {
                    ForEach(job.items) { item in
                        NavigationLink {
                            List {
                                Section(NSLocalizedString("输入", comment: "Batch item input")) {
                                    Text(item.prompt).batchTextSelection()
                                }
                                if let output = item.outputText {
                                    Section(NSLocalizedString("回答", comment: "Batch item output")) {
                                        Text(output).batchTextSelection()
                                    }
                                }
                                if let error = item.error { Section { Text(error).foregroundStyle(.red).batchTextSelection() } }
                                if let usage = item.usage {
                                    Section(NSLocalizedString("用量", comment: "Batch item usage")) {
                                        Text(usage.prettyPrintedCompact()).font(.caption).batchTextSelection()
                                    }
                                }
                            }
                            .navigationTitle(NSLocalizedString("请求详情", comment: "Batch item details title"))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.prompt).lineLimit(2)
                                Text(item.state == .succeeded ? NSLocalizedString("成功", comment: "Batch item succeeded") :
                                     item.state == .failed ? NSLocalizedString("失败", comment: "Batch item failed") :
                                     NSLocalizedString("等待结果", comment: "Batch item pending"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("批量任务详情", comment: "Batch job details title"))
        .confirmationDialog(NSLocalizedString("确认取消远端任务？", comment: "Batch cancel confirmation"), isPresented: $confirmsCancel) {
            Button(NSLocalizedString("取消远端任务", comment: "Batch cancel task"), role: .destructive) { Task { await model.cancel(id) } }
        } message: {
            Text(NSLocalizedString("厂商可能仍会收取已完成请求的费用。", comment: "Batch cancellation billing note"))
        }
        .confirmationDialog(NSLocalizedString("提交失败项为新任务？", comment: "Batch retry confirmation"), isPresented: $confirmsRetry) {
            Button(NSLocalizedString("提交新任务", comment: "Batch retry submit")) { Task { await model.retryFailed(id) } }
        } message: {
            Text(NSLocalizedString("仅重新提交失败请求，新任务将产生相应费用。", comment: "Batch retry billing note"))
        }
        #if os(iOS)
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .plainText,
                      defaultFilename: "batch-\(id.uuidString).jsonl") { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        #endif
    }
}

private extension View {
    @ViewBuilder
    func batchTextSelection() -> some View {
        #if os(iOS) || os(macOS)
        self.textSelection(.enabled)
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct BatchResultDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

@MainActor
private struct BatchTaskCreationView: View {
    @ObservedObject var model: BatchTaskViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedModelID = ""
    @State private var questions = ""
    @State private var systemPrompt = ""
    @State private var confirmsCompatibility = false
    @State private var showsImporter = false
    @State private var showsPreview = false
    private var selectedModel: RunnableModel? { model.models.first { $0.id == selectedModelID } }
    private var prompts: [String] {
        questions.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var isOfficial: Bool { URL(string: selectedModel?.provider.baseURL ?? "")?.host?.lowercased() == "api.openai.com" }

    var body: some View {
        Form {
            Section(NSLocalizedString("模型", comment: "Batch creation model section")) {
                Picker(NSLocalizedString("选择模型", comment: "Batch model picker"), selection: $selectedModelID) {
                    ForEach(model.models) { item in
                        Text("\(item.provider.name) · \(item.model.displayName)").tag(item.id)
                    }
                }
                Text(NSLocalizedString("首版支持 OpenAI Chat Completions 文本批量请求，不包含连续工具调用。", comment: "Batch MVP capabilities"))
                    .font(.footnote).foregroundStyle(.secondary)
                if !isOfficial {
                    Toggle(NSLocalizedString("已确认此服务支持 OpenAI Batch API", comment: "Batch compatible provider opt in"), isOn: $confirmsCompatibility)
                    Text(NSLocalizedString("兼容聊天接口并不代表支持 Batch，请先核对服务商文档。", comment: "Batch compatibility explanation"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section(NSLocalizedString("公共系统提示词（可选）", comment: "Batch shared system prompt")) {
                TextEditor(text: $systemPrompt).frame(minHeight: 80)
            }
            Section(NSLocalizedString("独立问题", comment: "Batch questions section")) {
                Text(NSLocalizedString("每个问题之间留一个空行；单个问题内可以换行。每项请求独立执行。", comment: "Batch input format explanation"))
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $questions).frame(minHeight: 180)
                Button(NSLocalizedString("导入文本文件", comment: "Batch import questions")) { showsImporter = true }
                Text(String(format: NSLocalizedString("共 %d 条请求", comment: "Batch input count"), prompts.count))
            }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button(NSLocalizedString("预览并提交", comment: "Batch preview submit")) { showsPreview = true }
                    .disabled(model.isBusy || selectedModel == nil || prompts.isEmpty || prompts.count > 50_000 || (!isOfficial && !confirmsCompatibility))
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(NSLocalizedString("创建批量任务", comment: "Batch create title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("关闭", comment: "Batch close creation")) { dismiss() }.disabled(model.isBusy)
            }
        }
        .onAppear { if selectedModelID.isEmpty { selectedModelID = model.models.first?.id ?? "" } }
        .onChange(of: selectedModelID) { _, _ in confirmsCompatibility = false }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5_000_000 else { throw BatchError.invalidInput(NSLocalizedString("导入文本不能超过 5 MB。", comment: "Batch text import size")) }
                questions = try String(contentsOf: url, encoding: .utf8)
            } catch { model.errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $showsPreview) {
            NavigationStack {
                List {
                    Section {
                        Text(selectedModel?.provider.name ?? "")
                        Text(selectedModel?.model.displayName ?? "")
                        Text(String(format: NSLocalizedString("将提交 %d 条独立请求，处理窗口为 24 小时。", comment: "Batch submit preview summary"), prompts.count))
                        Text(NSLocalizedString("提交后将由服务商处理并计费；不会包含当前聊天的历史或附件。", comment: "Batch submit preview context"))
                            .font(.footnote)
                    }
                    if !systemPrompt.isEmpty { Section { Text(systemPrompt) } }
                    ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                        Section("\(index + 1)") { Text(prompt) }
                    }
                    if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                }
                .navigationTitle(NSLocalizedString("提交预览", comment: "Batch preview title"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("返回编辑", comment: "Batch return to edit")) { showsPreview = false }.disabled(model.isBusy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("提交", comment: "Batch confirm submit")) {
                            guard let selectedModel else { return }
                            Task {
                                if await model.submit(model: selectedModel, prompts: prompts, systemPrompt: systemPrompt,
                                                      allowCompatibleProvider: confirmsCompatibility) {
                                    showsPreview = false
                                    dismiss()
                                }
                            }
                        }.disabled(model.isBusy)
                    }
                }
                .overlay { if model.isBusy { ProgressView() } }
            }.interactiveDismissDisabled(model.isBusy)
        }
    }
}
#endif
