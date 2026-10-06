import Foundation
import Speech
import AVFoundation

// Older Macs use Apple's on-device recognizer only. Audio is never sent to
// Apple's recognition service when the device or language cannot run locally.
@MainActor enum LegacyTranscription {
    static func locales() -> [String] {
        SFSpeechRecognizer.supportedLocales().filter {SFSpeechRecognizer(locale:$0)?.supportsOnDeviceRecognition == true}
            .map {$0.identifier.replacingOccurrences(of:"_",with:"-")}.sorted()
    }
    static func transcribe(url:URL,locale:Locale,source:String,offset:Double,progress:@escaping (String)->Void) async throws -> [TranscriptSegment] {
        guard let recognizer=SFSpeechRecognizer(locale:locale),recognizer.supportsOnDeviceRecognition else {
            throw AppError("이 Mac에서는 선택한 언어의 로컬 음성 변환을 사용할 수 없어요. 전체 기록에 전사문을 붙여넣으면 ChatGPT 회의록을 만들 수 있어요.")
        }
        let authorization=await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization {continuation.resume(returning:$0)} }
        guard authorization == .authorized else {throw AppError("시스템 설정 → 개인정보 보호 및 보안 → 음성 인식에서 Galpi를 허용해 주세요.")}
        let file=try AVAudioFile(forReading:url)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("Galpi-transcription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let chunkFrames=AVAudioFramePosition(file.processingFormat.sampleRate*45)
        let total=max(1,Int(ceil(Double(file.length)/Double(chunkFrames))))
        var output:[TranscriptSegment]=[],index=0
        while file.framePosition<file.length {
            try Task.checkCancellation()
            let start=file.framePosition
            let count=min(chunkFrames,file.length-start)
            let chunkURL=folder.appendingPathComponent("segment.caf")
            try? FileManager.default.removeItem(at:chunkURL)
            do {
                let chunk=try AVAudioFile(forWriting:chunkURL,settings:file.processingFormat.settings)
                guard let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:8192) else {throw AppError("음성 변환 버퍼를 만들지 못했어요.")}
                while file.framePosition<start+count {
                    try file.read(into:buffer,frameCount:AVAudioFrameCount(min(8192,start+count-file.framePosition)))
                    guard buffer.frameLength>0 else {throw AppError("녹음 파일을 끝까지 읽지 못했어요.")}
                    try chunk.write(from:buffer)
                }
            }
            index += 1;progress("Mac에서 음성을 글로 변환하는 중… \(index)/\(total)")
            let job=LegacyRecognitionJob()
            do {
                let segments=try await job.run(recognizer:recognizer,url:chunkURL)
                output += segments.map {TranscriptSegment(time:offset+Double(start)/file.processingFormat.sampleRate+$0.time,text:$0.text,source:source)}
            } catch {
                if Task.isCancelled {throw CancellationError()}
                throw AppError("로컬 음성 변환을 완료하지 못했어요. 시스템 설정의 받아쓰기 언어를 확인하거나 전체 기록에 전사문을 붙여넣어 주세요. 원본 녹음은 보존돼 있어요. (\((error as NSError).code))")
            }
        }
        return output
    }
}

@MainActor private final class LegacyRecognitionJob {
    private var task:SFSpeechRecognitionTask?
    private var continuation:CheckedContinuation<[TranscriptSegment],Error>?
    private var timeout:Task<Void,Never>?
    func run(recognizer:SFSpeechRecognizer,url:URL) async throws -> [TranscriptSegment] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation=continuation
                let request=SFSpeechURLRecognitionRequest(url:url)
                request.requiresOnDeviceRecognition=true;request.shouldReportPartialResults=false;request.taskHint = .dictation
                task=recognizer.recognitionTask(with:request) { [weak self] result,error in
                    let final=result?.isFinal == true
                    let segments=result.map { [TranscriptSegment(time:$0.bestTranscription.segments.first?.timestamp ?? 0,text:$0.bestTranscription.formattedString,source:"")] }
                    Task { @MainActor in
                        if final,let segments {self?.finish(.success(segments))}
                        else if let error {self?.finish(.failure(error))}
                    }
                }
                timeout=Task { [weak self] in
                    try? await Task.sleep(for:.seconds(120))
                    guard !Task.isCancelled else {return}
                    self?.finish(.failure(AppError("음성 변환 대기 시간이 끝났어요.")))
                }
            }
        } onCancel: {Task { @MainActor in self.finish(.failure(CancellationError())) }}
    }
    private func finish(_ result:Result<[TranscriptSegment],Error>) {
        guard let continuation else {return};self.continuation=nil
        timeout?.cancel();timeout=nil;task?.cancel();task=nil
        continuation.resume(with:result)
    }
}
