// MARK: - MultimodalSettingsView.swift
//
// Settings form for multimodal (voice + gesture + TTS) input/output configuration.
// Embedded in the application Settings tab.
//
// ── Sections ──────────────────────────────────────────────────────────────────
//   Panel:
//     "Show multimodal panel" toggle → @AppStorage("multimodal.panelVisible")
//     Note: also toggled by the mic button in MonitorView's toolbar
//   Voice Input:
//     Microphone permission indicator + "Request Access" button
//       → speechInput.micPermission; calls speechInput.requestPermissions()
//     Speech Recognition permission indicator + "Request Access" button
//       → speechInput.speechPermission; calls speechInput.requestPermissions()
//     Both permissions requested together (SFSpeechRecognizer requires mic + speech).
//   Camera / Gesture:
//     Camera permission indicator + "Request Access" button
//       → gestureInput.cameraPermission; calls gestureInput.requestPermission()
//     Gesture vocabulary: collapsible list of all 7 recognized gestures + meanings
//   Text-to-Speech (TTS):
//     "Speak AI responses" toggle → speechOutput.isEnabled (persisted to UserDefaults)
//     "Voice": read-only label showing the selected TTS voice name
//     "Speech rate": read-only label showing rate multiplier
//
// ── Permission Display Pattern ────────────────────────────────────────────────
//   permissionRow(icon:title:granted:action:) — reusable row with:
//     SF Symbol icon + title + green "Granted" / yellow "Not Granted" badge
//     "Request Access" button shown only when granted = false
//   Permissions are granted lazily (not at launch) per Apple HIG guidelines.
//
// ── Gesture Vocabulary ────────────────────────────────────────────────────────
//   Shown as a DisclosureGroup "Supported Gestures" with 7 rows:
//     Thumbs Up → "Acknowledge all alarms"
//     Open Palm → "Pause data collection"
//     Pinch      → "Confirm last action"
//     Point Up   → "Navigate to monitor tab"
//     Point Down → "Navigate to alarms tab"
//     Wave       → "Cancel and dismiss"
//     Fist       → "Stop data collection"

import SwiftUI

// MARK: - MultimodalSettingsView

struct MultimodalSettingsView: View {

    @EnvironmentObject var speechInput:  SpeechInputService
    @EnvironmentObject var gestureInput: GestureInputService
    @EnvironmentObject var speechOutput: SpeechOutputService

    @AppStorage("multimodal.panelVisible") private var panelVisible: Bool = false

    var body: some View {
        Form {
            // ── Panel visibility ───────────────────────────────────────────
            Section("Panel") {
                Toggle("Show multimodal panel", isOn: $panelVisible)
                Text("The floating bar is also toggled by the mic button in the Monitor toolbar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ── Microphone / Speech ────────────────────────────────────────
            Section("Voice Input") {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    granted: speechInput.micPermission,
                    action: {
                        Task { await speechInput.requestPermissions() }
                    }
                )

                permissionRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    granted: speechInput.speechPermission,
                    action: {
                        Task { await speechInput.requestPermissions() }
                    }
                )

                if let err = speechInput.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            // ── Camera / Gesture ───────────────────────────────────────────
            Section("Gesture Input") {
                permissionRow(
                    icon: "camera.fill",
                    title: "Camera (FaceTime HD)",
                    granted: gestureInput.cameraPermission,
                    action: {
                        Task { await gestureInput.requestPermission() }
                    }
                )

                HStack {
                    Label("Gesture recognition", systemImage: "hand.raised.fill")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { gestureInput.isRunning },
                        set: { enable in
                            Task {
                                if enable { await gestureInput.start() }
                                else       { gestureInput.stop() }
                            }
                        }
                    ))
                    .labelsHidden()
                    .disabled(!gestureInput.cameraPermission)
                }

                if let gesture = gestureInput.currentGesture {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised")
                            .foregroundColor(.accentColor)
                        Text("Detected: \(gesture.displayName)")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }

                gestureReferenceTable
            }

            // ── Text-to-Speech ─────────────────────────────────────────────
            Section("Spoken Responses (TTS)") {
                Toggle("Speak agent replies aloud", isOn: $speechOutput.isEnabled)

                HStack {
                    Label("Status", systemImage: "speaker.wave.2")
                    Spacer()
                    if speechOutput.isSpeaking {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Speaking…").font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        Text("Idle").font(.caption).foregroundColor(.secondary)
                    }
                }

                Button("Stop speaking") {
                    speechOutput.stopSpeaking()
                }
                .disabled(!speechOutput.isSpeaking)

                Text("Only the assistant's final text reply is spoken — tool-call summaries are skipped. Responses are trimmed to 120 words and markdown is stripped before speaking.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Multimodal Input")
    }

    // MARK: - Permission row helper

    private func permissionRow(icon: String,
                                title: String,
                                granted: Bool,
                                action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Button("Request Permission", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.accentColor)
            }
        }
    }

    // MARK: - Gesture reference card

    private var gestureReferenceTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Gesture commands")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.top, 4)

            ForEach(GestureInputService.Gesture.allCases, id: \.self) { gesture in
                HStack(spacing: 8) {
                    Text(gesture.displayName)
                        .font(.caption)
                        .frame(width: 90, alignment: .leading)
                    Text("→")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(gesture.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
