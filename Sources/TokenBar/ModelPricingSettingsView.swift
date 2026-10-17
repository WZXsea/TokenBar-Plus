import Foundation
import SwiftUI
import TokenBarCore

struct ModelPricingSettingsView: View {
    @Bindable private var store: ModelPricingStore
    let quoteService: (any ModelPriceQuoting)?
    let observedModels: [ObservedPricingModel]

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ModelPricingDraft()
    @State private var operationError: String?
    @State private var statusMessage: String?
    @State private var quoteNonce = UUID()
    @State private var quoteTask: Task<Void, Never>?
    @State private var isLoadingQuote = false

    init(
        store: ModelPricingStore,
        quoteService: (any ModelPriceQuoting)? = nil,
        observedModels: [ObservedPricingModel] = [])
    {
        self.store = store
        self.quoteService = quoteService
        self.observedModels = observedModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("模型单价")
                    .font(.title2)
                Spacer()
                Text("USD／百万 token")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    self.savedRulesSection
                    Divider()
                    self.editorSection
                    self.explanationSection
                }
                .padding(.trailing, 4)
            }

            if let error = self.operationError ?? self.store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityLabel("操作错误：\(error)")
            } else if let message = self.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Button("恢复自动价格") {
                    self.restoreAutomaticPrices()
                }
                .disabled(self.store.overrides.isEmpty && self.store.errorMessage == nil)
                .help("清空自定义规则，使用自动价格。")
                Spacer()
                Button("关闭") {
                    self.dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 660)
        .onDisappear {
            self.invalidateQuote()
        }
    }

    private var savedRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已保存规则（\(self.store.overrides.count)）")
                    .font(.headline)
                Spacer()
                Button("新增规则") {
                    self.beginNewRule()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            if self.store.overrides.isEmpty {
                Text("当前使用自动价格。可在下方填写模型单价并保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(self.store.overrides) { rule in
                            self.savedRuleRow(rule)
                            if rule.id != self.store.overrides.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(self.store.overrides.count) * 69, 156))
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func savedRuleRow(_ rule: ModelPriceOverride) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "启用",
                isOn: Binding(
                    get: { rule.enabled },
                    set: { self.setEnabled(rule, isEnabled: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("启用 \(rule.platform.displayName) 的 \(rule.modelID) \(rule.serviceTier.displayName) 价格")

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.modelID)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(rule.modelID)
                Text("\(rule.platform.displayName) · \(rule.serviceTier.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("编辑") {
                self.edit(rule)
            }
            .accessibilityLabel("编辑 \(rule.modelID) 的价格规则")
            Button("移除") {
                self.remove(rule)
            }
            .accessibilityLabel("移除 \(rule.modelID) 的价格规则")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.draft.id == nil ? "新增规则" : "编辑规则")
                .font(.headline)

            HStack(spacing: 16) {
                Picker("平台", selection: self.draftBinding(\.platform)) {
                    ForEach([TokenPlatform.codex, .claude, .grok, .antigravity]) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }
                Picker("模式", selection: self.draftBinding(\.serviceTier)) {
                    ForEach(ModelPriceTier.allCases) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("模型 ID", text: self.draftBinding(\.modelID), prompt: Text("例如 gpt-5.4"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("模型 ID")
                Menu("选择已观察模型") {
                    ForEach(self.availableObservedModels) { model in
                        Button("\(model.platform.displayName) · \(model.modelID)") {
                            self.invalidateQuote()
                            self.draft.platform = model.platform
                            self.draft.modelID = model.modelID
                        }
                    }
                }
                .disabled(self.availableObservedModels.isEmpty)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    self.priceField("输入", keyPath: \.inputPerMillion)
                    self.priceField("缓存读取", keyPath: \.cachedInputPerMillion)
                }
                GridRow {
                    self.priceField("缓存写入", keyPath: \.cacheWritePerMillion)
                    self.priceField("输出", keyPath: \.outputPerMillion)
                }
            }

            HStack(spacing: 10) {
                Button("载入自动单价") {
                    self.loadAutomaticPrice()
                }
                .disabled(self.quoteService == nil || self.draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || self.isLoadingQuote)
                .help("载入所选平台及模式的短上下文自动单价；所有模式使用标准模式报价。")

                if self.isLoadingQuote {
                    ProgressView().controlSize(.small)
                    Text("正在载入…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("短上下文自动单价")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用规则", isOn: self.draftBinding(\.enabled))
                    .toggleStyle(.checkbox)
            }

            HStack {
                Text("各项请填写 0 至 1,000,000 的单价，允许 0。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存规则") {
                    self.save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func priceField(_ title: String, keyPath: WritableKeyPath<ModelPricingDraft, String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("例如 1.25", text: self.draftBinding(keyPath))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(title)单价，USD 每百万 token")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("自动价格来源：官方价格表、OpenRouter、内置备用价。报价中的空白项可手动补齐后保存。")
            Text("推理 token 按输出单价计算。自定义价格直接用于所选模式的全部上下文长度。服务商记录的原始金额保留。")
            Text("保存后重新计算本机使用记录的预估费用。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var availableObservedModels: [ObservedPricingModel] {
        let platforms: Set<TokenPlatform> = [.codex, .claude, .grok, .antigravity]
        var seen: Set<String> = []
        return self.observedModels.filter {
            platforms.contains($0.platform) && seen.insert($0.id).inserted
        }.sorted {
            if $0.platform.rawValue != $1.platform.rawValue {
                return $0.platform.rawValue < $1.platform.rawValue
            }
            return $0.modelID.localizedStandardCompare($1.modelID) == .orderedAscending
        }
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<ModelPricingDraft, Value>) -> Binding<Value> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: {
                self.invalidateQuote()
                self.draft[keyPath: keyPath] = $0
                self.operationError = nil
                self.statusMessage = nil
            })
    }

    private func beginNewRule() {
        self.invalidateQuote()
        self.draft = ModelPricingDraft()
        self.operationError = nil
        self.statusMessage = nil
    }

    private func edit(_ rule: ModelPriceOverride) {
        self.invalidateQuote()
        self.draft = ModelPricingDraft(rule: rule)
        self.operationError = nil
        self.statusMessage = nil
    }

    private func save() {
        do {
            let rule = try self.draft.validatedRule()
            try self.store.upsert(rule)
            self.invalidateQuote()
            self.draft = ModelPricingDraft(rule: rule)
            self.operationError = nil
            self.statusMessage = "价格规则已保存。"
        } catch {
            self.operationError = error.localizedDescription
            self.statusMessage = nil
        }
    }

    private func setEnabled(_ rule: ModelPriceOverride, isEnabled: Bool) {
        do {
            try self.store.setEnabled(rule.id, isEnabled: isEnabled)
            if self.draft.id == rule.id {
                self.invalidateQuote()
                self.draft.enabled = isEnabled
            }
            self.operationError = nil
            self.statusMessage = isEnabled ? "价格规则已启用。" : "价格规则已停用。"
        } catch {
            self.operationError = error.localizedDescription
        }
    }

    private func remove(_ rule: ModelPriceOverride) {
        do {
            try self.store.remove(rule.id)
            if self.draft.id == rule.id {
                self.invalidateQuote()
                self.draft.id = nil
            }
            self.operationError = nil
            self.statusMessage = "价格规则已移除。"
        } catch {
            self.operationError = error.localizedDescription
        }
    }

    private func restoreAutomaticPrices() {
        do {
            try self.store.removeAll()
            self.invalidateQuote()
            self.draft = ModelPricingDraft()
            self.operationError = nil
            self.statusMessage = "已清空自定义规则，恢复自动价格。"
        } catch {
            self.operationError = error.localizedDescription
        }
    }

    private func invalidateQuote() {
        self.quoteTask?.cancel()
        self.quoteTask = nil
        self.quoteNonce = UUID()
        self.isLoadingQuote = false
    }

    private func loadAutomaticPrice() {
        guard let quoteService = self.quoteService else { return }
        self.invalidateQuote()
        let requestedDraft = self.draft
        let nonce = self.quoteNonce
        let modelID = requestedDraft.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }
        let tier = requestedDraft.serviceTier == .any ? ModelPriceTier.standard : requestedDraft.serviceTier
        self.operationError = nil
        self.statusMessage = nil
        self.isLoadingQuote = true
        self.quoteTask = Task { @MainActor in
            do {
                let quote = try await quoteService.quote(
                    platform: requestedDraft.platform,
                    modelID: modelID,
                    tier: tier)
                guard !Task.isCancelled, self.quoteNonce == nonce, self.draft == requestedDraft else { return }
                self.isLoadingQuote = false
                self.quoteTask = nil
                self.operationError = nil
                let rates = quote.rates
                self.draft.inputPerMillion = Self.priceDraft(rates?.inputPerMillion)
                self.draft.cachedInputPerMillion = Self.priceDraft(rates?.cachedInputPerMillion)
                self.draft.cacheWritePerMillion = Self.priceDraft(rates?.cacheWritePerMillion)
                self.draft.outputPerMillion = Self.priceDraft(rates?.outputPerMillion)
                self.statusMessage = rates == nil
                    ? "当前模型的自动单价待补充，可手动填写四项单价。"
                    : "已载入短上下文自动单价。请核对并补齐空白项后保存。"
            } catch is CancellationError {
                if self.quoteNonce == nonce {
                    self.isLoadingQuote = false
                    self.quoteTask = nil
                }
            } catch {
                guard self.quoteNonce == nonce, self.draft == requestedDraft else { return }
                self.isLoadingQuote = false
                self.quoteTask = nil
                self.operationError = error.localizedDescription
            }
        }
    }

    private static func priceDraft(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000 else { return "" }
        return String(value)
    }
}

private struct ModelPricingDraft: Equatable {
    var id: UUID?
    var platform: TokenPlatform = .codex
    var modelID = ""
    var serviceTier: ModelPriceTier = .any
    var inputPerMillion = ""
    var cachedInputPerMillion = ""
    var cacheWritePerMillion = ""
    var outputPerMillion = ""
    var enabled = true

    init() {}

    init(rule: ModelPriceOverride) {
        self.id = rule.id
        self.platform = rule.platform
        self.modelID = rule.modelID
        self.serviceTier = rule.serviceTier
        self.inputPerMillion = String(rule.inputPerMillion)
        self.cachedInputPerMillion = String(rule.cachedInputPerMillion)
        self.cacheWritePerMillion = String(rule.cacheWritePerMillion)
        self.outputPerMillion = String(rule.outputPerMillion)
        self.enabled = rule.enabled
    }

    func validatedRule() throws -> ModelPriceOverride {
        let modelID = self.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw ModelPricingDraftError(message: "请填写模型 ID。") }
        return try ModelPriceOverride(
            id: self.id ?? UUID(),
            platform: self.platform,
            modelID: modelID,
            serviceTier: self.serviceTier,
            inputPerMillion: Self.validPrice(self.inputPerMillion, title: "输入"),
            cachedInputPerMillion: Self.validPrice(self.cachedInputPerMillion, title: "缓存读取"),
            cacheWritePerMillion: Self.validPrice(self.cacheWritePerMillion, title: "缓存写入"),
            outputPerMillion: Self.validPrice(self.outputPerMillion, title: "输出"),
            enabled: self.enabled)
    }

    private static func validPrice(_ text: String, title: String) throws -> Double {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value.isFinite, value >= 0, value <= 1_000_000 else {
            throw ModelPricingDraftError(message: "\(title)单价请填写 0 至 1,000,000 的有效数值。")
        }
        return value
    }
}

private struct ModelPricingDraftError: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
}
