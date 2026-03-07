// MARK: - ChatbotPanel.swift
//
// Compact floating chat panel for the AI agent, accessible from all tabs via the FAB.
// Differs from AgentView (full tab) in two ways:
//   1. Tool-call / tool-result messages are filtered out (only user + assistant shown)
//   2. Quick-action suggestion chips are shown when the conversation is empty
//
// ── Layout ────────────────────────────────────────────────────────────────────
//   VStack:
//     panelHeader  — "HMI Assistant" title + collapse toggle + sign-in button if needed
//     ScrollView   — visibleMessages as bubbles (user right / assistant left)
//                    OR suggestion grid if visibleMessages.isEmpty
//     inputBar     — TextField + attach button + send button (same as AgentView)
//
// ── Message Filtering ─────────────────────────────────────────────────────────
//   visibleMessages filters agentService.messages to .user and .assistant kinds.
//   This keeps the panel clean for operators who don't need to see tool call detail.
//   Full tool call history is still visible in the AgentView tab.
//
// ── Quick-Action Suggestions ──────────────────────────────────────────────────
//   6 pre-defined commands shown as 2-column button grid when conversation is empty:
//     "System Status", "Active Alarms", "Ack All Alarms",
//     "Bad Quality Tags", "Show Trends", "Write a Value"
//   Tapping a suggestion calls agentService.sendMessage(text: suggestion.command).
//
// ── Shared Conversation ───────────────────────────────────────────────────────
//   ChatbotPanel and AgentView share the same AgentService @EnvironmentObject,
//   so messages sent from either panel appear in both.
//
// ── Image Attachment ──────────────────────────────────────────────────────────
//   Same NSOpenPanel + drag-drop image attach as AgentView.
//   attachedImageB64 sent with text via agentService.sendMessage(text:imageBase64:).

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ChatbotPanel

/// Floating chatbot panel accessible from every tab.
/// Shows only user + assistant bubbles (tool-call noise is hidden).
/// Shares the same AgentService conversation as the AI Agent tab.
struct ChatbotPanel: View {

    @EnvironmentObject var agentService:   AgentService
    @EnvironmentObject var sessionManager: SessionManager

    @AppStorage("chat.panelExpanded") private var isExpanded: Bool = true

    @State private var inputText:        String  = ""
    @State private var attachedImageB64: String? = nil
    @State private var showSignIn:       Bool    = false

    // MARK: - Quick-action suggestions

    private let suggestions: [(label: String, icon: String, command: String)] = [
        ("System Status",    "gauge",                           "Give me a full system status summary"),
        ("Active Alarms",    "exclamationmark.triangle.fill",   "List all active alarms"),
        ("Ack All Alarms",   "checkmark.seal",                  "Acknowledge all alarms"),
        ("Bad Quality Tags", "minus.circle",                    "List all tags with bad quality"),
        ("Show Trends",      "chart.xyaxis.line",               "Navigate to the trends tab"),
        ("Write a Value",    "pencil.circle",                   "Help me write a value to a tag"),
    ]

    // MARK: - Derived: only user + assistant messages (filter tool noise)

    private var visibleMessages: [AgentMessage] {
        agentService.messages.filter {
            switch $0.kind {
            case .user, .assistant: return true
            default:                return false
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isExpanded {
                Divider()

                // ── Message list ────────────────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if visibleMessages.isEmpty && !agentService.isLoading {
                                emptyState
                            } else {
                                ForEach(visibleMessages) { msg in
                                    chatBubble(msg)
                                        .id(msg.id)
                                }
                            }
                            if agentService.isLoading {
                                workingChip
                                    .id("working")
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: visibleMessages.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: agentService.isLoading) { _, loading in
                        if loading { scrollToBottom(proxy) }
                    }
                }

                Divider()

                // ── Input bar ───────────────────────────────────────────────
                inputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.callout)
                .foregroundColor(.accentColor)

            Text("HMI Assistant")
                .font(.subheadline.bold())

            if agentService.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }

            Spacer()

            // Claude connection status
            Button {
                showSignIn = true
            } label: {
                Image(systemName: agentService.hasAPIKey ? "checkmark.seal.fill" : "key.fill")
                    .font(.caption)
                    .foregroundColor(agentService.hasAPIKey ? .green : .yellow)
            }
            .buttonStyle(.plain)
            .help(agentService.hasAPIKey ? "Connected — click to manage API key" : "Not connected — click to connect to Claude")

