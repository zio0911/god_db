import GodDBCore
import SwiftUI

/// 행 상세가 다시 그려질 때마다 같은 값을 다시 파싱하지 않도록 최근 결과를 기억한다
@MainActor
enum JSONCache {
    private struct Key: Hashable {
        let text: String
        let jsonType: Bool
    }
    private static var detections: [Key: JSONDetection] = [:]
    private static var pretty: [String: String] = [:]

    static func detect(_ value: String?, columnType: String?) -> JSONDetection {
        // 대부분의 칸은 첫 글자만 보고 바로 거른다 (캐시에 넣지 않음)
        guard let value, JSONView.mightBeJSON(value, columnType: columnType) else { return .notJSON }
        let key = Key(text: value, jsonType: JSONView.isJSONType(columnType))
        if let hit = detections[key] { return hit }
        if detections.count > 64 { detections.removeAll() }
        let d = JSONView.detect(value, columnType: columnType)
        detections[key] = d
        return d
    }

    static func pretty(_ text: String, _ node: JSONNode) -> String {
        if let hit = pretty[text] { return hit }
        if pretty.count > 32 { pretty.removeAll() }
        let p = JSONView.pretty(node)
        pretty[text] = p
        return p
    }
}

extension JSONDetection {
    var isJSON: Bool {
        if case .notJSON = self { return false }
        return true
    }
}

/// 행 상세의 JSON 칸: 원문 · 정렬 · 트리 전환 (마지막 선택 기억, 기본 트리).
/// 편집 중이면 원문 = 편집 칸, 정렬 · 트리는 지금 값의 읽기 전용 보기.
struct JSONFieldView<RawEditor: View>: View {
    let text: String
    let detection: JSONDetection
    /// 편집 중일 때 원문 자리에 보일 편집 칸 (nil 이면 원문 글자)
    let rawEditor: RawEditor?
    @AppStorage(JSONViewMode.defaultsKey) private var modeRaw = JSONViewMode.default.rawValue

    init(text: String, detection: JSONDetection, @ViewBuilder rawEditor: () -> RawEditor) {
        self.text = text
        self.detection = detection
        self.rawEditor = rawEditor()
    }

    private var mode: JSONViewMode { JSONViewMode(rawValue: modeRaw) ?? .default }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch detection {
            case .tooLarge:
                Label(tr("너무 커서 원문만 보여요"), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                raw
            case .json(let node):
                Picker("", selection: $modeRaw) {
                    Text(tr("원문")).tag(JSONViewMode.raw.rawValue)
                    Text(tr("정렬")).tag(JSONViewMode.pretty.rawValue)
                    Text(tr("트리")).tag(JSONViewMode.tree.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                switch mode {
                case .raw: raw
                case .pretty: box(Text(JSONCache.pretty(text, node)))
                case .tree: JSONTreeView(root: node).id(text)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                }
            case .notJSON:
                raw
            }
        }
    }

    @ViewBuilder
    private var raw: some View {
        if let rawEditor { rawEditor } else { box(Text(text)) }
    }

    private func box(_ t: Text) -> some View {
        t.font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
    }
}

extension JSONFieldView where RawEditor == EmptyView {
    init(text: String, detection: JSONDetection) {
        self.text = text
        self.detection = detection
        rawEditor = nil
    }
}

/// JSON 트리: 펼치기/접기 (처음엔 2단계까지), 값 종류별 색, 우클릭 > 값 복사 · 경로 복사
struct JSONTreeView: View {
    let root: JSONNode
    /// 기본 펼침 상태에서 뒤집은 항목
    @State private var toggled: Set<[JSONPathComponent]> = []

    private struct Line: Identifiable {
        let path: [JSONPathComponent]
        let node: JSONNode
        var id: [JSONPathComponent] { path }
    }

    private func expanded(_ path: [JSONPathComponent]) -> Bool {
        (path.count < 2) != toggled.contains(path)
    }

    private var lines: [Line] {
        var out: [Line] = []
        func visit(_ node: JSONNode, _ path: [JSONPathComponent]) {
            out.append(Line(path: path, node: node))
            guard expanded(path) else { return }
            switch node {
            case .object(let members): for m in members { visit(m.value, path + [.key(m.key)]) }
            case .array(let items): for (i, v) in items.enumerated() { visit(v, path + [.index(i)]) }
            default: break
            }
        }
        // 맨 위 객체 · 배열은 줄로 그리지 않고 그 항목부터
        switch root {
        case .object(let members): for m in members { visit(m.value, [.key(m.key)]) }
        case .array(let items): for (i, v) in items.enumerated() { visit(v, [.index(i)]) }
        default: out.append(Line(path: [], node: root))
        }
        return out
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if case .object(let m) = root, m.isEmpty { Text(verbatim: "{}").foregroundStyle(.secondary) }
            if case .array(let a) = root, a.isEmpty { Text(verbatim: "[]").foregroundStyle(.secondary) }
            ForEach(lines) { line in
                row(line)
            }
        }
        .font(.system(.callout, design: .monospaced))
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 4) {
            if line.node.isContainer {
                Image(systemName: expanded(line.path) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            if let last = line.path.last {
                switch last {
                case .key(let k): Text(k).foregroundStyle(.primary)
                case .index(let i): Text(verbatim: "[\(i)]").foregroundStyle(.secondary)
                }
                Text(verbatim: ":").foregroundStyle(.tertiary)
            }
            value(line)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(max(0, line.path.count - 1)) * 14)
        // 탭 · 우클릭을 붙여도 키 · 값이 각각 읽히게 (손쉬운 사용 · 화면 테스트)
        .accessibilityElement(children: .contain)
        .contentShape(Rectangle())
        .onTapGesture {
            guard line.node.isContainer else { return }
            if toggled.contains(line.path) { toggled.remove(line.path) } else { toggled.insert(line.path) }
        }
        .contextMenu {
            Button(tr("값 복사")) { Pasteboard.copy(JSONView.copyText(line.node)) }
            Button(tr("경로 복사")) { Pasteboard.copy(JSONView.path(line.path)) }
        }
    }

    @ViewBuilder
    private func value(_ line: Line) -> some View {
        switch line.node {
        case .object(let m):
            Text(verbatim: expanded(line.path) ? "{" : "{…}").foregroundStyle(.secondary)
            Text(verbatim: "\(m.count)").font(.caption2).foregroundStyle(.tertiary)
        case .array(let a):
            Text(verbatim: expanded(line.path) ? "[" : "[…]").foregroundStyle(.secondary)
            Text(verbatim: "\(a.count)").font(.caption2).foregroundStyle(.tertiary)
        case .string(let s):
            Text(JSONView.quote(s)).foregroundStyle(.green).lineLimit(nil).textSelection(.enabled)
        case .number(let n):
            Text(n).foregroundStyle(.blue).textSelection(.enabled)
        case .bool(let b):
            Text(verbatim: b ? "true" : "false").foregroundStyle(.purple)
        case .null:
            Text(verbatim: "null").foregroundStyle(.secondary).italic()
        }
    }
}
