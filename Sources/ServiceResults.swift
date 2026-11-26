import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ServiceTranslationResult: Identifiable, Equatable {
    let id: TranslationServiceID
    var runID = UUID()
    var loading = true
    var retryingEmptyResponse = false
    var error: String?
    var result = BuiltinTranslationResult(text: "")

    @MainActor func copy(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(result.copyText, forType: .string)
    }
}

extension TranslationServiceID {
    var color: Color {
        switch self { case .youdao: return Color(red: 0.72, green: 0.29, blue: 0.26)
        case .google: return Color(red: 0.23, green: 0.42, blue: 0.73)
        case .ai: return Color(red: 0.35, green: 0.32, blue: 0.69) }
    }
}

struct ServiceResultsBody: View {
    @ObservedObject var state: FloatingState
    var retry: (TranslationServiceID) -> Void
    var modelMenuTracking: (Bool) -> Void
    var selectModel: (TranslationChoice, UUID) -> Void
    var restoreModel: (UUID) -> Void
    var loadModels: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var copied: TranslationServiceID?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                ForEach(state.services) { service in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text(service.id.mark).font(.system(size: 12, weight: .semibold))
                                .frame(width: 27, height: 27).foregroundStyle(service.id.color)
                                .background(service.id.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                            Text(state.operation.serviceName(service.id)).font(.system(size: 13, weight: .semibold))
                                .lineLimit(1).truncationMode(.tail).help(state.operation.serviceName(service.id))
                            Spacer(minLength: 0)
                            if service.id == .ai {
                                TemporaryModelPicker(state: state, tracking: modelMenuTracking, select: selectModel, restore: restoreModel, load: loadModels)
                                    .frame(maxWidth: 125).frame(height: 24)
                                if state.temporaryModel { Text("本次").font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 10)
                            .background(service.id.color.opacity(colorScheme == .dark ? 0.16 : 0.07))
                        Divider()
                        serviceBody(service).padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 6)
                        HStack {
                            Spacer()
                            if service.error != nil {
                                Button("重试") { retry(service.id) }.disabled(!state.actionAvailable)
                            } else {
                                Button {
                                    service.copy(to: .general)
                                    copied = service.id
                                } label: {
                                    Label(copied == service.id ? "已复制" : "复制", systemImage: "doc.on.doc")
                                }.disabled(service.loading)
                                    .accessibilityLabel("复制\(state.operation.serviceName(service.id))结果")
                            }
                        }.font(.system(size: 11)).buttonStyle(.borderless)
                            .padding(.horizontal, 14).padding(.bottom, 10).padding(.top, 4)
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.10), lineWidth: 1).allowsHitTesting(false))
                }
            }.padding(12).background(Color.primary.opacity(0.025))
        }.frame(width: TranslationWindowLayout.width).fixedSize(horizontal: false, vertical: true)
            .onChange(of: state.services) { copied = nil }
            .task(id: copied) {
                guard copied != nil else { return }
                do { try await Task.sleep(nanoseconds: 1_800_000_000); copied = nil } catch { }
            }
    }
    @ViewBuilder private func serviceBody(_ service: ServiceTranslationResult) -> some View {
        if let error = service.error {
            let message = service.retryingEmptyResponse ? "按原设置重试未成功。\(error)" : error
            Label(message, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
        } else if service.loading && service.result.text.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(service.retryingEmptyResponse ? "未收到正文，正在按原设置重试…" : "正在\(state.operation.action)…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if !service.result.phonetics.isEmpty { Text(service.result.phonetics.joined(separator: "　")).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                if !service.result.meanings.isEmpty {
                    ForEach(Array(service.result.meanings.enumerated()), id: \.offset) { _, meaning in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !meaning.part.isEmpty { Text(meaning.part).font(.system(size: 12)).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .leading) }
                            Text(meaning.text).font(.system(size: state.fontSize)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    TranslationResultText(text: service.result.text, dark: colorScheme == .dark, fontSize: state.fontSize, operation: state.operation)
                }
            }
        }
    }
}

struct ServicesScrollArea: NSViewRepresentable {
    let bodyView: ServiceResultsBody
    @ObservedObject private var state: FloatingState
    init(bodyView: ServiceResultsBody) {
        self.bodyView = bodyView
        _state = ObservedObject(wrappedValue: bodyView.state)
    }
    func makeNSView(context: Context) -> TranslationBodyScrollView { TranslationBodyScrollView() }
    func updateNSView(_ view: TranslationBodyScrollView, context: Context) {
        view.updateServices(bodyView, sessionID: state.sessionID)
    }
}

struct TranslationServicesListView: View {
    @ObservedObject var store: BuiltinTranslationSettings
    @ViewState private var dragging: TranslationServiceID?
    @ViewState private var rowWidth: CGFloat = 500
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsGroup(title: "翻译服务") {
                ForEach(store.order) { service in
                    if service != store.order.first { Divider() }
                    TranslationServiceRow(service: service, store: store)
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { rowWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in rowWidth = width }
                    })
                    .contentShape(Rectangle())
                    .onDrag {
                        dragging = service
                        return NSItemProvider(object: service.rawValue as NSString)
                    } preview: {
                        TranslationServiceDragPreview(service: service, store: store, width: rowWidth)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("拖动\(service.name)调整顺序")
                    .accessibilityAction(named: "上移") { store.move(service, offset: -1) }
                    .accessibilityAction(named: "下移") { store.move(service, offset: 1) }
                    .onDrop(of: [UTType.text], delegate: ServiceOrderDrop(target: service, store: store, dragging: $dragging))
                }
            }
            Text("开启的服务参与翻译，拖动可调整显示顺序。中文划词润色始终只用 AI，不受 AI 翻译开关影响。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct TranslationServiceRow: View {
    let service: TranslationServiceID
    @ObservedObject var store: BuiltinTranslationSettings
    var body: some View {
        SettingsRow {
            Text(service.mark).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26).foregroundStyle(service.color)
                .background(service.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Text(service.name)
            Spacer()
            switch service {
            case .youdao:
                Toggle("启用有道翻译", isOn: $store.youdao).labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
            case .google:
                Toggle("启用谷歌翻译", isOn: $store.google).labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
            case .ai:
                Toggle("启用 AI 翻译", isOn: $store.ai).labelsHidden().toggleStyle(.switch).controlSize(.small).settingsAction()
            }
        }
    }
}

struct TranslationServiceDragPreview: View {
    let service: TranslationServiceID
    @ObservedObject var store: BuiltinTranslationSettings
    let width: CGFloat
    var body: some View {
        TranslationServiceRow(service: service, store: store).frame(width: width)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 4)
            .padding(18).allowsHitTesting(false)
    }
}

private struct ServiceOrderDrop: DropDelegate {
    let target: TranslationServiceID
    let store: BuiltinTranslationSettings
    @Binding var dragging: TranslationServiceID?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        store.move(dragging, to: target)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
