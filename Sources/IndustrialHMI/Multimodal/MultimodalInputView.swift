import SwiftUI
import AVFoundation

// MARK: - MultimodalInputView
//
// Floating compact bar overlaid at the bottom of MainView.
// Provides a unified, always-accessible surface for voice, gesture, and TTS controls
// without duplicating the full AgentView text-chat interface.
//
// ── Layout (horizontal, max 380 × 52 pt) ─────────────────────────────────────
//   [ 🎙 mic button ]  [ 📷 camera button + preview/gesture label ]  [ event chip ]  [ Spacer ]  [ 🔊 TTS ]
//
// ── Visibility ────────────────────────────────────────────────────────────────
//   Controlled by @AppStorage("multimodal.panelVisible") in MainView.
//   Toggled by a mic button in MonitorView's status toolbar.
//   Hidden when the operator is not logged in (sessionManager.isLoggedIn = false).
//
// ── Event chip lifecycle ──────────────────────────────────────────────────────
//   1. MultimodalInputService sets `lastEvent` when a voice/gesture command is sent.
//   2. .onChange(of: multimodal.lastEvent) fades the chip in immediately.
//   3. A cancellable Task sleeps 3 seconds, then fades the chip out.
//   4. A new event cancels the pending hide task so the timer resets.
//   This avoids stale chips lingering while keeping the bar uncluttered.
//
// ── Mic button states ─────────────────────────────────────────────────────────
//   .idle       → mic icon, secondary colour
//   .listening  → mic.fill icon, accent colour, pulsing ring animation
//   .processing → mic.badge.ellipsis icon, orange colour
//
// ── Camera button states ──────────────────────────────────────────────────────
//   not running → camera icon, secondary colour
//   running, no gesture → camera.fill + live AVCaptureVideoPreviewLayer (48×36)
//   running, gesture detected → camera.fill + gesture display name chip

struct MultimodalInputView: View {

    @EnvironmentObject var speechInput:  SpeechInputService
    @EnvironmentObject var gestureInput: GestureInputService
    @EnvironmentObject var speechOutput: SpeechOutputService
    @EnvironmentObject var multimodal:   MultimodalInputService

    /// Whether the last-event chip is currently visible.
    /// Animated in/out by the onChange handler below.
    @State private var showEventChip: Bool = false

