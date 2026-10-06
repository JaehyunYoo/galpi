import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import Speech

final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private let queue = DispatchQueue(label: "Galpi.audio.writer")
    private var files: [String: AVAudioFile] = [:]
    private var offsets: [String: Double] = [:]
    private var writeError: Error?
    private var paused = false
    private var pauseStarted: Double?
    private var pausedDuration = 0.0
    private var started = AudioRecorder.hostTime()
    private var directory: URL!
    private var finishing = false
    var failure: ((String) -> Void)?
    var isPaused: Bool { queue.sync { paused } }
    var wasInterrupted: Bool { queue.sync { writeError != nil } }
    var duration: Double { queue.sync { max(0, Self.hostTime() - started - pausedDuration - (pauseStarted.map { Self.hostTime() - $0 } ?? 0)) } }
    func start(mode: String, directory: URL) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppError("시스템 설정 → 개인정보 보호 및 보안에서 Galpi의 마이크 권한을 허용해 주세요.") }
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        finishing = false
        if mode == "online" {
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            catch { throw AppError("온라인 녹음에는 화면 및 시스템 오디오 녹음 권한이 필요해요. 시스템 설정에서 허용한 후 다시 시작해 주세요.") }
            guard let display = content.displays.first else { throw AppError("녹음할 디스플레이를 찾지 못했어요.") }
            let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            if #available(macOS 15, *) {config.captureMicrophone = true}
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000; config.channelCount = 1
            config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            if #available(macOS 15, *) {try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)}
            self.stream = stream
            queue.sync { started = Self.hostTime() }
            do {
                try await stream.startCapture()
                if #available(macOS 15, *) {} else {try startMicrophone()}
            } catch {
                try? await stream.stopCapture();self.stream = nil
                queue.sync {finishing=true;files.removeAll()}
                throw error
            }
        } else {
            queue.sync {started = Self.hostTime()}
            try startMicrophone()
        }
    }
    private static func hostTime() -> Double {CMClockGetTime(CMClockGetHostTimeClock()).seconds}
    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {throw AppError("사용할 수 있는 마이크가 없어요.")}
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else {return}
            // Both capture paths use the host clock, including on macOS 13/14.
            let timestamp=time.isHostTimeValid ? AVAudioTime.seconds(forHostTime:time.hostTime) : Self.hostTime()
            self.queue.sync {self.write(buffer,name:"microphone.caf",offset:timestamp-self.started-self.pausedDuration)}
        }
        engine.prepare();self.engine=engine
        do {try engine.start()} catch {input.removeTap(onBus:0);self.engine=nil;throw error}
    }
    func togglePause() {
        queue.sync {
            paused.toggle()
            if paused { pauseStarted = Self.hostTime() }
            else { if let p = pauseStarted { pausedDuration += Self.hostTime() - p }; pauseStarted = nil }
        }
    }
    private func write(_ buffer: AVAudioPCMBuffer, name: String, offset: Double?) {
        guard !paused, !finishing, writeError == nil else { return }
        do {
            if files[name] == nil {
                files[name] = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: buffer.format.settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                offsets[name] = max(0, offset ?? 0)
            }
            guard let file=files[name] else {return}
            if let offset {
                // ScreenCaptureKit may omit silent intervals. Keep both tracks on
                // the same timeline by writing silence for gaps between buffers.
                let target=AVAudioFramePosition(max(0,offset-(offsets[name] ?? 0))*buffer.format.sampleRate)
                var gap=max(0,target-file.length)
                while gap>0 {
                    let count=AVAudioFrameCount(min(gap,AVAudioFramePosition(buffer.format.sampleRate)))
                    guard let silence=AVAudioPCMBuffer(pcmFormat:buffer.format,frameCapacity:count) else {throw AppError("녹음 버퍼를 만들지 못했어요.")}
                    silence.frameLength=count
                    for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {if let data=audio.mData {memset(data,0,Int(audio.mDataByteSize))}}
                    try file.write(from:silence);gap -= AVAudioFramePosition(count)
                }
            }
            try file.write(from: buffer)
        } catch {
            writeError = error
            DispatchQueue.main.async { self.failure?("녹음 파일을 저장하지 못했어요: \(error.localizedDescription)") }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        var supported=type == .audio
        if #available(macOS 15, *) {supported = supported || type == .microphone}
        guard sample.isValid,supported,let desc = sample.formatDescription else {return}
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        buffer.frameLength = AVAudioFrameCount(sample.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList) == noErr else { return }
        let pts = sample.presentationTimeStamp.seconds
        guard pts.isFinite else {return}
        write(buffer,name:type == .audio ? "system.caf" : "microphone.caf",offset:pts-started-pausedDuration)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.writeError = error }
        DispatchQueue.main.async { self.failure?("녹음이 중단됐어요. 저장된 부분을 보존할게요. \(error.localizedDescription)") }
    }
    func stop() async throws -> (Double, [AudioTrack]) {
        if let stream {
            do { try await stream.stopCapture() } catch { queue.sync { writeError = error } }
            self.stream = nil
        }
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil }
        let length = duration
        let tracks: [AudioTrack] = queue.sync {
            finishing = true
            let tracks = files.keys.sorted().map { AudioTrack(file: $0, label: $0 == "system.caf" ? "회의 소리" : "마이크", offset: offsets[$0] ?? 0) }
            files.removeAll(); return tracks
        }
        guard !tracks.isEmpty else { throw AppError("녹음된 소리가 없어요. 마이크와 시스템 오디오 권한을 확인해 주세요.") }
        return (length, tracks)
    }
    static func mix(directory: URL, tracks: [AudioTrack]) async throws -> String {
        let composition = AVMutableComposition()
        for item in tracks {
            let asset = AVURLAsset(url: directory.appendingPathComponent(item.file))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: CMTime(seconds: item.offset, preferredTimescale: 48000))
        }
        let output = directory.appendingPathComponent("recording-\(UUID().uuidString.prefix(6)).m4a")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw AppError("녹음 파일을 변환하지 못했어요.") }
        session.outputURL=output;session.outputFileType = .m4a
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            session.exportAsynchronously {
                if session.status == .completed {continuation.resume()}
                else {continuation.resume(throwing:session.error ?? AppError("녹음 파일을 변환하지 못했어요."))}
            }
        }
        return output.lastPathComponent
    }
}

