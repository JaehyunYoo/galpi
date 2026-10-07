import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AudioTrack: Codable {
    var file: String
    var label: String
    var offset: Double
}
struct Recording: Codable, Identifiable {
    var id = UUID().uuidString
    var created = Date().timeIntervalSince1970
    var mode: String
    var duration: Double = 0
    var status = "recording"
    var tracks: [AudioTrack] = []
    var playbackFile: String?
}
struct Note: Codable, Identifiable {
    var id = UUID().uuidString
    var title = "제목 없는 메모"
    var markdown = ""
    var document: String?
    var summary = ""
    var transcript = ""
    var pinned = false
    var deleted = false
    var created = Date().timeIntervalSince1970
    var updated = Date().timeIntervalSince1970
    var recordings: [Recording] = []
}
struct Shortcut: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String
}
struct Folder: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var path: String
    var bookmark: Data?
    var shortcut: Shortcut?
}
struct Preferences: Codable {
    var launcher = Shortcut(key: 49, modifiers: 6144, label: "⌃ ⌥ Space")
    var locale = "ko-KR"
    var model = ""
    var aiProvider: String?
    var claudeModel: String?
    var effectiveAIProvider: String { aiProvider == "claude" ? "claude" : "chatgpt" }
    var effectiveClaudeModel: String { claudeModel ?? "sonnet" }
    var compact = false
    var alwaysOnTop = false
    var theme: String?
    var customThemes: [CustomTheme]?
    var memoShortcut: Shortcut?
    var notchShortcut: Shortcut?
    var notchEnabled: Bool?
    var effectiveNotchShortcut: Shortcut { notchShortcut ?? Shortcut(key: 5, modifiers: 6144, label: "⌃ ⌥ G") }
    var effectiveMemoShortcut: Shortcut { memoShortcut ?? Shortcut(key: 45, modifiers: 6144, label: "⌃ ⌥ N") }
}
struct Library: Codable {
    var version = 1
    var notes: [Note] = []
    var folders: [Folder] = []
    var preferences = Preferences()
    var selectedNoteID: String?
}

final class Store {
    let root: URL
    var library: Library
    let encoder = JSONEncoder()
    init(root: URL? = nil) throws {
        let env = ProcessInfo.processInfo.environment["GALPI_DATA_DIR"]
        self.root = try root ?? env.map { URL(fileURLWithPath: $0) } ?? Compatibility.dataDirectory()
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = self.root.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file)) }
            catch { throw AppError("저장된 메모를 읽지 못했어요. 원본을 보존했어요. 데이터 폴더: \(self.root.path)") }
        } else {
            library = Library()
            var note = Note()
            note.title = "Galpi에 오신 걸 환영해요"
            note.markdown = "생각났을 때 바로 꺼내 쓰는 나만의 메모장.\n\n## 바로 해볼 것\n\n- [ ] 새 메모 만들기\n- [ ] 폴더에 단축키 지정하기\n- [ ] 회의 메모에서 녹음하기\n\n`/`를 입력하거나 아래 블록 버튼으로 제목, 체크리스트, 인용, 코드를 넣어보세요.\n\n**⌃ ⌥ Space**로 어디서든 검색창을 열 수 있어요."
            library.notes = [note]
            library.selectedNoteID = note.id
        }
        for i in library.notes.indices {
            // The welcome note is persisted data, so changing the new-note template
            // alone does not update existing installations. Keep edited content intact.
            if Compatibility.welcomeTitles.contains(library.notes[i].title),
               library.notes[i].markdown.hasPrefix("생각났을 때 바로 꺼내 쓰는 나만의 메모장.") {
                library.notes[i].title = "Galpi에 오신 걸 환영해요"
            }
            for j in library.notes[i].recordings.indices where library.notes[i].recordings[j].status == "recording" {
                library.notes[i].recordings[j].status = "interrupted"
                let recording = library.notes[i].recordings[j]
                let dir = recordingDirectory(recording.id)
                let known = ["microphone.caf", "system.caf"].filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
                library.notes[i].recordings[j].tracks = known.map { AudioTrack(file: $0, label: $0 == "microphone.caf" ? "마이크" : "회의 소리", offset: 0) }
            }
        }
        try persist()
    }
    func persist() throws {
        let data = try encoder.encode(library)
        let target = root.appendingPathComponent("library.json")
        if let old = try? Data(contentsOf: target) {
            try old.write(to: root.appendingPathComponent("library.backup.json"), options: .atomic)
        }
        try data.write(to: target, options: .atomic)
    }
    func snapshot() throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(library)) }
    func note(_ id: String) throws -> Note {
        guard let n = library.notes.first(where: { $0.id == id }) else { throw AppError("메모를 찾지 못했어요.") }
        return n
    }
    func update(_ id: String, _ change: (inout Note) -> Void) throws {
        guard let i = library.notes.firstIndex(where: { $0.id == id }) else { throw AppError("메모를 찾지 못했어요.") }
        let previous = library.notes[i]
        change(&library.notes[i]); library.notes[i].updated = Date().timeIntervalSince1970
        do { try persist() } catch { library.notes[i] = previous; throw error }
    }
    func create(title: String = "제목 없는 메모", markdown: String = "") throws -> Note {
        let previous=library
        var note = Note(); note.title = title; note.markdown = markdown
        library.notes.insert(note, at: 0); library.selectedNoteID = note.id
        do {try persist()} catch {library=previous;throw error};return note
    }
    func recordingDirectory(_ id: String) -> URL { root.appendingPathComponent("Recordings", isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    func archiveSummary(_ note: Note) throws {
        guard !note.summary.isEmpty else { return }
        let directory = root.appendingPathComponent("History", isDirectory: true).appendingPathComponent(note.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(note.summary.utf8).write(to: directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).md"), options: .atomic)
    }
    static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}
