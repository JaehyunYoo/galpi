import AppKit
import WebKit

@main struct UITest {
    @MainActor static func main() {
        guard ProcessInfo.processInfo.environment["GALPI_UI_TEST"]=="1",ProcessInfo.processInfo.environment["GALPI_DATA_DIR"] != nil,CommandLine.arguments.count>1 else {fatalError("Use test-ui.sh with an isolated data directory")}
        let script=try! String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let delegate=AppDelegate();app.delegate=delegate
        Task { @MainActor in
            do {
                while delegate.web == nil {try await Task.sleep(for:.milliseconds(50))}
                if ProcessInfo.processInfo.environment["GALPI_UI_TEST_BACKGROUND"] != "1" {
                    delegate.window.makeKeyAndOrderFront(nil)
                    app.activate(ignoringOtherApps: true)
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(45))
                    fputs("UI test timed out\n", stderr);exit(1)
                }
                while !delegate.loaded.contains(ObjectIdentifier(delegate.web)) || !delegate.loaded.contains(ObjectIdentifier(delegate.launcherWeb)) {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let result:Any?=try await withCheckedThrowingContinuation { continuation in
                    delegate.web.callAsyncJavaScript(script,arguments:[:],in:nil,in:.page) {continuation.resume(with:$0)}
                }
                let note=delegate.store.library.notes.first{$0.title=="한글 메모 📝"}
                guard let note,!note.deleted,note.markdown.contains("메모 본문 테스트"),note.transcript.contains("회의 전사 테스트") else {throw AppError("Native saved note verification failed")}
                try await Task.sleep(for:.seconds(1))
                guard try delegate.store.note(note.id).updated==note.updated else {throw AppError("Idle UI must not modify or save a note")}
                let reloaded=try Store(root:delegate.store.root)
                guard try reloaded.note(note.id).markdown==note.markdown,try reloaded.note(note.id).document==note.document else {throw AppError("UI to disk roundtrip failed")}
                guard let code=reloaded.library.notes.first(where:{$0.title=="코드 색상 테스트"}),
                      code.markdown.contains("```javascript"),code.markdown.contains("Hello, Galpi"),
                      let document=code.document,let json=try JSONSerialization.jsonObject(with:Data(document.utf8)) as? [String:Any],
                      let content=json["content"] as? [[String:Any]],
                      content.contains(where:{$0["type"] as? String=="codeBlock" && ($0["attrs"] as? [String:Any])?["language"] as? String=="javascript"}) else {throw AppError("Code language must persist in both Markdown and editor JSON")}
                guard let theme=reloaded.library.preferences.customThemes?.first,theme.name=="미드나이트 수정",theme.colors["paper"]=="#142033",theme.isDark,reloaded.library.preferences.theme==theme.id else {throw AppError("Custom theme persistence failed")}
                guard delegate.window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,delegate.launcher.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua else {throw AppError("Native window appearance did not follow theme")}
                let launcherColor:Any?=try await withCheckedThrowingContinuation { continuation in delegate.launcherWeb.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") {value,error in if let error{continuation.resume(throwing:error)}else{continuation.resume(returning:value)}} }
                guard launcherColor as? String=="rgb(20, 32, 51)" else {throw AppError("Launcher theme is inconsistent")}
                if let path=ProcessInfo.processInfo.environment["GALPI_UI_SCREENSHOT_DIR"] {
                    let directory=URL(fileURLWithPath:path)
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    for theme in ["light","dark"] {
                        let _:Any? = try await withCheckedThrowingContinuation { continuation in
                            delegate.web.callAsyncJavaScript("document.querySelector('[data-theme-choice='+theme+']').click(); for(let i=0;i<100 && document.documentElement.dataset.themeId!==theme;i++) await new Promise(r=>setTimeout(r,20));",arguments:["theme":theme],in:nil,in:.page) { continuation.resume(with:$0) }
                        }
                        let image=try await delegate.web.takeSnapshot(configuration:nil)
                        guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw AppError("Screenshot encoding failed")}
                        try png.write(to:directory.appendingPathComponent("Galpi-code-\(theme).png"))
                    }
                }
                let aiPreferences = try Store(root: delegate.store.root).library.preferences
                guard aiPreferences.effectiveAIProvider == "claude", aiPreferences.effectiveClaudeModel == "claude-opus-5-5" else { throw AppError("Claude provider/model persistence failed") }
                guard let notch = delegate.notch else { throw AppError("Missing notch controller") }
                notch.refresh(); notch.toggle()
                guard notch.state.expanded, let geometry = notch.geometry,
                      abs(notch.panel.frame.maxY - geometry.screen.maxY) < 1,
                      notch.state.notes.contains(where: { $0.id == code.id }) else { throw AppError("Notch content / anchor failed") }
                notch.act(.recordOptions)
                guard notch.state.recordingOptions, delegate.recorder == nil else { throw AppError("Opening recording choices must not start recording") }
                notch.act(.collapse)
                guard !notch.state.expanded, !notch.state.recordingOptions else { throw AppError("Notch collapse failed") }
                notch.act(.collapse)
                guard !notch.state.expanded, abs(notch.panel.frame.width - geometry.collapsedSize.width) < 1, abs(notch.panel.frame.height - geometry.collapsedSize.height) < 1 else { throw AppError("Repeated collapse must stay collapsed with the compact frame") }
                notch.toggle(); notch.toggle()
                guard !notch.state.expanded, !notch.panel.isKeyWindow else { throw AppError("Toggle must use the same collapse and release focus") }
                if ProcessInfo.processInfo.environment["GALPI_TEST_NOTCH_CLICKS"] == "1" {
                    // Deliver local mouse events to the real hosting view, without moving
                    // the user's pointer or posting keyboard events to another app.
                    for offset in [NSPoint(x: 0, y: 0), NSPoint(x: -12, y: 9), NSPoint(x: 12, y: -9)] {
                        notch.toggle()
                        notch.panel.orderFrontRegardless()
                        try await Task.sleep(for: .milliseconds(150))
                        notch.panel.contentView?.layoutSubtreeIfNeeded()
                        let point = NSPoint(x: notch.panel.frame.width - 36 + offset.x,
                                            y: notch.panel.frame.height - geometry.topInset - 22 + offset.y)
                        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: notch.panel.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime + 0.05, windowNumber: notch.panel.windowNumber,
                            context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
                        app.postEvent(down, atStart: false); app.postEvent(up, atStart: false)
                        try await Task.sleep(for: .milliseconds(250))
                        guard !notch.state.expanded else { throw AppError("Collapse button did not receive click at offset \(offset)") }
                    }
                    notch.panel.orderOut(nil)
                    print("Native collapse button center and padding clicks passed")
                }
                _ = try await delegate.handle("preferences", ["notchEnabled": false], source: delegate.web)
                guard !notch.panel.isVisible, try Store(root: delegate.store.root).library.preferences.notchEnabled == false else { throw AppError("Notch opt-out persistence failed") }
                _ = try await delegate.handle("preferences", ["notchEnabled": true], source: delegate.web)
                let _: Any? = try await withCheckedThrowingContinuation { continuation in
                    delegate.web.callAsyncJavaScript("const body=document.querySelector('#editor .tiptap');body.focus();const range=document.createRange();range.selectNodeContents(document.querySelector('#editor pre code'));range.collapse(false);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);document.execCommand('insertText',false,' // pending-notch-save');", arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
                }
                delegate.openMemo(noteID: note.id)
                let _: Any? = try await withCheckedThrowingContinuation { continuation in
                    delegate.web.callAsyncJavaScript("for(let i=0;i<120;i++){if(document.querySelector('#note-title').value==='한글 메모 📝')return;await new Promise(r=>setTimeout(r,30));}throw Error('Notch note selection failed');", arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
                }
                guard try Store(root: delegate.store.root).note(code.id).markdown.contains("pending-notch-save"),
                      delegate.store.library.selectedNoteID == note.id else { throw AppError("Opening memo must flush pending edits and select requested note") }
                print("Notch position, recording choices, toggle persistence and unsaved-note handoff passed")
                print(result ?? "No result");print("Native WKWebView UI + disk roundtrip passed");exit(0)
            } catch {fputs("UI test failed: \(error) \((error as NSError).userInfo)\n",stderr);exit(1)}
        }
        app.run();withExtendedLifetime(delegate){}
    }
}