struct TranscriptSegment { var time: Double; var text: String; var source: String }
@available(macOS 26, *)
private enum ModernTranscription {
    static func locales() async -> [String] {
        let speech = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        let dictation = await DictationTranscriber.supportedLocales
        return Array(Set((speech + dictation).map { $0.identifier.replacingOccurrences(of:"_",with:"-") })).sorted()
    }
    static func transcribe(url: URL, locale: Locale, source: String, offset: Double, progress: @escaping (String) -> Void) async throws -> [TranscriptSegment] {
        // SpeechAnalyzer performs file transcription on device. No audio is uploaded.
        let file = try AVAudioFile(forReading: url)
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            try await install([transcriber], locale: supported, progress: progress)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let task = Task { () throws -> [TranscriptSegment] in
                var result: [TranscriptSegment] = []
                for try await item in transcriber.results where item.isFinal {
                    result.append(TranscriptSegment(time: offset + item.range.start.seconds, text: String(item.text.characters), source: source))
                }
                return result
            }
            do { _ = try await analyzer.analyzeSequence(from: file); try await analyzer.finalizeAndFinishThroughEndOfInput(); return try await task.value }
            catch { task.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
            try await install([transcriber], locale: supported, progress: progress)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let task = Task { () throws -> [TranscriptSegment] in
                var result: [TranscriptSegment] = []
                for try await item in transcriber.results where item.isFinal {
                    result.append(TranscriptSegment(time: offset + item.range.start.seconds, text: String(item.text.characters), source: source))
                }; return result
            }
            do { _ = try await analyzer.analyzeSequence(from: file); try await analyzer.finalizeAndFinishThroughEndOfInput(); return try await task.value }
            catch { task.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        }
        throw AppError("이 Mac의 음성 인식에서 \(locale.identifier) 언어를 지원하지 않아요. 설정에서 지원 언어를 확인하거나 전체 기록 탭에 전사문을 붙여넣을 수 있어요.")
    }
    private static func install(_ modules: [any SpeechModule], locale: Locale, progress: (String) -> Void) async throws {
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            progress("처음 사용하는 언어의 음성 인식 데이터를 내려받는 중…")
            try await request.downloadAndInstall()
        }
        progress("Mac에서 음성을 글로 변환하는 중…")
    }
}

enum LocalTranscription {
    static func locales() async -> [String] {
        if #available(macOS 26, *) {return await ModernTranscription.locales()}
        return await LegacyTranscription.locales()
    }
    static func transcribe(url:URL,locale:Locale,source:String,offset:Double,progress:@escaping (String)->Void) async throws -> [TranscriptSegment] {
        if #available(macOS 26, *) {return try await ModernTranscription.transcribe(url:url,locale:locale,source:source,offset:offset,progress:progress)}
        return try await LegacyTranscription.transcribe(url:url,locale:locale,source:source,offset:offset,progress:progress)
    }
    static func markdown(_ segments: [TranscriptSegment]) -> String {
        segments.sorted { $0.time < $1.time }.map {
            let t = max(0, Int($0.time))
            return "[\(String(format: "%02d:%02d:%02d", t/3600, (t/60)%60, t%60))] **\($0.source)**\n\n\($0.text)"
        }.joined(separator: "\n\n")
    }
}
