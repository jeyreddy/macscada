import Foundation
import AVFoundation

// MARK: - SpeechOutputService
//
// Converts agent text replies to audible speech using AVSpeechSynthesizer (TTS).
//
// ── Design decisions ──────────────────────────────────────────────────────────
//   • On by default — operators in hands-free environments need audio feedback
//     without any initial configuration. The mute button is always visible.
//   • Preference persisted to UserDefaults under key "multimodal.ttsEnabled" so
//     it survives app restarts.
//   • Markdown is stripped before speaking — agent replies use bold, code blocks,
//     and bullet points that are meaningless or distracting when spoken aloud.
//   • Truncated to 120 words — long diagnostic replies can take 45+ seconds to
//     speak. Operators need actionable phrases, not verbatim paragraphs.
//   • Only `.assistant(text:)` messages are spoken — tool calls, tool results,
//     and user messages are never read aloud.
//
// ── Voice selection ───────────────────────────────────────────────────────────
//   Prefers the Enhanced Samantha voice (high quality, neural, requires download).
//   Falls back to any en-US system voice if Samantha is not installed.
//
// ── Concurrency ───────────────────────────────────────────────────────────────
//   AVSpeechSynthesizerDelegate callbacks are nonisolated (called by AVFoundation
//   on an unspecified thread). Each delegate method dispatches to @MainActor via
//   Task so that `@Published var isSpeaking` is always updated on the main actor.

@MainActor
final class SpeechOutputService: NSObject, ObservableObject {

    // MARK: - Published state

    /// True while the synthesizer is actively speaking an utterance.
    /// Drives a visual indicator in MultimodalInputView if needed.
    @Published var isSpeaking: Bool = false

    /// Whether TTS output is enabled. Persisted to UserDefaults so the
    /// operator's mute preference survives app restarts.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "multimodal.ttsEnabled") }
    }

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()

    /// Identifier for the Enhanced Samantha voice (macOS built-in, high quality).
    /// If not installed, falls back to any en-US voice in the `speak(_:)` method.
    private let preferredVoiceIdentifier = "com.apple.voice.enhanced.en-US.Samantha"

    // MARK: - Initializer

    override init() {
        // Read persisted preference; default to true (TTS on by default)
        let stored = UserDefaults.standard.object(forKey: "multimodal.ttsEnabled") as? Bool
        isEnabled = stored ?? true
        super.init()
        // Set self as delegate so isSpeaking tracks utterance lifecycle
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak `text` aloud after stripping markdown and truncating to 120 words.
    ///
    /// Silently no-ops when:
    ///   • isEnabled = false (operator has muted TTS)
    ///   • The stripped text is empty (e.g. a reply containing only code blocks)
    ///
    /// Utterances are queued by AVSpeechSynthesizer — if a previous utterance is
    /// still playing, the new one will be spoken immediately after it finishes.
    /// To interrupt, call stopSpeaking() before speak(_:).

    func speak(_ text: String) {
        guard isEnabled else { return }
        let cleaned = stripMarkdown(text)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let utterance = AVSpeechUtterance(string: cleaned)

        // Voice selection: prefer enhanced Samantha (natural prosody), fall back to system en-US
        if let voice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        // Slightly slower than default for industrial operator contexts where clarity matters
        utterance.rate           = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.pitchMultiplier = 1.0
        utterance.volume         = 1.0

        synthesizer.speak(utterance)
    }

    /// Immediately stop any in-progress speech.
    /// Called when the operator taps the TTS mute toggle while speech is playing.
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Markdown stripping
    //
    // Removes formatting markers that are meaningless when read aloud.
    // Applied in this order to avoid leaving stray characters from partial matches:
    //
    //   1. Fenced code blocks (``` ... ```) — replaced with a space
    //   2. Inline code (`...`)              — replaced with a space
    //   3. Bold/italic markers (* _ ** __) — removed
    //   4. ATX headings (# ## ### at line start) — removed
    //   5. Blockquote markers (> at line start) — removed
    //   6. Markdown links [text](url)       — kept text, removed URL
    //   7. Bare URLs (https://...)          — removed
    //   8. Excess whitespace               — collapsed to single spaces
    //   9. Truncate to 120 words + "…"     — keeps spoken time under ~45 s

    private func stripMarkdown(_ input: String) -> String {
        var text = input

        // Remove fenced code blocks (``` ... ```) — the content is usually code
        // that should not be read aloud at all
        text = text.replacingOccurrences(of: "```[^`]*```",
                                          with: " ",
                                          options: .regularExpression)

        // Remove inline code spans (`...`) — usually identifiers/values already mentioned
        text = text.replacingOccurrences(of: "`[^`]+`",
                                          with: " ",
                                          options: .regularExpression)

        // Remove bold (**) and italic (*) markers — pure visual formatting
        text = text.replacingOccurrences(of: "\\*{1,2}", with: "", options: .regularExpression)
        // Remove bold (__) and italic (_) markers
        text = text.replacingOccurrences(of: "_{1,2}",   with: "", options: .regularExpression)

        // Remove ATX headings (# text, ## text, ...) at the start of any line
        if let re = try? NSRegularExpression(pattern: "^#{1,6}\\s+", options: .anchorsMatchLines) {
            let range = NSRange(text.startIndex..., in: text)
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        // Remove blockquote markers (> at line start)
        if let re = try? NSRegularExpression(pattern: "^>\\s*", options: .anchorsMatchLines) {
            let range = NSRange(text.startIndex..., in: text)
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        // Markdown links: [link text](url) → keep "link text", drop the URL
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)",
                                          with: "$1",
                                          options: .regularExpression)

        // Remove bare URLs — they're unreadable when spoken character by character
        text = text.replacingOccurrences(of: "https?://\\S+",
                                          with: "",
                                          options: .regularExpression)

        // Collapse multiple whitespace chars (including newlines) to a single space
        text = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate to 120 words so very long replies don't block the operator for 45+ seconds
        let words = text.split(separator: " ")
        if words.count > 120 {
            text = words.prefix(120).joined(separator: " ") + "…"
        }
        return text
    }
}

// MARK: - AVSpeechSynthesizerDelegate
//
// All three callbacks are nonisolated because AVFoundation invokes them on its own
// internal thread.  Each dispatches to @MainActor to update `@Published isSpeaking`.

extension SpeechOutputService: AVSpeechSynthesizerDelegate {

    /// Called when an utterance begins playing — set isSpeaking so the UI can indicate TTS is active.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    /// Called when an utterance finishes naturally.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    /// Called when an utterance is cut short by stopSpeaking().
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
