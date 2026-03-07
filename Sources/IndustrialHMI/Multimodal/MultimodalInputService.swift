import Foundation
import Combine

// MARK: - MultimodalInputService
//
// Central orchestrator for all multimodal operator input (voice, gesture) and
// spoken output (TTS).  Connects three sub-services to the AgentService using
// Combine subscriptions.
//
// ── Two-phase initialization ──────────────────────────────────────────────────
//   MultimodalInputService is created early in IndustrialHMIApp.init() via
//   `placeholder()` — before AgentService and SessionManager are available.
//   After the app finishes launching, `wire(agentService:sessionManager:)` is
//   called from MainView.onAppear to establish all Combine subscriptions.
//
//   This pattern avoids creating a dependency between @StateObject init order and
//   keeps IndustrialHMIApp simple.
//
// ── Subscription wiring (established in wire()) ───────────────────────────────
//
//   1. Voice → Agent:
//      speechInput.transcriptFinalized
//        ─ guard sessionManager.isLoggedIn ─►
//        agentService.sendMessage(text: transcript, imageBase64: nil)
//
//   2. Gesture → Agent:
//      gestureInput.gestureDetected
//        ─ guard sessionManager.isLoggedIn ─►
//        agentService.sendMessage(text: gesture.rawValue, imageBase64: nil)
//        (rawValue is the natural-language HMI command, e.g. "Acknowledge all alarms")
//
//   3. Agent reply → TTS:
//      agentService.$messages.compactMap { $0.last }
//        ─ if .assistant(text:) AND text changed ─►
//        speechOutput.speak(text)
//        `lastSpokenText` guard prevents re-speaking unchanged messages.
//
// ── Session gate ──────────────────────────────────────────────────────────────
//   Voice and gesture commands are only forwarded when sessionManager.isLoggedIn
//   is true — matching the existing text-chat behaviour in AgentView.
//   This prevents unauthenticated operators from driving HMI actions via gesture.
//
// ── lastEvent chip ────────────────────────────────────────────────────────────
//   lastEvent is set with an emoji prefix before forwarding each command so
//   MultimodalInputView can display a brief chip:
//     Voice:   "🎙 <transcript text>"
//     Gesture: "✋ <gesture displayName>"

/// Orchestrates SpeechInputService, GestureInputService, and SpeechOutputService.
/// Receives voice transcripts and hand gestures, forwards them to AgentService,
/// and speaks agent replies aloud via SpeechOutputService.
@MainActor
final class MultimodalInputService: ObservableObject {

    // MARK: - Sub-services
    //
    // Owned by this service and injected into the SwiftUI environment by
    // IndustrialHMIApp so views can subscribe directly to their @Published properties.

    let speechInput:  SpeechInputService
    let gestureInput: GestureInputService
    let speechOutput: SpeechOutputService

    // MARK: - Published state

    /// Most recent voice/gesture event description.
    /// Shown as a floating chip in MultimodalInputView for ~3 seconds after each command.
    /// Format: "🎙 <transcript>" for voice, "✋ <gesture name>" for gestures.
    @Published var lastEvent: String = ""

    // MARK: - Private

    /// Combine subscriptions — stored here to keep them alive for the app's lifetime.
    private var cancellables = Set<AnyCancellable>()

    /// Text of the last agent reply that was spoken aloud.
    /// Guards against re-speaking the same message if the messages array is updated
    /// for reasons unrelated to a new reply (e.g. tool result appended mid-stream).
    private var lastSpokenText: String = ""

    // MARK: - Initialization (two-phase)
    //
    // Phase 1: placeholder() — creates sub-services with no Combine wiring.
    //          Used by IndustrialHMIApp as a @StateObject before other services exist.
    //
    // Phase 2: wire(agentService:sessionManager:) — called from MainView.onAppear
    //          once AgentService and SessionManager are fully initialized.

    /// Create an unwired instance with sub-services but no Combine subscriptions.
    static func placeholder() -> MultimodalInputService {
        MultimodalInputService()
    }

    private init() {
        speechInput  = SpeechInputService()
        gestureInput = GestureInputService()
        speechOutput = SpeechOutputService()
    }

    // MARK: - Wiring

    /// Connect this service to AgentService and SessionManager via Combine.
    ///
    /// Safe to call multiple times — cancels and removes all previous subscriptions
    /// before establishing new ones, so re-wiring after a sign-out/sign-in cycle works.
    ///
    /// - Parameters:
    ///   - agentService: The active AgentService instance that owns the 40 HMI tools.
    ///   - sessionManager: Gate that restricts commands to authenticated operators.

    func wire(agentService: AgentService, sessionManager: SessionManager) {
        // Remove any subscriptions from a previous wire() call
        cancellables.removeAll()

        // ── 1. Voice → Agent ───────────────────────────────────────────────
        // SpeechInputService emits on transcriptFinalized when the operator
        // finishes speaking (isFinal from recognizer OR silence timer fires).
        // The transcript is forwarded to AgentService only when logged in.

        speechInput.transcriptFinalized
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak agentService, weak sessionManager] transcript in
                guard let self, let agent = agentService, let session = sessionManager else { return }
                guard session.isLoggedIn else { return }
                // Set lastEvent so the MultimodalInputView chip shows the transcript
                self.lastEvent = "🎙 \(transcript)"
                Task { await agent.sendMessage(text: transcript, imageBase64: nil) }
            }
            .store(in: &cancellables)

        // ── 2. Gesture → Agent ─────────────────────────────────────────────
        // GestureInputService emits on gestureDetected after 6/8 frame consensus.
        // The gesture's rawValue is the natural-language HMI command string.

        gestureInput.gestureDetected
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak agentService, weak sessionManager] gesture in
                guard let self, let agent = agentService, let session = sessionManager else { return }
                guard session.isLoggedIn else { return }
                // Set lastEvent so the MultimodalInputView chip shows the gesture name
                self.lastEvent = "✋ \(gesture.displayName)"
                // gesture.rawValue = "Acknowledge all alarms", "Stop data collection", etc.
                Task { await agent.sendMessage(text: gesture.rawValue, imageBase64: nil) }
            }
            .store(in: &cancellables)

        // ── 3. Agent reply → TTS ───────────────────────────────────────────
        // Watch the last message in agentService.$messages for new .assistant replies.
        // compactMap { $0.last } skips emits when the array is empty.
        // The lastSpokenText guard prevents re-speaking if the array is updated
        // (e.g. a tool result is appended) without a new assistant message.

        agentService.$messages
            .receive(on: DispatchQueue.main)
            .compactMap { $0.last }   // only interested in the most recent message
            .sink { [weak self] message in
                guard let self else { return }
                if case .assistant(let text) = message.kind {
                    // De-duplicate: don't speak the same reply twice
                    guard text != self.lastSpokenText else { return }
                    self.lastSpokenText = text
                    // SpeechOutputService strips markdown and truncates before speaking
                    self.speechOutput.speak(text)
                }
            }
            .store(in: &cancellables)
    }
}
