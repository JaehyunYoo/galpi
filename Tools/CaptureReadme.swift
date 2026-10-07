import AppKit
import WebKit

/// Captures the shipping UI in a hidden window. Only the supplied scratch store is used.
@main struct CaptureReadme {
    @MainActor static func main() {
        guard ProcessInfo.processInfo.environment["GALPI_UI_TEST"] == "1",
              let dataPath = ProcessInfo.processInfo.environment["GALPI_DATA_DIR"],
              CommandLine.arguments.count == 2 else { fatalError("Run Tools/capture-readme.sh") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do { try seed(URL(fileURLWithPath: dataPath)) }
        catch { fputs("Example data failed: \(error)\n", stderr); exit(1) }
        let delegate = AppDelegate()
        app.delegate = delegate
        Task { @MainActor in
            do {
                while delegate.web == nil { try await Task.sleep(for: .milliseconds(50)) }
                delegate.window.setContentSize(NSSize(width: 980, height: 760))
                let web = delegate.web!
                let output = URL(fileURLWithPath: CommandLine.arguments[1])
                let deadline = Date().addingTimeInterval(15)
                while !delegate.loaded.contains(ObjectIdentifier(web)) && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard delegate.loaded.contains(ObjectIdentifier(web)) else { throw AppError("App UI failed to load") }
                try await js(web, "for(let i=0;i<200;i++){if(window.Galpi && document.querySelector('#note-title').value==='오늘의 작업 메모') return; await new Promise(r=>setTimeout(r,50));} throw Error('UI did not become ready');")
                try await js(web, "await window.Galpi.flushAsync();")
                try await capture(web, output, "notes-light")

                try await select(web, id: "docs-code", title: "코드 스니펫")
                try await js(web, "document.querySelector('[data-theme-choice=dark]').click();")
                try await waitTheme(web, "dark")
                try await capture(web, output, "code-dark")

                try await js(web, "document.querySelector('[data-theme-choice=light]').click();")
                try await waitTheme(web, "light")
                try await select(web, id: "docs-notes", title: "오늘의 작업 메모")
                try await js(web, "document.querySelector('#settings-open').click(); document.querySelector('[data-settings=folders]').click();")
                delegate.window.setContentSize(NSSize(width: 980, height: 920))
                try await capture(web, output, "folder-shortcuts")
                delegate.window.setContentSize(NSSize(width: 980, height: 760))

                try await js(web, "document.querySelector('[data-settings=appearance]').click(); document.querySelector('[data-theme-edit]').click();")
                try await capture(web, output, "theme-editor")
                try await js(web, "document.querySelector('#theme-cancel').click(); document.querySelector('#settings-close').click();")

                try await select(web, id: "docs-meeting", title: "제품 회의 · 예시")
                try await js(web, "document.querySelector('#record-open').click();")
                try await capture(web, output, "recording-modes")
                try await js(web, "document.querySelector('#record-cancel').click(); document.querySelector('[data-tab=summary]').click();")
                try await capture(web, output, "meeting-summary")

                try await js(web, "document.querySelector('#settings-open').click(); document.querySelector('[data-settings=ai]').click();")
                try await capture(web, output, "chatgpt-settings")
                try await js(web, "document.querySelector('#ai-provider').value='claude'; document.querySelector('#ai-provider').dispatchEvent(new Event('change',{bubbles:true})); for(let i=0;i<100 && document.querySelector('#claude-settings').hidden;i++) await new Promise(r=>setTimeout(r,20));")
                delegate.window.setContentSize(NSSize(width: 980, height: 920))
                try await capture(web, output, "claude-settings")
                delegate.window.setContentSize(NSSize(width: 980, height: 760))
                if let notch = delegate.notch {
                    delegate.store.library.folders += [
                        Folder(id: "docs-folder-3", name: "디자인 자료", path: "/Users/demo/Design"),
                        Folder(id: "docs-folder-4", name: "회의 자료", path: "/Users/demo/Meetings"),
                        Folder(id: "docs-folder-5", name: "보관함", path: "/Users/demo/Archive")
                    ]
                    notch.refresh(); notch.toggle()
                    try await Task.sleep(for: .milliseconds(350))
                    guard let view = notch.panel.contentView else { throw AppError("Missing native notch view") }
                    try captureNative(view, output, "notch-panel")
                    guard let scroll = findScrollView(view), let document = scroll.documentView,
                          document.bounds.height > scroll.contentView.bounds.height else { throw AppError("Folder list must scroll with five example folders") }
                    let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(350))
                    try captureNative(view, output, "notch-folders-scrolled")
                    notch.collapse()
                    try await Task.sleep(for: .milliseconds(350))
                    try captureNative(view, output, "notch-collapsed")
                }
                print("Captured 11 app screens using example data; no recording or AI request was started.")
                exit(0)
            } catch { fputs("Screenshot capture failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }

    @MainActor static func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView($0) }.first
    }

    @MainActor static func captureNative(_ view: NSView, _ output: URL, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError("Notch bitmap unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError("Notch PNG unavailable") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }

    static func seed(_ root: URL) throws {
        let store = try Store(root: root)
        let date = ISO8601DateFormatter().date(from: "2026-10-06T01:00:00Z")!.timeIntervalSince1970
        func note(_ id: String, _ title: String, _ markdown: String, pinned: Bool = false) -> Note {
            var result = Note()
            result.id = id; result.title = title; result.markdown = markdown
            result.pinned = pinned; result.created = date; result.updated = date
            return result
        }
        let notes = note("docs-notes", "오늘의 작업 메모", """
        생각은 가볍게 적고, 필요한 순간에 다시 꺼내요.

        ## 오늘 할 일

        - [x] 프로젝트 폴더에 단축키 연결하기
        - [ ] 회의 전에 질문 정리하기
        - [ ] 녹음 후 결정 사항과 다음 할 일 확인하기

        ## 잊지 않을 아이디어

        > 메모, 폴더, 회의 기록을 한곳에서 빠르게 찾기.

        빈 문단에서 `/`를 눌러 제목·목록·코드를 추가할 수 있어요.
        """, pinned: true)
        let code = note("docs-code", "코드 스니펫", """
        ## 언어에 맞게 읽기 쉽게

        코드 위에서 언어를 선택하면 키워드와 문자열을 구분해 보여줘요.

        ```javascript
        // 자주 쓰는 짧은 코드를 메모해 두세요.
        const project = "Galpi";
        const features = ["메모", "단축키", "회의록"];

        function describe(name) {
          return `${name}에서 생각을 이어가세요.`;
        }

        console.log(describe(project));
        ```

        선택한 언어와 코드는 메모를 다시 열어도 유지돼요.
        """)
        var meeting = note("docs-meeting", "제품 회의 · 예시", """
        ## 회의 안건

        - 첫 실행 안내와 폴더 바로가기 흐름 점검
        - 다음 배포 전 확인할 항목 정리

        아래 회의록은 화면 설명을 위한 예시입니다.
        """, pinned: true)
        meeting.transcript = """
        화면 설명용 예시 전사문입니다.

        [00:00] 마이크: 다음 배포에는 첫 실행 안내를 더 쉽게 정리하면 좋겠어요.
        [00:15] 회의 소리: 폴더 바로가기는 기존 단축키를 유지하고 안내를 보완해요.
        [00:30] 마이크: 가은은 목요일까지 안내 초안, 민준은 금요일까지 사용성 점검을 맡을게요.
        """
        meeting.summary = """
        > 화면 설명용 회의록 예시 · 실제 AI 생성 결과가 아닙니다.

        ## 핵심 요약

        첫 실행 안내를 보완하고 폴더 바로가기 사용 흐름을 점검하기로 했어요.

        ## 결정 사항

        - 첫 실행 안내에 세 단계 시작 가이드 추가
        - 폴더 바로가기의 기본 단축키 유지

        ## 다음 할 일

        - [ ] 가은 · 시작 가이드 초안 작성 · 10월 8일
        - [ ] 민준 · 폴더 바로가기 사용성 점검 · 10월 9일
        """
        var library = Library()
        library.notes = [notes, meeting, code, note("docs-ideas", "아이디어 수집", "다음에 해보고 싶은 일을 편하게 모아 두는 공간."), note("docs-links", "참고 링크", "프로젝트에 필요한 자료와 링크를 한곳에 정리해요.")]
        library.selectedNoteID = notes.id
        library.preferences.theme = "light"
        library.preferences.customThemes = [try CustomTheme(id: "docs-midnight", name: "미드나이트", colors: ["paper":"#142033", "side":"#101A2B", "ink":"#EBF0F7", "dim":"#A2B0C3", "line":"#2B3C54", "blue":"#8FBCF5"])]
        library.folders = [
            Folder(id: "docs-folder-1", name: "프로젝트", path: "/Users/demo/Projects", shortcut: Shortcut(key: 35, modifiers: 6144, label: "⌃ ⌥ P")),
            Folder(id: "docs-folder-2", name: "다운로드", path: "/Users/demo/Downloads", shortcut: Shortcut(key: 2, modifiers: 6144, label: "⌃ ⌥ D"))
        ]
        store.library = library
        try store.persist()
    }

    @MainActor static func js(_ web: WKWebView, _ script: String, arguments: [String: Any] = [:]) async throws {
        let _: Any? = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { continuation.resume(with: $0) }
        }
    }
    @MainActor static func select(_ web: WKWebView, id: String, title: String) async throws {
        try await js(web, "window.Galpi.receive({event:'select',data:{id}}); for(let i=0;i<100;i++){if(document.querySelector('#note-title').value===title)return;await new Promise(r=>setTimeout(r,30));} throw Error('Note selection timed out');", arguments: ["id": id, "title": title])
    }
    @MainActor static func waitTheme(_ web: WKWebView, _ theme: String) async throws {
        try await js(web, "for(let i=0;i<100;i++){if(document.documentElement.dataset.themeId===theme)return;await new Promise(r=>setTimeout(r,30));}throw Error('Theme selection timed out');", arguments: ["theme":theme])
    }
    @MainActor static func capture(_ web: WKWebView, _ output: URL, _ name: String) async throws {
        try await js(web, "document.activeElement?.blur(); document.querySelector('#note-page').scrollTop=0; await document.fonts.ready;")
        try await Task.sleep(for: .milliseconds(300))
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 980
        let image = try await web.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError("PNG encoding failed") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
}