            // Clear conversation
            if !agentService.messages.isEmpty {
                Button {
                    agentService.messages.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear conversation")
            }

            // Collapse / expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Minimise" : "Expand")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sheet(isPresented: $showSignIn) {
            ClaudeSignInSheet()
        }
    }

    // MARK: - Empty state (suggestion chips)

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How can I help?")
                    .font(.headline)
                Text("Type a command or tap a suggestion below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)

            // Two-column chip grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(suggestions, id: \.label) { s in
                    suggestionChip(s)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func suggestionChip(_ s: (label: String, icon: String, command: String)) -> some View {
        Button {
            send(text: s.command)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: s.icon)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Text(s.label)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(agentService.isLoading)
    }

    // MARK: - Chat bubbles

    @ViewBuilder
    private func chatBubble(_ msg: AgentMessage) -> some View {
        switch msg.kind {
        case .user(let text, let b64):
            ChatUserBubble(text: text, imageBase64: b64)
        case .assistant(let text):
            ChatAssistantBubble(text: text)
        default:
            EmptyView()
        }
    }

    // MARK: - Working chip

    private var workingChip: some View {
        HStack(spacing: 8) {
            // Count active tool calls for display
            let toolCalls = agentService.messages.filter {
                if case .toolCall = $0.kind { return true }; return false
            }
            let lastTool = toolCalls.last.flatMap { msg -> String? in
                if case .toolCall(let name, _) = msg.kind { return name }; return nil
            }

            ProgressView()
                .controlSize(.small)

            if let tool = lastTool {
                Text("Running \(tool.replacingOccurrences(of: "_", with: " "))…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Thinking…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .cornerRadius(10)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Image thumbnail
            if let b64 = attachedImageB64,
               let data = Data(base64Encoded: b64),
               let nsImg = NSImage(data: data) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Button { attachedImageB64 = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 3, y: -3)
                }
                .padding(.bottom, 2)
            }

            TextField("Type a command…", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        inputText.append("\n")
                    } else {
                        sendFromBar()
                    }
                }

            // Image attach
            Button { openImagePanel() } label: {
                Image(systemName: "paperclip")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach image")

            // Send
            Button { sendFromBar() } label: {
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
    }

    // MARK: - Helpers

    private var canSend: Bool {
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedImageB64 != nil)
        && !agentService.isLoading
        && agentService.hasAPIKey
        && sessionManager.isLoggedIn
    }

    private func sendFromBar() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachedImageB64 != nil else { return }
        let img = attachedImageB64
        inputText = ""
        attachedImageB64 = nil
        send(text: text, imageBase64: img)
    }

    private func send(text: String, imageBase64: String? = nil) {
        guard !agentService.isLoading, agentService.hasAPIKey, sessionManager.isLoggedIn else { return }
        Task { await agentService.sendMessage(text: text, imageBase64: imageBase64) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if let last = visibleMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if agentService.isLoading {
                proxy.scrollTo("working", anchor: .bottom)
            }
        }
    }

    private func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url    = panel.url,
              let data   = try? Data(contentsOf: url),
              let img    = NSImage(data: data),
              let tiff   = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png    = bitmap.representation(using: .png, properties: [:]) else { return }
        attachedImageB64 = png.base64EncodedString()
    }
}

// MARK: - ChatUserBubble

private struct ChatUserBubble: View {
    let text:        String
    let imageBase64: String?

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if let b64 = imageBase64,
                   let data = Data(base64Encoded: b64),
                   let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 140)
                        .cornerRadius(10)
                }
                if !text.isEmpty {
                    Text(text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(16, corners: [.topLeft, .topRight, .bottomLeft])
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - ChatAssistantBubble

private struct ChatAssistantBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar
            Image(systemName: "cpu.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
                .padding(5)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())
                .frame(width: 26, height: 26)

            // Markdown-rendered text
            Group {
                if let attr = try? AttributedString(markdown: text) {
                    Text(attr)
                } else {
                    Text(text)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(16, corners: [.topLeft, .topRight, .bottomRight])
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 20)
        }
    }
}

// MARK: - Rounded corners helper

private extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft     = RectCorner(rawValue: 1 << 0)
    static let topRight    = RectCorner(rawValue: 1 << 1)
    static let bottomLeft  = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let all: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

private struct RoundedCornerShape: Shape {
    let radius:  CGFloat
    let corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = corners.contains(.topLeft)     ? radius : 0
        let tr = corners.contains(.topRight)    ? radius : 0
        let bl = corners.contains(.bottomLeft)  ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                                  radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                                  radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                                  radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                                  radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        path.closeSubpath()
        return path
    }
}
