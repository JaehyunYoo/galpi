import AppKit
import SwiftUI

struct NotchGeometry {
    let screen: NSRect
    let cutoutWidth: CGFloat
    let topInset: CGFloat
    var collapsedSize: NSSize { NSSize(width: max(220, cutoutWidth + 156), height: max(32, topInset + 10)) }
    func frame(expanded: Bool, recordingOptions: Bool = false) -> NSRect {
        let size = expanded ? NSSize(width: min(660, screen.width - 32), height: topInset + (recordingOptions ? 230 : 192)) : collapsedSize
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }
    static func current(_ screen: NSScreen) -> NotchGeometry {
        let left = screen.auxiliaryTopLeftArea ?? .zero, right = screen.auxiliaryTopRightArea ?? .zero
        let gap = !left.isEmpty && !right.isEmpty ? right.minX - left.maxX : 0
        return NotchGeometry(screen: screen.frame, cutoutWidth: max(0, gap), topInset: screen.safeAreaInsets.top)
    }
}

struct NotchNote: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
}
struct NotchFolder: Identifiable, Equatable {
    let id: String
    let name: String
}
@MainActor final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var topInset: CGFloat = 0
    @Published var cutoutWidth: CGFloat = 0
    @Published var notes: [NotchNote] = []
    @Published var folders: [NotchFolder] = []
    @Published var recording = false
    @Published var paused = false
    @Published var busy = false
    @Published var duration = 0
    @Published var recordingOptions = false
    @Published var targetTitle = "회의 메모"
    @Published var error = ""
    var time: String { String(format: "%02d:%02d", duration / 60, duration % 60) }
}

final class NotchPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor final class NotchController {
    weak var owner: AppDelegate?
    let state = NotchState()
    let panel: NotchPanel
    private var screenObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var operationInFlight = false
    private let display: Bool
    private(set) var geometry: NotchGeometry?
    private var enabled = false

