// SPDX-License-Identifier: Apache-2.0

import OpenBeanVoice
import SwiftUI

/// 个人词表（Application Support 里的 glossary.txt，和 Mac 版同一种格式）：一行一个词条，可以写 `词条 = 误听1, 误听2`。
/// 这里按行编辑：注释和空行原样留着，没改的行原样写回。保存后让共用的 GlossaryBackfill 把新词表应用到已有的转写
struct WordListView: View {
    @State private var file = GlossaryFile.load()
    @State private var editing: GlossaryFile.EditTarget?
    @State private var query = ""
    @State private var saved = false

    private var entries: [(index: Int, entry: GlossaryCorrector.Entry)] {
        file.entries.filter { e in
            query.isEmpty || e.entry.term.localizedCaseInsensitiveContains(query)
                || e.entry.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(entries, id: \.index) { item in
                    Button { editing = .line(item.index) } label: { WordRow(entry: item.entry) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { remove(item.index) }
                        }
                }
            } header: {
                if !file.entries.isEmpty { Text("\(file.entries.count) terms") }
            } footer: {
                Text("Names, product names and jargon. OpenBean changes same-sounding words in transcripts to these, without an LLM; in long transcripts only terms of three or more characters are fixed by sound. For a word it keeps mishearing, add what it hears, for example Claude Code heard as “cloud code”. Summaries also get the list.")
            }
            if saved {
                Section {
                    Label("Saved. Existing transcripts are being updated in the background.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if file.entries.isEmpty {
                ContentUnavailableView {
                    Label("No terms yet", systemImage: "character.book.closed")
                } description: {
                    Text("Add names and words that transcripts get wrong.")
                } actions: {
                    Button("Add a term") { editing = .new }
                }
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query)
        .navigationTitle("Personal word list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { editing = .new }
            }
        }
        .sheet(item: $editing) { target in
            WordEditor(entry: target.index.map { file.entry(at: $0) } ?? GlossaryCorrector.Entry(term: ""),
                       isNew: target.index == nil,
                       taken: Set(file.entries.filter { $0.index != target.index }.map { $0.entry.term.lowercased() })) { entry in
                if let i = target.index { file.replace(i, with: entry) } else { file.append(entry) }
                save()
            }
        }
        .onAppear { file = GlossaryFile.load() }
    }

    private func remove(_ i: Int) {
        file.remove(i)
        save()
    }

    private func save() {
        file.save()
        // 共用的回填：词表变了就重新应用到已有的转写（列表、搜索、导出跟着更新）
        MobileModel.shared.glossaryBackfill.check(force: false)
        withAnimation { saved = true }
    }
}

struct WordRow: View {
    let entry: GlossaryCorrector.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.term).font(.body.weight(.medium))
            if !entry.aliases.isEmpty {
                Text("Heard as: \(entry.aliases.joined(separator: ", "))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// 改一个词条：词条本身，和它常被听成的写法（每个一行）
struct WordEditor: View {
    @State var term: String
    @State var aliases: [String]
    let isNew: Bool
    let taken: Set<String>
    let done: (GlossaryCorrector.Entry) -> Void
    @State private var newAlias = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    enum Field { case term, alias }

    init(entry: GlossaryCorrector.Entry, isNew: Bool, taken: Set<String>, done: @escaping (GlossaryCorrector.Entry) -> Void) {
        _term = State(initialValue: entry.term)
        _aliases = State(initialValue: entry.aliases)
        self.isNew = isNew
        self.taken = taken
        self.done = done
    }

    private var cleanTerm: String { GlossaryFile.clean(term) }
    private var problem: LocalizedStringKey? {
        if cleanTerm.isEmpty { return nil }
        if taken.contains(cleanTerm.lowercased()) { return "This term is already in the list." }
        if aliases.contains(where: { GlossaryFile.clean($0).count < 2 }) { return "Each misheard form needs at least two characters." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Term", text: $term, prompt: Text("For example: OpenBean"))
                        .focused($focus, equals: .term)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Term")
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                Section {
                    ForEach(aliases.indices, id: \.self) { i in
                        TextField("Heard as", text: $aliases[i])
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .onDelete { aliases.remove(atOffsets: $0) }
                    HStack {
                        TextField("Add what it hears", text: $newAlias)
                            .focused($focus, equals: .alias)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(addAlias)
                        Button("Add", systemImage: "plus.circle.fill", action: addAlias)
                            .labelStyle(.iconOnly)
                            .disabled(GlossaryFile.clean(newAlias).count < 2)
                    }
                } header: {
                    Text("Misheard as")
                } footer: {
                    Text("Optional. Whenever a transcript has one of these, it becomes the term. Chinese must match exactly; English ignores case, spaces and hyphens.")
                }
            }
            .navigationTitle(isNew ? "New term" : "Edit term")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) {
                        addAlias()
                        let a = aliases.map(GlossaryFile.clean).filter { $0.count >= 2 }
                        done(GlossaryCorrector.Entry(term: cleanTerm, aliases: a))
                        dismiss()
                    }
                    .disabled(cleanTerm.isEmpty || problem != nil)
                }
            }
            .onAppear { if isNew { focus = .term } }
        }
    }

