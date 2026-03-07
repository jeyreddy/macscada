import Foundation
import Speech
import AVFoundation
import Combine

// MARK: - SpeechInputService
//
// Manages microphone capture and on-device/cloud speech recognition via the
// Apple Speech framework (SFSpeechRecognizer).
//
// ── Permissions ───────────────────────────────────────────────────────────────
//   Requires two separate macOS permissions, each with its own system prompt:
//     • AVCaptureDevice.requestAccess(for: .audio)  → microphone access
//     • SFSpeechRecognizer.requestAuthorization      → speech recognition
//   Permissions are requested lazily on the first call to startListening(),
//   not at app launch, to avoid surprising the operator.
//
// ── Audio pipeline ────────────────────────────────────────────────────────────
//   AVAudioEngine (inputNode)
//     ↓ installTap(bufferSize: 1024)
//   SFSpeechAudioBufferRecognitionRequest
//     ↓ recognizer.recognitionTask(with: request)
//   SFSpeechRecognitionTask
//     ↓ result.bestTranscription.formattedString (partial)
//   liveTranscript  ← updated on every partial result
//     ↓ result.isFinal  OR  silenceTimer fires
//   transcriptFinalized.send(text)  → received by MultimodalInputService
//
// ── Silence detection ─────────────────────────────────────────────────────────
//   A Timer fires every 0.5 s and checks how long ago the last recognition result
//   arrived.  If ≥ 4 s of silence, endSession() is called automatically.
//   This avoids leaving the microphone open indefinitely after the operator
//   finishes speaking.
//
// ── State machine ─────────────────────────────────────────────────────────────
//   .idle       — microphone off, no session
//   .listening  — AVAudioEngine running, SFSpeechRecognitionTask active
//   .processing — endSession called, waiting for the final recognition result
//                 (in practice the transition to .idle is nearly instant)
//
// ── Error handling ────────────────────────────────────────────────────────────
//   • kAFAssistantErrorDomain code 216 = "cancelled" — expected when stopListening()
//     is called programmatically; silently ignored.
//   • Other errors → self.error is set and the session ends cleanly.

@MainActor
final class SpeechInputService: ObservableObject {

    // MARK: - State enum

    /// Current recognition state. Drives mic button appearance in MultimodalInputView.
    enum State { case idle, listening, processing }

    // MARK: - Published properties

    /// Current recognition state — drives mic button appearance and colour.
    @Published var state: State = .idle

    /// Rolling partial transcript updated on every recognition result.
    /// Displayed in the mic button tooltip; cleared when the session ends.
    @Published var liveTranscript: String = ""

    /// Whether the operator has granted microphone access.
    @Published var micPermission: Bool = false

    /// Whether the operator has granted speech recognition access.
    @Published var speechPermission: Bool = false

    /// Most recent error message, or nil if no error. Displayed in the UI if non-nil.
    @Published var error: String?

    // MARK: - Combine subject

    /// Fires with the final recognized text when:
    ///   (a) SFSpeechRecognitionTask returns isFinal = true, OR
    ///   (b) The silence timer fires (operator stopped speaking).
    /// Subscribed by MultimodalInputService to forward to AgentService.
    let transcriptFinalized = PassthroughSubject<String, Never>()

    // MARK: - Private — recognition stack

    /// `en-US` locale recognizer. requiresOnDeviceRecognition = false allows
    /// cloud fallback for better accuracy, while still working offline.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// The active audio buffer recognition request — non-nil only while listening.
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    /// The active recognition task — non-nil only while listening.
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Low-level audio capture graph. A single input node tap feeds the recognition request.
    private let audioEngine = AVAudioEngine()

    // MARK: - Private — silence detection

    /// Timestamp of the most recent recognition result.
    /// Compared against Date() by the silence timer to detect pauses.
    private var lastResultTime: Date = .distantPast

    /// Polls every 0.5 s for silence. Invalidated when the session ends.
    private var silenceTimer: Timer?

    /// Seconds of silence before auto-stopping the session.
    private let silenceThreshold: TimeInterval = 4.0

    // MARK: - Permissions

    /// Request both microphone and speech recognition permissions if not already granted.
    /// Called lazily before the first session begins.
    func requestPermissions() async {
        await requestMicPermission()
        await requestSpeechPermission()
    }

