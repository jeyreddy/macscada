// MARK: - MultimodalControlPanel.swift
//
// Compact popover panel opened by the mic FAB (FloatingPanelManager.micPanel).
// Provides a unified control surface for all three multimodal input/output modes:
//   voice input (SpeechInputService), gesture input (GestureInputService),
//   and TTS output (SpeechOutputService).
//
// ── Layout (VStack, 320 pt wide) ──────────────────────────────────────────────
//   Header: waveform.and.mic icon + "Voice & Gesture" title
//   micRow:
//     Mic status icon (idle/listening/processing) + last transcript chip
//     Push-to-talk button: tap = start, tap again = stop
//     Live transcript text if SpeechInputService.state == .listening
//   cameraRow:
//     Camera start/stop toggle button
//     Current gesture chip (multimodal.lastEvent if starts with ✋)
//   lastEvent chip:
//     Shows multimodal.lastEvent (voice or gesture) with 🎙 or ✋ prefix
//     Fades after 3 seconds (managed by MultimodalInputService)
//   TTS row:
//     Speaker toggle (speechOutput.isEnabled)
//     "Speaking..." text when speechOutput.isSpeaking
//   Settings link: opens MultimodalSettingsView via NavigationLink
//
// ── Permissions ───────────────────────────────────────────────────────────────
//   If speechInput.micPermission or speechInput.speechPermission = false:
//     Shows "Grant permissions" button → Task { await speechInput.requestPermissions() }
//   If gestureInput.cameraPermission = false:
//     Shows "Grant camera access" button → Task { await gestureInput.requestPermission() }
//
// ── Session Gate ──────────────────────────────────────────────────────────────
//   Not shown when !sessionManager.isLoggedIn — FloatingPanelManager hides the FAB.
//   The panel itself has no additional session check (FAB hiding is sufficient).

import SwiftUI

// MARK: - MultimodalControlPanel
//
// Compact popover panel for the multimodal floating button.
// Replaces the old bottom-bar MultimodalInputView.

struct MultimodalControlPanel: View {

    @EnvironmentObject var speechInput:  SpeechInputService
    @EnvironmentObject var gestureInput: GestureInputService
    @EnvironmentObject var speechOutput: SpeechOutputService
    @EnvironmentObject var multimodal:   MultimodalInputService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "waveform.and.mic")
                    .foregroundColor(.purple)
                Text("Voice & Gesture")
                    .font(.subheadline.bold())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // ── Microphone ────────────────────────────────────────────
                micRow

                Divider()

                // ── Camera / Gesture ──────────────────────────────────────
                cameraRow

                // Last event chip
                if !multimodal.lastEvent.isEmpty {
                    Text(multimodal.lastEvent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }

                Divider()

                // ── TTS ───────────────────────────────────────────────────
                ttsRow
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mic row

    private var micRow: some View {
        HStack(spacing: 12) {
            // Pulsing mic button
            Button {
                if speechInput.state == .idle { speechInput.startListening() }
                else                          { speechInput.stopListening() }
            } label: {
                ZStack {
                    if speechInput.state == .listening {
                        Circle()
                            .stroke(Color.purple.opacity(0.3), lineWidth: 5)
                            .scaleEffect(1.5)
                            .animation(
                                .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                                value: speechInput.state == .listening
                            )
                    }
                    Circle()
                        .fill(micBg)
                        .frame(width: 36, height: 36)
                    Image(systemName: micIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(micLabel)
                    .font(.callout.bold())
                if !speechInput.liveTranscript.isEmpty {
                    Text(speechInput.liveTranscript)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else if let err = speechInput.error {
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(1)
                } else {
                    permissionHint(mic: true)
                }
            }
            Spacer()
        }
    }

    private var micIcon: String {
        switch speechInput.state {
        case .idle:       return "mic.fill"
        case .listening:  return "mic.fill"
        case .processing: return "ellipsis"
        }
    }

    private var micBg: Color {
        switch speechInput.state {
        case .idle:       return speechInput.micPermission ? .purple : .secondary
        case .listening:  return .purple
        case .processing: return .orange
        }
    }

    private var micLabel: String {
        switch speechInput.state {
        case .idle:       return speechInput.micPermission ? "Voice Input" : "Voice (tap to enable)"
        case .listening:  return "Listening…"
        case .processing: return "Processing…"
        }
    }

    // MARK: - Camera row

    private var cameraRow: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if gestureInput.isRunning { gestureInput.stop() }
                    else                      { await gestureInput.start() }
                }
            } label: {
                Circle()
                    .fill(gestureInput.isRunning ? Color.blue : Color.secondary)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: gestureInput.isRunning ? "camera.fill" : "camera")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(gestureInput.isRunning ? "Gestures Active" : "Gesture Input")
                    .font(.callout.bold())
                if let g = gestureInput.currentGesture {
                    Text("✋ \(g.displayName)")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else {
                    permissionHint(mic: false)
                }
            }
            Spacer()
        }
    }

    // MARK: - TTS row

    private var ttsRow: some View {
        HStack(spacing: 12) {
            Button {
                speechOutput.isEnabled.toggle()
                if !speechOutput.isEnabled { speechOutput.stopSpeaking() }
            } label: {
                Circle()
                    .fill(speechOutput.isEnabled ? Color.green : Color.secondary)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: speechOutput.isEnabled
                              ? (speechOutput.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                              : "speaker.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(speechOutput.isEnabled ? "Spoken Responses On" : "Spoken Responses Off")
                    .font(.callout.bold())
                Text(speechOutput.isSpeaking ? "Speaking…" : "Tap to \(speechOutput.isEnabled ? "mute" : "unmute")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Permission hint

    @ViewBuilder
    private func permissionHint(mic: Bool) -> some View {
        let granted = mic ? speechInput.micPermission : gestureInput.cameraPermission
        if !granted {
            Button("Grant permission") {
                Task {
                    if mic { await speechInput.requestPermissions() }
                    else   { await gestureInput.requestPermission() }
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        } else {
            Text(mic ? "Tap to start" : "Tap to start")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