    init(owner: AppDelegate, display: Bool = true) {
        self.owner = owner; self.display = display
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Galpi 노치"
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: NotchView(state: state, action: { [weak self] in self?.act($0) }))
        host.sizingOptions = []
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.collapse() }
        if display {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.position() }
            }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window !== self.panel { self.collapse() }
                return event
            }
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.collapse() }
            }
        }
        refresh()
    }
    func refresh() {
        guard let owner, let store = owner.store else { return }
        let notes = store.library.notes.filter { !$0.deleted }.sorted { $0.updated > $1.updated }.prefix(3).map {
            NotchNote(id: $0.id, title: $0.title, preview: $0.markdown.split(separator: "\n").first.map(String.init) ?? "이어서 메모하기")
        }
        let folders = store.library.folders.map { NotchFolder(id: $0.id, name: $0.name) }
        if state.notes != notes { state.notes = notes }
        if state.folders != folders { state.folders = folders }
        let targetID = owner.recordingNoteID ?? store.library.selectedNoteID
        let targetTitle = store.library.notes.first { $0.id == targetID && !$0.deleted }?.title ?? store.library.notes.first { !$0.deleted }?.title ?? "회의 메모"
        if state.targetTitle != targetTitle { state.targetTitle = targetTitle }
        let active = owner.recorder != nil
        if state.recording != active { state.recording = active; state.recordingOptions = false; position() }
        let paused = owner.recorder?.isPaused ?? false
        if state.paused != paused { state.paused = paused }
        let duration = Int(owner.recorder?.duration ?? 0)
        if state.duration != duration { state.duration = duration }
        let busy = owner.recordingStarting || owner.recordingStopping || operationInFlight
        if state.busy != busy { state.busy = busy }
        let enabled = store.library.preferences.notchEnabled ?? true
        if enabled != self.enabled { self.enabled = enabled; if !enabled { collapse(); panel.orderOut(nil) } else { position() } }
    }
    func position(animated: Bool = false) {
        guard enabled else { return }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { panel.orderOut(nil); return }
        geometry = NotchGeometry.current(screen)
        guard let geometry else { return }
        state.topInset = geometry.topInset; state.cutoutWidth = geometry.cutoutWidth
        panel.setFrame(geometry.frame(expanded: state.expanded, recordingOptions: state.recordingOptions), display: true, animate: animated && display && panel.isVisible)
        if display { panel.orderFrontRegardless() }
    }
    func toggle() {
        guard enabled else { owner?.showWindow(); return }
        if state.expanded { collapse(); return }
        state.expanded = true; state.error = ""; state.recordingOptions = false; position(animated: true)
        if display { panel.makeKey() }
    }
    func collapse() {
        guard state.expanded else { return }
        state.expanded = false; state.recordingOptions = false; state.error = ""
        if panel.isKeyWindow { panel.resignKey() }
        position(animated: true)
    }
    enum Action { case toggle, collapse, note(String), newNote, folder(String), settings, recordOptions, start(String), pause, stop }
    func act(_ action: Action) {
        guard let owner else { return }
        switch action {
        case .toggle: toggle()
        case .collapse: collapse()
        case .note(let id): owner.openMemo(noteID: id)
        case .newNote: owner.newNote()
        case .folder(let id):
            do { try owner.openFolder(id); collapse() } catch { state.error = error.localizedDescription }
        case .settings: owner.openSettings()
        case .recordOptions: state.recordingOptions.toggle(); state.error = ""; position(animated: true)
        case .start(let mode):
            guard !state.busy, !state.recording else { return }
            operationInFlight = true; state.busy = true
            owner.flush(onFailure: { [weak self] in self?.operationInFlight = false; self?.state.busy = false; self?.state.error = "메모 저장을 완료한 뒤 다시 시도해 주세요." }) { [weak self, weak owner] in
                guard let self, let owner else { return }
                Task { @MainActor in
                    defer { self.operationInFlight = false; self.state.busy = false; self.refresh() }
                    do {
                        let note = try owner.store.library.notes.first { $0.id == owner.store.library.selectedNoteID && !$0.deleted } ?? owner.store.library.notes.first { !$0.deleted } ?? owner.store.create(title: "회의 메모")
                        try await owner.startRecording(noteID: note.id, mode: mode)
                        self.state.recordingOptions = false; self.position()
                    } catch { self.state.error = error.localizedDescription }
                }
            }
        case .pause: owner.recorder?.togglePause(); owner.tick()
        case .stop:
            guard !state.busy else { return }; operationInFlight = true; state.busy = true
            Task { @MainActor [weak self] in
                do { try await owner.stopRecording() } catch { self?.state.error = error.localizedDescription }
                self?.operationInFlight = false; self?.state.busy = false; self?.refresh()
            }
        }
    }
    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }
}

private struct NotchOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 22
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - corner, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: corner, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - corner), control: CGPoint(x: 0, y: rect.maxY))
        p.closeSubpath(); return p
    }
}