    /// Request microphone permission via AVCaptureDevice (needed even on macOS for audio input).
    private func requestMicPermission() async {
        let status = await AVCaptureDevice.requestAccess(for: .audio)
        micPermission = status
    }

    /// Request speech recognition permission via SFSpeechRecognizer.
    /// Uses a continuation bridge because the completion handler is callback-based.
    private func requestSpeechPermission() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    self.speechPermission = (status == .authorized)
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Public API

    /// Start speech recognition. Requests permissions if needed.
    /// Guards against starting a new session while one is already active.
    func startListening() {
        guard state == .idle else { return }
        guard micPermission, speechPermission else {
            // Request permissions and let the operator press the button again.
            Task { await requestPermissions() }
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }

        do {
            try beginSession(recognizer: recognizer)
        } catch {
            self.error = error.localizedDescription
            state = .idle
        }
    }

    /// Stop speech recognition immediately.
    /// If partial text is available, emits it via `transcriptFinalized`.
    func stopListening() {
        endSession()
    }

    // MARK: - Internal session management

    /// Configure and start the AVAudioEngine + SFSpeechRecognitionTask.
    ///
    /// Flow:
    ///   1. Clean up any previous session (endSession(emit: false))
    ///   2. Create SFSpeechAudioBufferRecognitionRequest with partialResults = true
    ///   3. Install a tap on AVAudioEngine.inputNode to feed buffers to the request
    ///   4. Start the audio engine
    ///   5. Start the recognition task with a callback that updates liveTranscript
    ///   6. Start the silence detection timer

    private func beginSession(recognizer: SFSpeechRecognizer) throws {
        endSession(emit: false)    // clean up stale session if any
        liveTranscript = ""
        error = nil
        state = .listening

        // Partial results enabled so liveTranscript updates in real-time while speaking
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false   // cloud fallback for better accuracy
        recognitionRequest = request

        // Tap the audio input node at its native format — no resampling needed
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Reset silence timer baseline to now (before the first result arrives)
        lastResultTime = Date()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, err in
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    // Update rolling live transcript on every partial result
                    self.liveTranscript = result.bestTranscription.formattedString
                    self.lastResultTime = Date()

                    if result.isFinal {
                        // Apple's recognizer signals completion — emit and clean up
                        let text = result.bestTranscription.formattedString
                        self.endSession(emit: false)
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.transcriptFinalized.send(text)
                        }
                    }
                }
                if let err {
                    // kAFAssistantErrorDomain code 216 = programmatic cancellation — expected on stop()
                    let nsErr = err as NSError
                    if nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 216 { return }
                    self.error = err.localizedDescription
                    self.endSession(emit: false)
                }
            }
        }

        startSilenceTimer()
    }

    /// Tear down the audio capture pipeline and recognition task.
    ///
    /// - Parameter emit: If true AND liveTranscript is non-empty, emits the partial
    ///   transcript via transcriptFinalized before clearing it.  Pass false when the
    ///   session ended due to isFinal (already emitted) or an error.

    private func endSession(emit: Bool = true) {
        // Stop and invalidate the silence timer first to prevent re-entry
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Stop the audio engine and remove the tap before ending the recognition request
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Signal end of audio to the recognizer, then cancel and nil the references
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        // Emit partial transcript if requested and non-empty
        if emit && !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = liveTranscript
            liveTranscript = ""
            state = .idle
            transcriptFinalized.send(text)
        } else {
            liveTranscript = ""
            state = .idle
        }
    }

    // MARK: - Silence detection

    /// Schedule a repeating timer that fires every 0.5 s to check for silence.
    /// When `Date().timeIntervalSince(lastResultTime) >= silenceThreshold`,
    /// the session is ended and the partial transcript (if any) is emitted.
    ///
    /// The timer is scheduled on the main run loop (from a @MainActor context)
    /// and dispatches back through Task @MainActor to satisfy Swift concurrency.

    private func startSilenceTimer() {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(self.lastResultTime)
                if elapsed >= self.silenceThreshold && self.state == .listening {
                    // 4 s of silence — auto-stop and emit whatever was transcribed so far
                    self.endSession(emit: true)
                }
            }
        }
    }
}