    private func addAlias() {
        let a = GlossaryFile.clean(newAlias)
        guard a.count >= 2 else { return }
        aliases.append(a)
        newAlias = ""
    }
}

/// glossary.txt 的逐行模型：注释、空行和没改过的词条原样写回
struct GlossaryFile {
    enum Line { case other(String), entry(GlossaryCorrector.Entry, raw: String?) }
    enum EditTarget: Identifiable {
        case new, line(Int)
        var id: Int { index ?? -1 }
        var index: Int? { if case let .line(i) = self { return i } else { return nil } }
    }

    var lines: [Line]

    static func load() -> GlossaryFile {
        _ = AppPaths.readGlossary()  // 没有文件时写一份带说明的
        let text = (try? String(contentsOf: AppPaths.glossary, encoding: .utf8)) ?? ""
        var lines: [Line] = text.components(separatedBy: .newlines).map { l in
            if let e = GlossaryCorrector.Entry.parse(l) { return .entry(e, raw: l) }
            return .other(l)
        }
        // 文件以换行结尾时最后多一个空串
        if case .other("") = lines.last { lines.removeLast() }
        return GlossaryFile(lines: lines)
    }

    var entries: [(index: Int, entry: GlossaryCorrector.Entry)] {
        lines.enumerated().compactMap { i, l in if case let .entry(e, _) = l { return (i, e) } else { return nil } }
    }

    func entry(at i: Int) -> GlossaryCorrector.Entry {
        if case let .entry(e, _) = lines[i] { return e }
        return GlossaryCorrector.Entry(term: "")
    }

    mutating func replace(_ i: Int, with e: GlossaryCorrector.Entry) {
        if entry(at: i) != e { lines[i] = .entry(e, raw: nil) }
    }
    mutating func append(_ e: GlossaryCorrector.Entry) { lines.append(.entry(e, raw: nil)) }
    mutating func remove(_ i: Int) { lines.remove(at: i) }

    func save() {
        let text = lines.map { l -> String in
            switch l {
            case let .other(s): return s
            case let .entry(_, raw?): return raw
            case let .entry(e, nil): return e.aliases.isEmpty ? e.term : "\(e.term) = \(e.aliases.joined(separator: ", "))"
            }
        }.joined(separator: "\n") + "\n"
        try? text.write(to: AppPaths.glossary, atomically: true, encoding: .utf8)
    }

    /// 词条和别名里不能有换行、等号、分隔用的逗号顿号；不能以 # 开头（会被当成注释）
    static func clean(_ s: String) -> String {
        var t = s.components(separatedBy: CharacterSet(charactersIn: "\n\r=＝,，、")).joined(separator: " ")
        t = t.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return t
    }
}