private struct NotchView: View {
    @ObservedObject var state: NotchState
    let action: (NotchController.Action) -> Void
    private let panelColor = Color(red: 0.045, green: 0.048, blue: 0.055)
    private let controlColor = Color(red: 0.13, green: 0.14, blue: 0.155)
    var body: some View {
        VStack(spacing: 0) {
            if state.expanded {
                Color.clear.frame(height: state.topInset)
                HStack {
                    Label("Galpi", systemImage: "bookmark.fill").font(.system(size: 13, weight: .semibold))
                    Text("빠른 작업").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { action(.settings) } label: {
                        Image(systemName: "gearshape").frame(width: 32, height: 28).contentShape(Rectangle())
                    }.help("Galpi 설정").accessibilityLabel("Galpi 설정")
                    Button { action(.collapse) } label: {
                        Image(systemName: "minus").frame(width: 32, height: 28).contentShape(Rectangle())
                    }.help("노치 접기").accessibilityLabel("노치 접기").accessibilityIdentifier("notch-collapse")
                }.padding(.horizontal, 20).padding(.top, 8)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 9) {
                        if let note = state.notes.first {
                            Button { action(.note(note.id)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bookmark.fill").font(.system(size: 29)).foregroundStyle(Color(red: 0.25, green: 0.34, blue: 0.43)).frame(width: 62, height: 72).background(Color(red: 0.87, green: 0.83, blue: 0.73), in: RoundedRectangle(cornerRadius: 14))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(note.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                        Text(note.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                        Text("메모 창에서 이어서 쓰기 ↗").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.contentShape(Rectangle())
                            }.help(note.title)
                        } else {
                            Button("첫 메모 만들기") { action(.newNote) }.frame(maxWidth: .infinity, minHeight: 72)
                        }
                        HStack(spacing: 9) {
                            Menu("최근 메모") { ForEach(state.notes) { note in Button(note.title) { action(.note(note.id)) } } }.menuStyle(.borderlessButton).fixedSize().disabled(state.notes.isEmpty)
                            Button { action(.newNote) } label: { Label("새 메모", systemImage: "square.and.pencil") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 82)
                    VStack(spacing: 6) {
                        if state.folders.isEmpty {
                            Button { action(.settings) } label: { Label("폴더 추가", systemImage: "folder.badge.plus").font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 80).background(controlColor, in: RoundedRectangle(cornerRadius: 15)) }
                        } else {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(spacing: 8) {
                                    ForEach(state.folders) { folder in
                                        Button { action(.folder(folder.id)) } label: {
                                            Label(folder.name, systemImage: "folder").lineLimit(1).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 39).background(controlColor, in: Capsule()).contentShape(Capsule())
                                        }.help(folder.name)
                                    }
                                }.padding(.trailing, state.folders.count > 2 ? 10 : 0)
                            }.frame(height: state.folders.count == 1 ? 39 : 86)
                                .accessibilityLabel("폴더 바로가기")
                            if state.folders.count > 2 {
                                Text("↕ 스크롤 · 폴더 \(state.folders.count)개").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(width: 165)
                    VStack(spacing: 5) {
                        Button { action(state.recording ? .stop : .recordOptions) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: state.recording ? "stop.fill" : "mic.fill").font(.system(size: 24))
                                Text(state.busy ? "처리 중…" : state.recording ? state.time : "녹음").font(.system(size: 11)).monospacedDigit()
                            }.frame(width: 80, height: 80).background(state.recording ? Color(red: 0.28, green: 0.13, blue: 0.12) : controlColor, in: Circle())
                        }.disabled(state.busy).help(state.recording ? "녹음 저장 후 종료" : "녹음 방식 선택")
                        if state.recording { Button(state.paused ? "계속 녹음" : "일시정지") { action(.pause) }.font(.system(size: 11)).disabled(state.busy) }
                    }.frame(width: 84)
                }.padding(.horizontal, 20).padding(.top, 12)
                if state.recordingOptions {
                    HStack {
                        Text(state.targetTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help("이 메모에 녹음을 첨부해요")
                        Spacer()
                        Button("대면 · 마이크") { action(.start("inperson")) }.padding(8).background(controlColor, in: Capsule())
                        Button("온라인 · 마이크 + 시스템") { action(.start("online")) }.padding(8).background(controlColor, in: Capsule())
                    }.font(.system(size: 11)).padding(.horizontal, 20).padding(.top, 9).disabled(state.busy)
                }
                if !state.error.isEmpty { Text(state.error).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2).padding(.horizontal, 20).accessibilityLabel(state.error) }
                Spacer(minLength: 7)
            } else {
                Button { action(.toggle) } label: {
                    HStack(spacing: 0) {
                        Label("Galpi", systemImage: "bookmark.fill").font(.system(size: 11, weight: .medium)).frame(width: 74)
                        Spacer(minLength: state.cutoutWidth)
                        if state.recording { HStack(spacing: 4) { Circle().fill(state.paused ? Color.orange : Color.red).frame(width: 5, height: 5); Text(state.time).font(.system(size: 11)).monospacedDigit() }.frame(width: 74) }
                        else { Image(systemName: "chevron.down").font(.system(size: 11)).frame(width: 74) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.help("Galpi 노치 열기")
            }
        }.foregroundStyle(Color.white.opacity(0.93)).buttonStyle(.plain).background(panelColor).clipShape(NotchOutline()).environment(\.colorScheme, .dark)
    }
}
