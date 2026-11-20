import AppKit
import GodDBCore
import SwiftUI
import UniformTypeIdentifiers

/// 테이블 명세서(엑셀) 저장 전: 시스템명 · 작성자 · 작성일을 묻는다
struct TableSpecExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: DataModel
    @State private var systemName: String
    @State private var author: String
    @State private var date: String

    static let authorKey = "tableSpec.author"

    init(model: DataModel) {
        self.model = model
        _systemName = State(initialValue: model.name)
        let saved = UserDefaults.standard.string(forKey: Self.authorKey) ?? ""
        _author = State(initialValue: saved.isEmpty ? NSFullUserName() : saved)
        _date = State(initialValue: Self.today())
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("테이블 명세서로 저장하기…"), systemImage: "tablecells").font(.headline)
            Form {
                TextField(tr("시스템명"), text: $systemName)
                TextField(tr("작성자"), text: $author)
                TextField(tr("작성일"), text: $date)
            }
            .formStyle(.columns)
            Text(tr("목차 시트와 테이블마다 한 시트(컬럼 · 인덱스 · 관계)로 된 엑셀 파일을 만들어요."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("저장…")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func save() {
        let info = TableSpecInfo(systemName: systemName.trimmingCharacters(in: .whitespaces),
                                 author: author.trimmingCharacters(in: .whitespaces),
                                 date: date.trimmingCharacters(in: .whitespaces))
        UserDefaults.standard.set(info.author, forKey: Self.authorKey)
        dismiss()
        let model = model
        // 시트가 닫힌 뒤에 저장 창을 띄운다
        DispatchQueue.main.async { Self.saveFile(model, info: info) }
    }

    @MainActor
    static func saveFile(_ model: DataModel, info: TableSpecInfo) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.nameFieldStringValue = "\(model.name)_테이블명세서.xlsx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TableSpecExport.data(model, info: info).write(to: url, options: .atomic) } catch {
            NSAlert(error: error).runModal()
        }
    }
}
