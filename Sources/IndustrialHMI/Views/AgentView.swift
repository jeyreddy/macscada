import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - AgentView

struct AgentView: View {
    @EnvironmentObject var agentService: AgentService

    @State private var inputText:         String  = ""
    @State private var attachedImageB64:  String? = nil
    @State private var apiKeyInput:       String  = ""
    @State private var scrollProxy:       ScrollViewProxy? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── API Key Banner ──────────────────────────────────────────────
            if !agentService.hasAPIKey {
                apiKeyBanner
                Divider()
            }

            // ── Chat scroll area ────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(agentService.messages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                        }
                        if agentService.isLoading {
                            TypingIndicatorRow()
                                .padding(.horizontal, 12)
                                .id("typing")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: agentService.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: agentService.isLoading) { _, loading in
                    if loading { scrollToBottom(proxy) }
                }
                .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // ── Input bar ───────────────────────────────────────────────────
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("AI Agent")
    }

    // MARK: - API Key Banner

    private var apiKeyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundColor(.yellow)
            Text("Enter your Anthropic API key to start:")
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField("sk-ant-...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            Button("Save") {
                agentService.saveAPIKey(apiKeyInput)
                apiKeyInput = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKeyInput.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.1))
    }

    // MARK: - Message Bubbles

    @ViewBuilder
    private func messageBubble(_ msg: AgentMessage) -> some View {
        switch msg.kind {
        case .user(let text, let b64):
            UserBubble(text: text, imageBase64: b64)
        case .assistant(let text):
            AssistantBubble(text: text)
        case .toolCall(let name, let summary):
            ToolCallRow(toolName: name, inputSummary: summary)
        case .toolResult(let name, let summary, let isError):
            ToolResultRow(toolName: name, resultSummary: summary, isError: isError)
        case .error(let msg):
            ErrorRow(message: msg)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Attached image thumbnail
            if let b64 = attachedImageB64,
               let data = Data(base64Encoded: b64),
               let nsImg = NSImage(data: data) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button {
                        attachedImageB64 = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
                .padding(.bottom, 4)
            }

            // Text input
            TextField("Ask the AI agent…", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        inputText.append("\n")
                    } else {
                        sendMessage()
                    }
                }

            // Image attach button
            Button {
                openImagePanel()
            } label: {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach an image (PNG/JPEG/TIFF)")

            // Send button
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(canSend ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Actions

    private var canSend: Bool {
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImageB64 != nil)
        && !agentService.isLoading
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachedImageB64 != nil else { return }
        let img = attachedImageB64
        inputText        = ""
        attachedImageB64 = nil
        Task { await agentService.sendMessage(text: text, imageBase64: img) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let last = agentService.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if agentService.isLoading {
                proxy.scrollTo("typing", anchor: .bottom)
            }
        }
    }

    private func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data  = try? Data(contentsOf: url),
              let nsImg = NSImage(data: data),
              let png   = nsImg.pngRepresentation
        else { return }
        attachedImageB64 = png.base64EncodedString()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // Try PNG data directly
            let id = UTType.png.identifier
            if provider.hasItemConformingToTypeIdentifier(id) {
                provider.loadDataRepresentation(forTypeIdentifier: id) { data, _ in
                    guard let data = data,
                          let nsImg = NSImage(data: data),
                          let png   = nsImg.pngRepresentation else { return }
                    DispatchQueue.main.async { self.attachedImageB64 = png.base64EncodedString() }
                }
                return true
            }
            // Try generic image
            let imgId = UTType.image.identifier
            if provider.hasItemConformingToTypeIdentifier(imgId) {
                provider.loadDataRepresentation(forTypeIdentifier: imgId) { data, _ in
                    guard let data = data,
                          let nsImg = NSImage(data: data),
                          let png   = nsImg.pngRepresentation else { return }
                    DispatchQueue.main.async { self.attachedImageB64 = png.base64EncodedString() }
                }
                return true
            }
        }
        return false
    }
}

// MARK: - UserBubble

private struct UserBubble: View {
    let text: String
    let imageBase64: String?

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                if let b64 = imageBase64,
                   let data = Data(base64Encoded: b64),
                   let nsImg = NSImage(data: data) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 160)
                        .cornerRadius(10)
                }
                if !text.isEmpty {
                    Text(text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - AssistantBubble

private struct AssistantBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cpu.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
                .padding(6)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Circle())
                .frame(width: 28, height: 28)
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(16)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 40)
        }
    }
}

// MARK: - ToolCallRow

private struct ToolCallRow: View {
    let toolName:     String
    let inputSummary: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Calling \(toolName)")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            if !inputSummary.isEmpty {
                Text("· \(inputSummary)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - ToolResultRow

private struct ToolResultRow: View {
    let toolName:      String
    let resultSummary: String
    let isError:       Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "xmark.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundColor(isError ? .red : .green)
            Text(resultSummary)
                .font(.caption)
                .foregroundColor(isError ? .red : .secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

// MARK: - ErrorRow

private struct ErrorRow: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.red.opacity(0.08))
        .cornerRadius(6)
    }
}

// MARK: - Typing Indicator

private struct TypingIndicatorRow: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cpu.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
                .padding(6)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Circle())
                .frame(width: 28, height: 28)
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(phase == i ? 1.4 : 1.0)
                        .animation(.easeInOut(duration: 0.3), value: phase)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(16)
            Spacer()
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - NSImage extension

extension NSImage {
    var pngRepresentation: Data? {
        guard let tiff   = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
