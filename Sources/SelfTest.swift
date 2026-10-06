import Foundation
import AVFoundation

enum SelfTest {
    @MainActor static func run() async throws {
        guard let path=ProcessInfo.processInfo.environment["GALPI_SELFTEST_DIR"] else {throw AppError("Set GALPI_SELFTEST_DIR to a scratch directory.")}
        // Exercise the real loopback listener without opening a browser or exchanging credentials.
        var authorizationURL: URL?
        let login=ChatGPT(loadCredentials:false,openBrowser:{authorizationURL=$0;return true})
        try await login.signIn()
        guard let url=authorizationURL,let components=URLComponents(url:url,resolvingAgainstBaseURL:false),components.host=="auth.openai.com" else {throw AppError("Login did not open the authorization URL")}
        let params=Dictionary(uniqueKeysWithValues:(components.queryItems ?? []).map{($0.name,$0.value ?? "")})
        guard params["client_id"]=="dynamic_agent_client",let redirect=params["redirect_uri"],let state=params["state"],params["code_challenge"]?.count==43 else {throw AppError("Login request contract failed")}
        let bad=URL(string:redirect+"?state=wrong&error=access_denied")!
        let (_,badResponse)=try await URLSession.shared.data(from:bad)
        guard (badResponse as? HTTPURLResponse)?.statusCode==400,login.publicState()["signingIn"] as? Bool==true else {throw AppError("Invalid login state must not terminate the real attempt")}
        let denied=URL(string:redirect+"?state="+state+"&error=access_denied")!
        let (_,deniedResponse)=try await URLSession.shared.data(from:denied)
        guard (deniedResponse as? HTTPURLResponse)?.statusCode==200,login.publicState()["signingIn"] as? Bool==false,login.current==nil else {throw AppError("Cancelled login was not cleaned up")}
        let failedBrowser=ChatGPT(loadCredentials:false,openBrowser:{_ in false})
        var openFailed=false
        do {try await failedBrowser.signIn()}catch{openFailed=true}
        guard openFailed,failedBrowser.publicState()["signingIn"] as? Bool==false else {throw AppError("Browser open failure must clear the login attempt")}
        print("OAuth loopback start, state validation, denial and browser failure passed.")
        let root=URL(fileURLWithPath:path).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=try Store(root:root.appendingPathComponent("Library"))
        try welcomeMigration(root: root.appendingPathComponent("WelcomeMigration"))
        try dataFolderMigration(root: root.appendingPathComponent("DataMigration"))
        let note=try store.create(title:"한글 📝 보존",markdown:"## 회의\n\n- [x] 확인\n- [ ] 다음 일\n\n```swift\nlet value = 42\n```")
        try store.update(note.id){$0.summary="기존 회의록";$0.transcript="[00:42] 회의 발언";$0.pinned=true}
        try store.archiveSummary(store.note(note.id))
        let restored=try Store(root:store.root)
        guard try restored.note(note.id).markdown==note.markdown,try restored.note(note.id).pinned else {throw AppError("Persistence roundtrip failed")}
        try restored.update(note.id){$0.deleted=true};try restored.update(note.id){$0.deleted=false}
        guard try !restored.note(note.id).deleted else {throw AppError("Restore failed")}
        let theme=try restored.saveTheme(name:"테스트 다크",colors:["paper":"#112233","side":"#152536","ink":"#eeeeee","dim":"#aaaaaa","line":"#334455","blue":"#aabbcc"])
        let themed=try Store(root:restored.root)
        guard themed.library.preferences.theme==theme.id,themed.library.preferences.customThemes?.first?.isDark==true else {throw AppError("Theme persistence failed")}
        var rejected=false;do{_=try themed.saveTheme(name:"잘못된 테마",colors:["paper":"url(https://example.com)"])}catch{rejected=true}
        guard rejected,themed.library.preferences.customThemes?.count==1 else {throw AppError("Invalid theme altered saved themes")}
        try themed.removeTheme(theme.id)
        guard themed.library.preferences.theme=="dark",themed.library.preferences.customThemes?.isEmpty==true else {throw AppError("Deleting active theme must restore a built-in theme")}
        let archive=root.appendingPathComponent("Library/History/\(note.id)")
        guard try FileManager.default.contentsOfDirectory(atPath:archive.path).count==1 else {throw AppError("Summary archive missing")}
        let broken=root.appendingPathComponent("Broken");try FileManager.default.createDirectory(at:broken,withIntermediateDirectories:true)
        let original=Data("{bad-json".utf8);try original.write(to:broken.appendingPathComponent("library.json"))
        var failed=false;do{_=try Store(root:broken)}catch{failed=true}
        guard failed,try Data(contentsOf:broken.appendingPathComponent("library.json"))==original else {throw AppError("Corrupt library was not preserved")}
        let text=String(repeating:"한글😀",count:20000)
        let chunks=ChatGPT.chunks(text,limit:1000)
        guard chunks.joined()==text,chunks.allSatisfy({$0.count<=1000}) else {throw AppError("Unicode chunking failed")}
        let audio=root.appendingPathComponent("Audio");try FileManager.default.createDirectory(at:audio,withIntermediateDirectories:true)
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!;buffer.frameLength=16000
        for i in 0..<16000 {buffer.floatChannelData![0][i]=Float(sin(Double(i)*2*Double.pi*440/16000)*0.15)}
        do {let file=try AVAudioFile(forWriting:audio.appendingPathComponent("microphone.caf"),settings:format.settings);try file.write(from:buffer)}
        let mixed=try await AudioRecorder.mix(directory:audio,tracks:[AudioTrack(file:"microphone.caf",label:"test",offset:0)])
        let asset=AVURLAsset(url:audio.appendingPathComponent(mixed));let duration=try await asset.load(.duration)
        guard abs(duration.seconds-1)<0.15 else {throw AppError("Audio export duration incorrect")}
        let formatted=LocalTranscription.markdown([TranscriptSegment(time:61,text:"회의 내용",source:"마이크")])
        guard formatted.contains("00:01:01"),formatted.contains("회의 내용") else {throw AppError("Transcript timestamp failed")}
        let locales=await LocalTranscription.locales()
        print("Persistence, recovery, Unicode, transcript timestamps, synthetic audio export passed.")
        print("Available Korean locales: \(locales.filter{$0.hasPrefix("ko")}.joined(separator:", "))")
    }