    /// Handle to the running auto-hide Task so it can be cancelled when a new event arrives.
    @State private var chipHideTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 12) {

            // ── Microphone button ──────────────────────────────────────────
            // Tap to toggle speech recognition on/off.
            // The button appearance and tooltip update to reflect the current state.
            micButton

            // ── Camera / gesture toggle ────────────────────────────────────
            // Tap to start/stop AVCaptureSession + Vision hand-pose detection.
            // While running, shows a live camera preview or the detected gesture name.
            cameraButton

            // ── Last-event chip ────────────────────────────────────────────
            // Fades in when a voice/gesture command fires, auto-hides after 3 s.
            if showEventChip && !multimodal.lastEvent.isEmpty {
                Text(multimodal.lastEvent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .transition(.opacity)   // fade in/out via withAnimation in onChange
            } else {
                // Zero-size placeholder prevents layout from jumping when chip appears/disappears
                Color.clear.frame(width: 10, height: 1)
            }

            Spacer(minLength: 0)

            // ── TTS toggle ─────────────────────────────────────────────────
            // Mutes/unmutes spoken agent responses. Stopping active speech immediately.
            ttsToggle
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, minHeight: 52)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)

        // ── Event chip animation driver ────────────────────────────────────
        // Runs every time MultimodalInputService sets a new lastEvent string.
        // Pattern: cancel previous hide task → show chip → schedule new 3-second hide.
        .onChange(of: multimodal.lastEvent) { _, newValue in
            guard !newValue.isEmpty else { return }
            // Cancel any pending auto-hide so the timer resets on new events
            chipHideTask?.cancel()
            // Immediately reveal the chip with a fast ease-in
            withAnimation(.easeIn(duration: 0.15)) { showEventChip = true }
            // Schedule auto-hide after 3 s; respects Task cancellation
            chipHideTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.3)) { showEventChip = false }
                }
            }
        }
    }

    // MARK: - Mic button
    //
    // Three visual states driven by SpeechInputService.state:
    //   .idle       → "mic"                  secondary colour (inactive)
    //   .listening  → "mic.fill" + pulse ring accent colour  (recording)
    //   .processing → "mic.badge.ellipsis"   orange          (transcribing)
    //
    // Pulsing ring: a Circle stroke behind the icon, animated with repeatForever.
    // The ring is only rendered during .listening to avoid wasting CPU at idle.

    private var micButton: some View {
        Button {
            // Toggle: idle → start listening, any other state → stop
            if speechInput.state == .idle {
                speechInput.startListening()
            } else {
                speechInput.stopListening()
            }
        } label: {
            ZStack {
                // Pulsing ring — only shown while actively recording
                if speechInput.state == .listening {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 6)
                        .scaleEffect(1.4)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: speechInput.state == .listening)
                }
                Image(systemName: micIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(micColor)
                    .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.plain)
        .help(speechInput.state == .idle ? "Start voice input" : "Stop voice input")
        .frame(width: 36, height: 36)
    }

    /// SF Symbol name for the current SpeechInputService state.
    private var micIcon: String {
        switch speechInput.state {
        case .idle:       return "mic"
        case .listening:  return "mic.fill"
        case .processing: return "mic.badge.ellipsis"
        }
    }

    /// Foreground colour for the mic icon.
    private var micColor: Color {
        switch speechInput.state {
        case .idle:       return .secondary
        case .listening:  return .accentColor
        case .processing: return .orange
        }
    }

    // MARK: - Camera button
    //
    // Tapping starts or stops GestureInputService (AVCaptureSession + Vision).
    // While running, the button expands to show either:
    //   • A live 48×36 camera preview (via CameraPreviewView NSViewRepresentable)
    //   • The detected gesture's displayName (when a gesture is currently active)
    //
    // The expansion is animated so the bar width changes smoothly.

    private var cameraButton: some View {
        Button {
            // start() is async (requests camera permission on first use)
            Task {
                if gestureInput.isRunning {
                    gestureInput.stop()
                } else {
                    await gestureInput.start()
                }
            }
        } label: {
            HStack(spacing: 6) {
                // Camera icon: .fill when running (accent), plain when off (secondary)
                Image(systemName: gestureInput.isRunning ? "camera.fill" : "camera")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(gestureInput.isRunning ? .accentColor : .secondary)

                // Inline live preview or gesture chip (only visible when running)
                if gestureInput.isRunning {
                    if let gesture = gestureInput.currentGesture {
                        // A gesture has been debounce-confirmed — show its display name
                        Text(gesture.displayName)
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .transition(.opacity)
                    } else if let previewLayer = gestureInput.previewLayer {
                        // No active gesture — show live camera feed in a small rounded rect
                        CameraPreviewView(layer: previewLayer)
                            .frame(width: 48, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help(gestureInput.isRunning ? "Stop gesture recognition" : "Start gesture recognition")
        .frame(minWidth: 36, minHeight: 36)
        // Smooth width animation as preview/gesture chip appears or disappears
        .animation(.easeInOut(duration: 0.2), value: gestureInput.isRunning)
        .animation(.easeInOut(duration: 0.2), value: gestureInput.currentGesture?.rawValue)
    }

    // MARK: - TTS toggle
    //
    // Toggles SpeechOutputService.isEnabled.
    // When muting, also immediately stops any in-progress utterance.

    private var ttsToggle: some View {
        Button {
            speechOutput.isEnabled.toggle()
            // Immediately silence current speech when the operator mutes
            if !speechOutput.isEnabled { speechOutput.stopSpeaking() }
        } label: {
            Image(systemName: speechOutput.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(speechOutput.isEnabled ? .accentColor : .secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(speechOutput.isEnabled ? "Mute spoken responses" : "Enable spoken responses")
    }
}

// MARK: - CameraPreviewView (NSViewRepresentable)
//
// Bridges an AVCaptureVideoPreviewLayer into SwiftUI on macOS.
// SwiftUI on macOS has no native equivalent of UIKit's AVCaptureVideoPreviewLayer
// host view, so we wrap an NSView and add the layer as a sublayer.
//
// ── Layer management ──────────────────────────────────────────────────────────
// updateNSView checks whether the layer is already attached to avoid re-adding
// it on every SwiftUI re-render (which would cause flickering).
// The layer's frame is set to hostLayer.bounds and uses .layerWidthSizable +
// .layerHeightSizable autoresizing masks so it fills the NSView at any size.
//
// ── Lifecycle ─────────────────────────────────────────────────────────────────
// The AVCaptureVideoPreviewLayer is owned by GestureInputService (not this view).
// When GestureInputService.stop() is called, the session stops and the preview
// goes black. This view does not need to manage the session lifecycle.

struct CameraPreviewView: NSViewRepresentable {
    /// The preview layer created and owned by GestureInputService.
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true   // required for sublayer attachment on macOS
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let hostLayer = nsView.layer else { return }
        // Only re-add the layer if it is not already a sublayer of this host view.
        // Checking superlayer prevents removing and re-adding on every render cycle.
        if layer.superlayer !== hostLayer {
            layer.removeFromSuperlayer()
            layer.frame = hostLayer.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            hostLayer.addSublayer(layer)
        }
    }
}
