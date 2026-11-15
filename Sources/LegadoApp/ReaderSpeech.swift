import AVFoundation
import Foundation
import NaturalLanguage
import Observation

@MainActor
@Observable
final class ReaderSpeech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var lastUtterance: ObjectIdentifier?
    private(set) var state: State = .stopped

    init(useAppAudioSession: Bool = false) {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = useAppAudioSession
    }

    var actionTitle: String {
        switch state {
        case .stopped: "朗读"
        case .speaking: "暂停"
        case .paused: "继续"
        }
    }

    var icon: String {
        switch state {
        case .stopped: "speaker.wave.2"
        case .speaking: "pause.fill"
        case .paused: "play.fill"
        }
    }

    func toggle(paragraphs: [String]) {
        switch state {
        case .stopped:
            start(paragraphs: paragraphs)
        case .speaking:
            if synthesizer.pauseSpeaking(at: .immediate) { state = .paused }
        case .paused:
            if synthesizer.continueSpeaking() { state = .speaking }
        }
    }

    func stop() {
        lastUtterance = nil
        if state != .stopped { synthesizer.stopSpeaking(at: .immediate) }
        state = .stopped
    }

    private func start(paragraphs: [String]) {
        let chunks = speechChunks(paragraphs.joined(separator: "\n\n"))
        guard let first = chunks.first else { return }
        let voice = voice(for: first)
        let utterances = chunks.map { chunk in
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.postUtteranceDelay = 0.14
            return utterance
        }
        lastUtterance = utterances.last.map { ObjectIdentifier($0) }
        state = .speaking
        for utterance in utterances { synthesizer.speak(utterance) }
    }

    private func voice(for sample: String) -> AVSpeechSynthesisVoice? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: sample) else { return nil }
        switch language {
        case .simplifiedChinese:
            return AVSpeechSynthesisVoice(language: "zh-CN")
        case .traditionalChinese:
            return AVSpeechSynthesisVoice(language: "zh-TW")
        default:
            if let direct = AVSpeechSynthesisVoice(language: language.rawValue) { return direct }
            return AVSpeechSynthesisVoice.speechVoices().first {
                Locale(identifier: $0.language).language.languageCode?.identifier == language.rawValue
            }
        }
    }

    private func speechChunks(_ text: String) -> [String] {
        var chunks = [String]()
        var start = text.startIndex
        while start < text.endIndex {
            let bound = text.index(start, offsetBy: 900, limitedBy: text.endIndex) ?? text.endIndex
            var end = bound
            if bound < text.endIndex {
                let recent = text.index(bound, offsetBy: -220)
                if let sentenceEnd = text[recent..<bound].lastIndex(where: { "。！？.!?\n".contains($0) }) {
                    end = text.index(after: sentenceEnd)
                }
            }
            let chunk = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            start = end
        }
        return chunks
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }

    private nonisolated func finished(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, self.lastUtterance == id else { return }
            self.lastUtterance = nil
            self.state = .stopped
        }
    }

    enum State: Equatable {
        case stopped, speaking, paused
    }
}