    private static func welcomeMigration(root: URL) throws {
        let store = try Store(root: root)
        var legacy = store.library.notes[0]
        legacy.title = Compatibility.welcomeTitles[0]
        legacy.markdown += "\n\n직접 추가한 내용은 그대로 남아야 해요."
        legacy.document = "{\"type\":\"doc\",\"content\":[]}"
        legacy.summary = "보존할 회의록"
        legacy.transcript = "보존할 기록"
        legacy.pinned = true
        var korean = legacy
        korean.id = UUID().uuidString
        korean.title = "갈피에 오신 걸 환영해요"
        var customTitle = legacy
        customTitle.id = UUID().uuidString
        customTitle.title = "앱 사용에 관한 내 메모"
        var customContent = legacy
        customContent.id = UUID().uuidString
        customContent.markdown = "사용자가 새로 쓴 본문"
        store.library.notes = [legacy, korean, customTitle, customContent]
        try store.persist()
        var expected = store.library
        expected.notes[0].title = "Galpi에 오신 걸 환영해요"
        expected.notes[1].title = "Galpi에 오신 걸 환영해요"
        let migrated = try Store(root: root)
        let reloaded = try Store(root: root)
        guard try store.encoder.encode(migrated.library) == store.encoder.encode(expected),
              try store.encoder.encode(reloaded.library) == store.encoder.encode(expected) else {
            throw AppError("Welcome migration must change only recognized default titles and preserve all other data")
        }
        print("Welcome title migration, edited content preservation and repeat loading passed.")
    }

    private static func dataFolderMigration(root: URL) throws {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(Compatibility.legacyDataFolder)
        let store = try Store(root: legacy)
        _ = try store.create(title: "이전 메모", markdown: "기존 본문")
        let recording = legacy.appendingPathComponent("Recordings/sample")
        try fm.createDirectory(at: recording, withIntermediateDirectories: true)
        let audio = Data([0, 42, 255, 3])
        try audio.write(to: recording.appendingPathComponent("microphone.caf"))
        let original = try Data(contentsOf: legacy.appendingPathComponent("library.json"))
        let target = try Compatibility.dataDirectory(applicationSupport: root)
        guard target.lastPathComponent == "Galpi", !fm.fileExists(atPath: legacy.path),
              try Data(contentsOf: target.appendingPathComponent("library.json")) == original,
              try Data(contentsOf: target.appendingPathComponent("Recordings/sample/microphone.caf")) == audio,
              try Compatibility.dataDirectory(applicationSupport: root) == target else {
            throw AppError("Data migration must preserve files and be repeatable")
        }
        _ = try Store(root: legacy)
        _ = try Compatibility.dataDirectory(applicationSupport: root)
        guard fm.fileExists(atPath: legacy.path), try Data(contentsOf: target.appendingPathComponent("library.json")) == original else {
            throw AppError("Existing destination data must not be overwritten")
        }
        let brokenSupport = root.appendingPathComponent("Corrupt")
        let broken = brokenSupport.appendingPathComponent(Compatibility.legacyDataFolder)
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        let invalid = Data("broken-library".utf8)
        try invalid.write(to: broken.appendingPathComponent("library.json"))
        var rejected = false
        do { _ = try Compatibility.dataDirectory(applicationSupport: brokenSupport) } catch { rejected = true }
        guard rejected, try Data(contentsOf: broken.appendingPathComponent("library.json")) == invalid,
              !fm.fileExists(atPath: brokenSupport.appendingPathComponent("Galpi").path) else {
            throw AppError("Corrupt legacy data must stay in place")
        }
        print("Data folder migration, audio preservation, collision and corrupt-data protection passed.")
    }
}
