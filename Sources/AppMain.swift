import AppKit
import WebKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var store: Store!
    var window: NSWindow!
    var web: WKWebView!
    var launcher: NSPanel!
    var launcherWeb: WKWebView!
    var statusItem: NSStatusItem!
    var notch: NotchController?
    let shortcuts = Shortcuts()
    let chatGPT = ChatGPT(loadCredentials: ProcessInfo.processInfo.environment["GALPI_UI_TEST"] != "1")
    let claude = ClaudeCLI(enabled: ProcessInfo.processInfo.environment["GALPI_UI_TEST"] != "1")
    var recorder: AudioRecorder?
    var recordingNoteID: String?
    var recordingID: String?
    var recordingStarting = false
    var recordingStopping = false
    var audioPlayer: AVAudioPlayer?
    var playingID: String?
    var timer: Timer?
    var captureMonitor: Any?
    var captureContinuation: CheckedContinuation<Shortcut,Error>?
    var startupNotices: [String] = []
    var jobs = Set<String>()
    var loaded = Set<ObjectIdentifier>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["GALPI_DIAGNOSTICS"]=="1" {fputs("Galpi launch callback\n",stderr)}
        do { store = try Store() }
        catch { let alert=NSAlert();alert.messageText="Galpi를 시작할 수 없어요";alert.informativeText=error.localizedDescription;alert.runModal();NSApp.terminate(nil);return }
        createMenus()
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:680),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="Galpi";window.titlebarAppearsTransparent=true;window.titleVisibility = .hidden
        window.minSize=NSSize(width:500,height:450);window.isReleasedWhenClosed=false;window.delegate=self
        Compatibility.migrateWindowFrame()
        window.setFrameAutosaveName("GalpiMainWindow")
        window.center();web=makeWebView()
        window.contentView=WindowContent(webView:web,headerHeight:52,trailingControlsWidth:154)
        launcher=NSPanel(contentRect:NSRect(x:0,y:0,width:620,height:430),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        launcher.title="Galpi 빠른 실행";launcher.titleVisibility = .hidden;launcher.titlebarAppearsTransparent=true
        launcher.isFloatingPanel=true;launcher.level = .floating;launcher.isReleasedWhenClosed=false;launcher.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        launcherWeb=makeWebView()
        launcher.contentView=WindowContent(webView:launcherWeb,headerHeight:28,trailingControlsWidth:0)
        load(web,launcherMode:false);load(launcherWeb,launcherMode:true)
        applyAppearance();if ProcessInfo.processInfo.environment["GALPI_UI_TEST"] != "1" {configureShortcuts()};createStatusItem()
        notch = NotchController(owner: self, display: ProcessInfo.processInfo.environment["GALPI_UI_TEST"] != "1")
        chatGPT.status={ [weak self] text,error in self?.emit("notice",["message":text,"error":error]);self?.emit("account",self?.chatGPT.publicState() ?? [:]) }
        claude.changed = { [weak self] in self?.emit("claude", self?.claude.publicState() ?? [:]) }
        timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if ProcessInfo.processInfo.environment["GALPI_UI_TEST"] != "1" {showWindow()}
    }
    func makeWebView() -> WKWebView {
        if ProcessInfo.processInfo.environment["GALPI_DIAGNOSTICS"]=="1" {fputs("Create web configuration\n",stderr)}
        let config=WKWebViewConfiguration();config.userContentController.add(self,name:"galpi")
        config.websiteDataStore = .nonPersistent()
        let view=WKWebView(frame:NSRect(x:0,y:0,width:860,height:680),configuration:config);view.navigationDelegate=self
        if ProcessInfo.processInfo.environment["GALPI_DIAGNOSTICS"]=="1" {fputs("Web view created\n",stderr)}
        view.autoresizingMask=[.width,.height]
        return view
    }
    func load(_ view:WKWebView,launcherMode:Bool) {
        let folder=Bundle.main.resourceURL!.absoluteURL
        var url=URLComponents(url:folder.appendingPathComponent("index.html"),resolvingAgainstBaseURL:true)!
        if launcherMode {url.queryItems=[URLQueryItem(name:"launcher",value:"1")]}
        if ProcessInfo.processInfo.environment["GALPI_DIAGNOSTICS"]=="1" {fputs("Loading UI: \(url.url!.path), resource: \(folder.path)\n",stderr)}
        view.loadFileURL(url.url!,allowingReadAccessTo:folder)
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {fputs("Galpi page load: \(error.localizedDescription)\n",stderr)}
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {fputs("Galpi navigation: \(error.localizedDescription)\n",stderr)}
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        if ProcessInfo.processInfo.environment["GALPI_DIAGNOSTICS"]=="1" {
            webView.evaluateJavaScript("JSON.stringify({title:document.title,ready:!!window.Galpi,width:innerWidth,height:innerHeight})") {value,error in print("Galpi UI:",value ?? "nil",error?.localizedDescription ?? "")}
        }
    }
    func createMenus() {
        let menu=NSMenu();NSApp.mainMenu=menu
        let app=NSMenuItem();menu.addItem(app);app.submenu=NSMenu()
        app.submenu?.addItem(withTitle:"Galpi 설정…",action:#selector(openSettings),keyEquivalent:",").target=self
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle:"Galpi 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let edit=NSMenuItem();menu.addItem(edit);edit.submenu=NSMenu(title:"편집")
        for (title,action,key) in [("실행 취소","undo:","z"),("다시 실행","redo:","Z"),("잘라내기","cut:","x"),("복사","copy:","c"),("붙여넣기","paste:","v"),("전체 선택","selectAll:","a")] {
            edit.submenu?.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)
        }
        let file=NSMenuItem();menu.addItem(file);file.submenu=NSMenu(title:"메모")
        file.submenu?.addItem(withTitle:"새 메모",action:#selector(newNote),keyEquivalent:"n").target=self
        file.submenu?.addItem(withTitle:"빠른 실행",action:#selector(toggleLauncher),keyEquivalent:"k").target=self
    }
    func createStatusItem() {
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.image=NSImage(systemSymbolName:"bookmark.fill",accessibilityDescription:"Galpi")
        let menu=NSMenu()
        menu.addItem(withTitle:"메모 열기",action:#selector(showWindow),keyEquivalent:"").target=self
        menu.addItem(withTitle:"노치 열기 / 접기",action:#selector(toggleNotch),keyEquivalent:"").target=self
        menu.addItem(withTitle:"빠른 실행",action:#selector(toggleLauncher),keyEquivalent:"").target=self
        menu.addItem(withTitle:"새 메모",action:#selector(newNote),keyEquivalent:"").target=self
        menu.addItem(.separator());menu.addItem(withTitle:"설정…",action:#selector(openSettings),keyEquivalent:"").target=self
        menu.addItem(.separator());menu.addItem(withTitle:"Galpi 종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
        statusItem.menu=menu
    }
    func configureShortcuts() {
        shortcuts.clear();startupNotices=[]
        do {try shortcuts.register(store.library.preferences.launcher) { [weak self] in self?.toggleLauncher() }} catch { startupNotices.append(error.localizedDescription) }
        for folder in store.library.folders {
            guard let shortcut=folder.shortcut else {continue}
            do {try shortcuts.register(shortcut) { [weak self] in do {try self?.openFolder(folder.id)} catch {self?.emit("notice",["message":error.localizedDescription,"error":true])} }} catch {startupNotices.append(error.localizedDescription)}
        }
        do { try shortcuts.register(store.library.preferences.effectiveMemoShortcut) { [weak self] in self?.toggleMemo() } }
        catch { startupNotices.append("메모 창 단축키: " + error.localizedDescription) }
        if store.library.preferences.notchEnabled ?? true {
            do { try shortcuts.register(store.library.preferences.effectiveNotchShortcut) { [weak self] in self?.toggleNotch() } }
            catch { startupNotices.append("노치 단축키: " + error.localizedDescription) }
        }
    }
    @objc func toggleNotch() { notch?.toggle() }
    @objc func toggleMemo() {
        if window.isKeyWindow && window.isVisible { flush { self.window.orderOut(nil) } }
        else { openMemo() }
    }
    func openMemo(noteID: String? = nil) {
        flush { [weak self] in
            guard let self else { return }
            do {
                let candidate = noteID ?? self.store.library.selectedNoteID
                let note = try self.store.library.notes.first { $0.id == candidate && !$0.deleted } ?? self.store.library.notes.first { !$0.deleted } ?? self.store.create()
                self.broadcast(); self.showWindow(); self.emit("openMemo", ["id": note.id], only: self.web)
            } catch { self.emitError(error) }
        }
    }
    @objc func showWindow() {
        notch?.collapse();launcher?.orderOut(nil)
        if ProcessInfo.processInfo.environment["GALPI_UI_TEST"] == "1" && ProcessInfo.processInfo.environment["GALPI_UI_TEST_BACKGROUND"] == "1" {return}
        NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
    }
    @objc func newNote() {do {let note=try store.create();broadcast();showWindow();emit("select",["id":note.id])}catch{emitError(error)}}
    @objc func openSettings() {showWindow();emit("settings",[:])}
    @objc func toggleLauncher() {
        if launcher.isVisible {launcher.orderOut(nil);return}
        if let screen=NSScreen.main {let f=screen.visibleFrame;launcher.setFrameOrigin(NSPoint(x:f.midX-310,y:f.midY+50))}
        NSApp.activate(ignoringOtherApps:true);launcher.makeKeyAndOrderFront(nil)
        broadcast();emit("launcher",[:],only:launcherWeb)
    }
    func applyAppearance() {
        let theme=store.library.preferences.theme ?? "system"
        let custom=(store.library.preferences.customThemes ?? []).first{$0.id==theme}
        switch custom.map({$0.isDark ? "dark":"light"}) ?? theme {
        case "light":NSApp.appearance=NSAppearance(named:.aqua)
        case "dark":NSApp.appearance=NSAppearance(named:.darkAqua)
        default:NSApp.appearance=nil
        }
        window.level=store.library.preferences.alwaysOnTop ? .floating : .normal
        window.collectionBehavior=store.library.preferences.alwaysOnTop ? [.canJoinAllSpaces,.fullScreenAuxiliary] : [.managed]
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        flush {sender.orderOut(nil)};return false
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showWindow();return true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if recorder != nil || recordingStarting {
            let alert=NSAlert();alert.messageText="녹음을 저장하고 종료할까요?";alert.addButton(withTitle:"저장하고 종료");alert.addButton(withTitle:"계속 녹음")
            guard alert.runModal() == .alertFirstButtonReturn else {return .terminateCancel}
        }
        flush(onFailure: { NSApp.reply(toApplicationShouldTerminate:false) }) { [weak self] in
            Task { @MainActor in
                do {
                    if self?.recorder != nil {try await self?.stopRecording()}
                    try self?.store.persist();self?.chatGPT.cancelLogin();self?.claude.cancelLogin();CLICommand.cancelAll();NSApp.reply(toApplicationShouldTerminate:true)
                } catch { self?.emitError(error);NSApp.reply(toApplicationShouldTerminate:false) }
            }
        };return .terminateLater
    }
    func flush(onFailure:@escaping ()->Void = {}, _ completion:@escaping ()->Void) {
        guard web != nil else {completion();return}
        web.callAsyncJavaScript("await window.Galpi?.flushAsync()",arguments:[:],in:nil,in:.page) { result in
            DispatchQueue.main.async {
                switch result {
                case .success: completion()
                case .failure(let error): self.emitError(error);onFailure()
                }
            }
        }
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        guard let url=action.request.url else {decisionHandler(.cancel);return}
        let resourcePath=Bundle.main.resourceURL!.standardizedFileURL.path
        let prefix=resourcePath.hasSuffix("/") ? resourcePath : resourcePath+"/"
        if ProcessInfo.processInfo.environment["GALPI_DIAGNOSTICS"]=="1" {fputs("Navigation UI: \(url.path), prefix: \(prefix)\n",stderr)}
        if url.isFileURL, url.standardizedFileURL.path.hasPrefix(prefix) {decisionHandler(.allow)}
        else if action.navigationType == .linkActivated, ["https","http"].contains(url.scheme ?? "") {NSWorkspace.shared.open(url);decisionHandler(.cancel)}
        else {decisionHandler(.cancel)}
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.frameInfo.isMainFrame,let body=message.body as? [String:Any],let id=body["id"] as? String,let action=body["action"] as? String,let view=message.webView else {return}
        let arguments=body["arguments"] as? [String:Any] ?? [:]
        Task { @MainActor in
            do {let result=try await handle(action,arguments,source:view);reply(view,id:id,result:result)}
            catch {reply(view,id:id,error:error.localizedDescription)}
        }
    }
    func reply(_ view:WKWebView,id:String,result:Any=[:],error:String?=nil) {
        var body:[String:Any]=["id":id,"result":result];if let error {body["error"]=error}
        send(body,to:view)
    }
    func send(_ body:[String:Any],to view:WKWebView) {
        guard let data=try? JSONSerialization.data(withJSONObject:body,options:[.fragmentsAllowed]),let json=String(data:data,encoding:.utf8) else {return}
        view.evaluateJavaScript("window.Galpi?.receive(\(json))",completionHandler:nil)
    }
    func emit(_ event:String,_ data:Any,only:WKWebView?=nil) {
        for view in only.map({[$0]}) ?? [web,launcherWeb].compactMap({$0}) where loaded.contains(ObjectIdentifier(view)) {send(["event":event,"data":data],to:view)}
    }
    func emitError(_ error:Error){emit("notice",["message":error.localizedDescription,"error":true])}
    func broadcast(){if let state=try? store.snapshot(){emit("state",state)};notch?.refresh()}
    func tick() {
        let recording:[String:Any] = ["active":recorder != nil,"noteID":recordingNoteID ?? "","duration":recorder?.duration ?? 0,"paused":recorder?.isPaused ?? false]
        emit("recording",recording)
        let playbackState: [String: Any] = ["id":playingID ?? "","playing":audioPlayer?.isPlaying ?? false,"time":audioPlayer?.currentTime ?? 0.0,"duration":audioPlayer?.duration ?? 0.0]
        emit("playback",playbackState)
        statusItem?.button?.title=recorder != nil ? " ● \(Int(recorder?.duration ?? 0)/60)m" : ""
        notch?.refresh()
    }
    func handle(_ action:String,_ a:[String:Any],source:WKWebView) async throws -> Any {
        let id=a["noteID"] as? String ?? store.library.selectedNoteID ?? ""
        switch action {
        case "ready":
            loaded.insert(ObjectIdentifier(source))
            return ["library":try store.snapshot(),"account":chatGPT.publicState(),"claude":claude.publicState(),"notices":startupNotices,"dataPath":store.root.path]
        case "save":
            try store.update(id) {note in
                if let title=a["title"] as? String {note.title=title.isEmpty ? "제목 없는 메모" : String(title.prefix(500))}
                if let text=a["markdown"] as? String {note.markdown=text;note.document=a["document"] as? String}
                if let text=a["summary"] as? String {note.summary=text}
                if let text=a["transcript"] as? String {note.transcript=text}
            };notch?.refresh();return ["saved":true]
        case "create":
            let n=try store.create();broadcast();if source===launcherWeb {launcher.orderOut(nil);showWindow()};emit("select",["id":n.id]);return ["id":n.id]
        case "select":
            _=try store.note(id);store.library.selectedNoteID=id;try store.persist();notch?.refresh()
            if source===launcherWeb {launcher.orderOut(nil);showWindow();emit("select",["id":id],only:web)}
            return try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.note(id)))
        case "pin":try store.update(id) {$0.pinned.toggle()};broadcast();return [:]
        case "trash":
            guard recordingNoteID != id,!jobs.contains(id) else {throw AppError("녹음이나 회의록 작업이 끝난 뒤 메모를 보관해 주세요.")}
            try store.update(id) {$0.deleted=true};broadcast();return [:]
        case "restore":try store.update(id) {$0.deleted=false};broadcast();return [:]
        case "export":
            let note=try store.note(id);let panel=NSSavePanel();panel.nameFieldStringValue=note.title.replacingOccurrences(of:"/",with:"-")+".md";panel.allowedContentTypes=[.plainText]
            guard panel.runModal() == .OK,let url=panel.url else {return [:]}
            let field=a["field"] as? String ?? "memo"
            let content=field=="summary" ? note.summary : field=="transcript" ? note.transcript : note.markdown
            try Data(("# "+note.title+"\n\n"+content).utf8).write(to:url,options:.atomic);return [:]
        case "import":
            let panel=NSOpenPanel();panel.allowedContentTypes=[.plainText];panel.allowsMultipleSelection=false
            guard panel.runModal() == .OK,let url=panel.url else {return [:]}
            let text=try String(contentsOf:url,encoding:.utf8)
            let note=try store.create(title:url.deletingPathExtension().lastPathComponent,markdown:text)
            broadcast();emit("select",["id":note.id]);return [:]
        case "compact":
            store.library.preferences.compact.toggle();try store.persist()
            var frame=window.frame;frame.size.width=store.library.preferences.compact ? 550 : 860;window.setFrame(frame,display:true,animate:true);broadcast();return [:]
        case "top":store.library.preferences.alwaysOnTop.toggle();try store.persist();applyAppearance();broadcast();return [:]
        case "addFolder":
            let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt="폴더 등록"
            guard panel.runModal() == .OK,let url=panel.url else {return [:]}
            if store.library.folders.contains(where:{$0.path==url.path}){throw AppError("이미 등록한 폴더예요.")}
            let bookmark=try? url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
            store.library.folders.append(Folder(name:url.lastPathComponent,path:url.path,bookmark:bookmark));try store.persist();broadcast();return [:]
        case "renameFolder":
            guard let folderID=a["folderID"] as? String,let i=store.library.folders.firstIndex(where:{$0.id==folderID}),let name=a["name"] as? String,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AppError("폴더 이름을 입력해 주세요.")}
            store.library.folders[i].name=String(name.prefix(200));try store.persist();broadcast();return [:]
        case "removeFolder":
            let folderID=a["folderID"] as? String;store.library.folders.removeAll {$0.id==folderID};try store.persist();configureShortcuts();broadcast();return [:]
        case "openFolder":try openFolder(a["folderID"] as? String ?? "");launcher.orderOut(nil);return [:]
        case "shortcut":
            let target=a["folderID"] as? String
            let shortcut=try await captureShortcut()
            let old=store.library
            if let target,let i=store.library.folders.firstIndex(where:{$0.id==target}) {store.library.folders[i].shortcut=shortcut}
            else if a["target"] as? String == "memo" {store.library.preferences.memoShortcut=shortcut}
            else if a["target"] as? String == "notch" {store.library.preferences.notchShortcut=shortcut}
            else {store.library.preferences.launcher=shortcut}
            configureShortcuts()
            if !startupNotices.isEmpty {let error=startupNotices.joined(separator:"\n");store.library=old;configureShortcuts();throw AppError(error)}
            do {try store.persist()} catch {store.library=old;configureShortcuts();throw error};broadcast();return [:]
        case "clearShortcut":
            if let i=store.library.folders.firstIndex(where:{$0.id==a["folderID"] as? String}){store.library.folders[i].shortcut=nil}
            try store.persist();configureShortcuts();broadcast();return [:]
        case "cancelShortcut":cancelCapture();return [:]
        case "settings":showWindow();emit("settings",[:],only:web);return [:]
        case "hideLauncher":launcher.orderOut(nil);return [:]
        case "dataFolder":NSWorkspace.shared.open(store.root);return [:]
        case "link":
            let alert=NSAlert();alert.messageText="링크 주소";alert.addButton(withTitle:"적용");alert.addButton(withTitle:"취소")
            let input=NSTextField(frame:NSRect(x:0,y:0,width:340,height:26));input.stringValue=a["url"] as? String ?? "";input.placeholderString="https://…";alert.accessoryView=input
            guard alert.runModal() == .alertFirstButtonReturn else {return ["cancelled":true]}
            let value=input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if !value.isEmpty {guard let url=URL(string:value),["http","https","mailto"].contains(url.scheme ?? "") else {throw AppError("http, https 또는 mailto 링크를 입력해 주세요.")}}
            return ["url":value]
        case "preferences":
            let previous=store.library.preferences
            if let provider = a["aiProvider"] as? String, !["chatgpt", "claude"].contains(provider) { throw AppError("지원하지 않는 AI 서비스예요.") }
            if let model = a["claudeModel"] as? String, !ClaudeModels.supported.contains(model) { throw AppError("지원하지 않는 Claude 모델이에요.") }
            if let theme=a["theme"] as? String {
                guard ["system","light","dark"].contains(theme) || (store.library.preferences.customThemes ?? []).contains(where:{$0.id==theme}) else {throw AppError("지원하지 않는 화면 모드예요.")}
                store.library.preferences.theme=theme
            }
            if let enabled=a["notchEnabled"] as? Bool {store.library.preferences.notchEnabled=enabled}
            if let locale=a["locale"] as? String {store.library.preferences.locale=locale}
            if let model=a["model"] as? String {store.library.preferences.model=model}
            if let provider=a["aiProvider"] as? String {store.library.preferences.aiProvider=provider}
            if let model=a["claudeModel"] as? String {store.library.preferences.claudeModel=model}
            do {try store.persist()}catch{store.library.preferences=previous;throw error}
            if a["notchEnabled"] != nil && ProcessInfo.processInfo.environment["GALPI_UI_TEST"] != "1" {configureShortcuts();if !startupNotices.isEmpty {emit("notice",["message":startupNotices.joined(separator:"\n"),"error":true])}}
            applyAppearance();broadcast();return [:]
        case "saveTheme":
            guard let name=a["name"] as? String,let colors=a["colors"] as? [String:String] else {throw AppError("테마 이름과 색상을 입력해 주세요.")}
            let theme=try store.saveTheme(name:name,colors:colors,id:a["themeID"] as? String)
            applyAppearance();broadcast();return ["id":theme.id]
        case "removeTheme":
            try store.removeTheme(a["themeID"] as? String ?? "");applyAppearance();broadcast();return [:]
        case "importTheme":
            let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false;panel.prompt="테마 가져오기"
            guard panel.runModal() == .OK,let url=panel.url else {return [:]}
            guard let data=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any],data["version"] as? Int==1,let name=data["name"] as? String,let colors=data["colors"] as? [String:String] else {throw AppError("Galpi 테마 파일 형식이 아니에요.")}
            let theme=try store.saveTheme(name:name,colors:colors);applyAppearance();broadcast();return ["id":theme.id]
        case "exportTheme":
            guard let theme=(store.library.preferences.customThemes ?? []).first(where:{$0.id==a["themeID"] as? String}) else {throw AppError("테마를 찾지 못했어요.")}
            let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue=theme.name.replacingOccurrences(of:"/",with:"-")+".galpi-theme.json"
            guard panel.runModal() == .OK,let url=panel.url else {return [:]}
            let data=try JSONSerialization.data(withJSONObject:["version":1,"name":theme.name,"colors":theme.colors],options:[.prettyPrinted,.sortedKeys]);try data.write(to:url,options:.atomic);return [:]
        case "locales":return await LocalTranscription.locales()
        case "claudeStatus":try await claude.refresh();return claude.publicState()
        case "claudeSignIn":try claude.signIn();return claude.publicState()
        case "claudeCancelLogin":claude.cancelLogin();return claude.publicState()
        case "claudeInstall":NSWorkspace.shared.open(URL(string:"https://code.claude.com/docs/en/setup")!);return [:]
        case "claudeLoginCommand":NSPasteboard.general.clearContents();NSPasteboard.general.setString("claude auth login",forType:.string);return [:]
        case "signIn":try await chatGPT.signIn(existingID:a["accountID"] as? String);return [:]
        case "cancelLogin":chatGPT.cancelLogin();return [:]
        case "signOut":defer{emit("account",chatGPT.publicState())};try await chatGPT.signOut();return [:]
        case "selectAccount":try chatGPT.select(a["accountID"] as? String ?? "");store.library.preferences.model="";try store.persist();emit("account",chatGPT.publicState());broadcast();return [:]
        case "models":return try await chatGPT.models()
        case "record":try await startRecording(noteID:id,mode:a["mode"] as? String ?? "inperson");return [:]
        case "pause":recorder?.togglePause();tick();return [:]
        case "stop":try await stopRecording();return [:]
        case "play":
            let note=try store.note(id);let recID=a["recordingID"] as? String
            guard let recording=note.recordings.first(where:{$0.id==recID}),let file=recording.playbackFile ?? recording.tracks.first?.file else {throw AppError("재생할 녹음 파일이 없어요.")}
            if playingID==recID,let player=audioPlayer {if player.isPlaying{player.pause()}else{player.play()}}
            else {audioPlayer?.stop();audioPlayer=try AVAudioPlayer(contentsOf:store.recordingDirectory(recording.id).appendingPathComponent(file));playingID=recID;audioPlayer?.play()};tick();return [:]
        case "seek":audioPlayer?.currentTime=a["seconds"] as? Double ?? 0;return [:]
        case "revealRecording":
            let note=try store.note(id);guard let r=note.recordings.first(where:{$0.id==a["recordingID"] as? String}) else {throw AppError("녹음을 찾지 못했어요.")}
            NSWorkspace.shared.open(store.recordingDirectory(r.id));return [:]
        case "transcribe","summarize":
            guard !jobs.contains(id),recordingNoteID != id else {throw AppError("진행 중인 작업이 끝난 뒤 다시 시도해 주세요.")}
            let provider = store.library.preferences.effectiveAIProvider
            let model = provider == "claude" ? store.library.preferences.effectiveClaudeModel : store.library.preferences.model
            jobs.insert(id);defer{jobs.remove(id);emit("job",["noteID":id,"message":"","busy":false])}
            let progress:(String)->Void = { [weak self] message in Task { @MainActor in self?.emit("job",["noteID":id,"message":message,"busy":true]) } }
            let needsTranscript = try store.note(id).transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            if action=="transcribe" || needsTranscript {try await transcribe(id,progress:progress)}
            if action=="summarize" {
                let original=try store.note(id)
                guard !original.transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AppError("전체 기록에 전사문이 있어야 회의록을 만들 수 있어요.")}
                let text="회의 제목: \(original.title)\n\n직접 쓴 메모:\n\(original.markdown)\n\n회의 대화 기록:\n\(original.transcript)"
                let summary: String
                if provider == "claude" { summary = try await claude.summarize(text:text,model:model,progress:progress) }
                else { summary = try await chatGPT.summarize(text:text,model:model,progress:progress) }
                let latest=try store.note(id);try store.archiveSummary(latest)
                if latest.summary != original.summary {
                    let generated=try store.create(title:latest.title+" · 새 회의록",markdown:summary);emit("notice",["message":"수정 중인 회의록을 보존하고 새 메모에 생성했어요.","error":false]);emit("select",["id":generated.id])
                } else {try store.update(id){$0.summary=summary}}
            }
            broadcast();return try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.note(id)))
        default:throw AppError("지원하지 않는 명령이에요.")
        }
    }
    func openFolder(_ id:String) throws {
        guard let i=store.library.folders.firstIndex(where:{$0.id==id}) else {throw AppError("등록된 폴더를 찾지 못했어요.")}
        var folder=store.library.folders[i];var url=URL(fileURLWithPath:folder.path)
        if let bookmark=folder.bookmark {var stale=false;if let resolved=try? URL(resolvingBookmarkData:bookmark,options:[],relativeTo:nil,bookmarkDataIsStale:&stale){url=resolved;if stale || resolved.path != folder.path {folder.path=resolved.path;folder.bookmark=try? resolved.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil);store.library.folders[i]=folder;try store.persist()}}}
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory),isDirectory.boolValue else {throw AppError("폴더가 이동되거나 삭제됐어요. 설정에서 다시 등록해 주세요.")}
        NSWorkspace.shared.open(url)
    }
    func captureShortcut() async throws -> Shortcut {
        guard captureContinuation==nil else {throw AppError("이미 단축키를 입력받고 있어요.")}
        return try await withCheckedThrowingContinuation { continuation in
            captureContinuation=continuation
            captureMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                guard let self else {return event}
                if event.keyCode==53 {self.cancelCapture();return nil}
                do {let shortcut=try Shortcuts.from(event);self.finishCapture(.success(shortcut))}catch{self.finishCapture(.failure(error))};return nil
            }
        }
    }
    func finishCapture(_ result:Result<Shortcut,Error>) {if let monitor=captureMonitor{NSEvent.removeMonitor(monitor)};captureMonitor=nil;let c=captureContinuation;captureContinuation=nil;c?.resume(with:result)}
    func cancelCapture(){finishCapture(.failure(AppError("단축키 설정을 취소했어요.")))}
    func startRecording(noteID:String,mode:String) async throws {
        guard recorder==nil,!recordingStarting,!recordingStopping else {throw AppError("다른 녹음이 진행 중이에요.")}
        _=try store.note(noteID);recordingStarting=true;defer{recordingStarting=false}
        let record=Recording(mode:mode);try store.update(noteID){$0.recordings.append(record)}
        let recorder=AudioRecorder()
        recorder.failure={ [weak self] message in
            guard let self,!self.recordingStopping else {return}
            self.emit("notice",["message":message,"error":true]);Task {try? await self.stopRecording()}
        }
        do {
            audioPlayer?.stop();try await recorder.start(mode:mode,directory:store.recordingDirectory(record.id))
            self.recorder=recorder;recordingNoteID=noteID;recordingID=record.id;broadcast();tick()
        } catch {try? store.update(noteID){n in if let i=n.recordings.firstIndex(where:{$0.id==record.id}){n.recordings[i].status="failed"}};broadcast();throw error}
    }
    func stopRecording() async throws {
        guard let recorder,let noteID=recordingNoteID,let id=recordingID,!recordingStopping else {return}
        recordingStopping=true;defer{self.recorder=nil;recordingID=nil;recordingNoteID=nil;recordingStopping=false;broadcast();tick()}
        let result:(Double,[AudioTrack])
        do {result=try await recorder.stop()}catch{try? store.update(noteID){n in if let i=n.recordings.firstIndex(where:{$0.id==id}){n.recordings[i].status="interrupted"}};throw error}
        try store.update(noteID){n in if let i=n.recordings.firstIndex(where:{$0.id==id}){n.recordings[i].duration=result.0;n.recordings[i].tracks=result.1;n.recordings[i].status=recorder.wasInterrupted ? "interrupted" : "saved"}}
        do {
            let file=try await AudioRecorder.mix(directory:store.recordingDirectory(id),tracks:result.1)
            try store.update(noteID){n in if let i=n.recordings.firstIndex(where:{$0.id==id}){n.recordings[i].playbackFile=file}}
        } catch {emit("notice",["message":"재생용 파일 변환에 실패했어요. 원본 녹음은 보존됐으며 '녹음 폴더 열기'에서 확인할 수 있어요.","error":true])}
    }
    func transcribe(_ id:String,progress:@escaping (String)->Void) async throws {
        let note=try store.note(id)
        let recordings=note.recordings.filter{!$0.tracks.isEmpty && $0.status != "recording"}
        guard !recordings.isEmpty else {throw AppError("먼저 녹음하거나 전체 기록 탭에 전사문을 붙여넣어 주세요.")}
        var sections:[String]=[]
        for (index,recording) in recordings.enumerated() {
            var segments:[TranscriptSegment]=[]
            for track in recording.tracks {
                progress("녹음 \(index+1)/\(recordings.count) · \(track.label) 변환 중…")
                segments += try await LocalTranscription.transcribe(url:store.recordingDirectory(recording.id).appendingPathComponent(track.file),locale:Locale(identifier:store.library.preferences.locale),source:track.label,offset:track.offset,progress:progress)
            }
            let recognized=segments.filter{!$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
            if !recognized.isEmpty {sections.append("## 녹음 \(index+1)\n\n"+LocalTranscription.markdown(recognized))}
        }
        let result=sections.joined(separator:"\n\n---\n\n")
        guard !sections.isEmpty else {throw AppError("인식된 음성이 없어요. 녹음 내용과 언어를 확인해 주세요.")}
        let latest=try store.note(id)
        // Never discard a transcript edited while transcription was running.
        try store.update(id){$0.transcript=latest.transcript==note.transcript ? result : latest.transcript+"\n\n## 새 전사 결과\n\n"+result}
    }
}

#if !UITEST
@main struct GalpiMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in do {try await SelfTest.run();print("Galpi self-tests passed");exit(0)}catch{fputs("Self-test failed: \(error)\n",stderr);exit(1)} };RunLoop.main.run();return
        }
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=AppDelegate();app.delegate=delegate;app.run();withExtendedLifetime(delegate){}
    }
}
#endif
