import AppKit
import GodDBCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// 모델링 화면 상태: 저장된 모델 목록, 고른 모델, 자동 저장, 되돌리기
@MainActor
@Observable
final class ModelingState {
    var models: [DataModel] = []
    var selectedID: UUID?
    private(set) var loaded = false
    /// 모델별 되돌리기 기록 (구조 변경 전 스냅샷)
    private var undo: [UUID: [DataModel]] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    let store: ModelStore
    /// 저장 실패 등을 앱 로그로 보낸다
    var onError: ((String, any Error) -> Void)?

    init(store: ModelStore = .shared) {
        self.store = store
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        models = store.list()
        selectedID = selectedID ?? models.first?.id
        loaded = true
    }

    /// 개발용 화면 확인: 저장소 대신 메모리의 모델만 쓴다
    func useForPreview(_ list: [DataModel]) {
        models = list
        selectedID = list.first?.id
        loaded = true
    }

    var selected: DataModel? { selectedID.flatMap { id in models.first { $0.id == id } } }

    /// 지워져도 죽지 않는 바인딩
    func binding(_ id: UUID) -> Binding<DataModel>? {
        guard models.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { [weak self] in self?.models.first { $0.id == id } ?? DataModel(id: id) },
                       set: { [weak self] new in
                           guard let self, let i = self.models.firstIndex(where: { $0.id == id }) else { return }
                           if self.models[i] != new {
                               self.models[i] = new
                               self.scheduleSave(id)
                           }
                       })
    }

    /// 구조를 바꾸기 전에 호출 (테이블·관계 추가/삭제, 이동 등)
    func checkpoint(_ id: UUID) {
        guard let m = models.first(where: { $0.id == id }) else { return }
        var stack = undo[id] ?? []
        if stack.last != m { stack.append(m) }
        if stack.count > 60 { stack.removeFirst(stack.count - 60) }
        undo[id] = stack
    }

    func canUndo(_ id: UUID) -> Bool { !(undo[id] ?? []).isEmpty }

    func undoLast(_ id: UUID) {
        guard var stack = undo[id], let prev = stack.popLast(),
              let i = models.firstIndex(where: { $0.id == id }) else { return }
        undo[id] = stack
        models[i] = prev
        scheduleSave(id)
    }

    func edit(_ id: UUID, checkpoint cp: Bool = true, _ change: (inout DataModel) -> Void) {
        guard let i = models.firstIndex(where: { $0.id == id }) else { return }
        if cp { checkpoint(id) }
        change(&models[i])
        models[i].touch()
        scheduleSave(id)
    }

    func scheduleSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let m = self.models.first(where: { $0.id == id }) else { return }
            self.saveNow(m)
        }
    }

    func saveNow(_ m: DataModel) {
        var m = m
        m.updated = Date()
        do { try store.save(m) } catch {
            onError?(tr("모델 저장 실패 · %@", m.name), error)
        }
    }

    func add(_ model: DataModel) {
        models.insert(model, at: 0)
        selectedID = model.id
        saveNow(model)
    }

    func create(kind: DatabaseKind) {
        var m = DataModel(name: tr("새 모델 %@", "\(models.count + 1)"), kind: kind == .redis ? .mysql : kind)
        m.addTable(logicalName: tr("회원"))
        add(m)
    }

    func duplicate(_ id: UUID) {
        guard var m = models.first(where: { $0.id == id }) else { return }
        m.id = UUID()
        m.name += tr(" 복사본")
        m.created = Date()
        add(m)
    }

    func delete(_ id: UUID) {
        saveTasks[id]?.cancel()
        store.delete(id)
        models.removeAll { $0.id == id }
        undo[id] = nil
        if selectedID == id { selectedID = models.first?.id }
    }

    // MARK: - 파일

    static var fileType: UTType {
        UTType(filenameExtension: DataModel.fileExtension, conformingTo: .json) ?? .json
    }

    func exportFile(_ id: UUID) {
        guard let m = models.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = "\(m.name).\(DataModel.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ModelStore.encode(m).write(to: url, options: .atomic) } catch {
            NSAlert(error: error).runModal()
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                var m = try ModelStore.decode(Data(contentsOf: url))
                // 같은 모델을 두 번 가져와도 따로 보관
                if models.contains(where: { $0.id == m.id }) { m.id = UUID() }
                add(m)
            } catch {
                let alert = NSAlert()
                alert.messageText = url.lastPathComponent
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
