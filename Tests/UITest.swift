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
                try await Task.sleep(for:.seconds(1))
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
                print(result ?? "No result");print("Native WKWebView UI + disk roundtrip passed");exit(0)
            } catch {fputs("UI test failed: \(error) \((error as NSError).userInfo)\n",stderr);exit(1)}
        }
        app.run();withExtendedLifetime(delegate){}
    }
}
