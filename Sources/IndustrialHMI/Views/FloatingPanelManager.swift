// MARK: - FloatingPanelManager.swift
//
// Manages four NSPanel OS-level windows for the floating HMI assistants:
//   chatFAB  — circular FAB button for the AI chat panel
//   micFAB   — circular FAB button for the multimodal (voice/gesture) panel
//   chatPanel  — full ChatbotPanel content panel (opens when chatFAB tapped)
//   micPanel   — MultimodalControlPanel content panel (opens when micFAB tapped)
//
// ── FAB Windows ───────────────────────────────────────────────────────────────
//   FABPanel (NSPanel subclass) is borderless (.borderless) + .nonactivatingPanel.
//   NSWindow.isMovableByWindowBackground = true so dragging anywhere on the FAB moves it.
//   Initial position stored in UserDefaults; restored on configure() via savedPosition().
//   FAB windows persist across app focus changes and can live on secondary displays.
//
// ── Content Panels ────────────────────────────────────────────────────────────
//   chatPanel and micPanel are standard NSPanel instances with a thin bezel.
//   Populated with SwiftUI views via NSHostingController + NSPanel.contentView.
//   Positioned adjacent to the FAB button (FAB.frame.origin + offset).
//   Dismissed on FAB re-tap or clicking outside (NSPanel.hidesOnDeactivate = true).
//
// ── Wiring ────────────────────────────────────────────────────────────────────
//   configure() is called from MainView.onAppear after all services are initialized.
//   Injects all required services into the SwiftUI host controllers via environment.
//   @Published chatVisible / micVisible drive FAB button appearance (filled vs outline).
//
// ── Session Gate ──────────────────────────────────────────────────────────────
//   FABs are hidden when !sessionManager.isLoggedIn (Combine subscription on
//   sessionManager.$isLoggedIn → set FABPanel.isHidden accordingly).
//
// ── FloatingDraggableButton ───────────────────────────────────────────────────
//   SwiftUI view inside each FAB NSPanel. Renders a circle button with system icon.
//   Tap action calls FloatingPanelManager.toggleChat() / toggleMic().

import AppKit
import SwiftUI
import Combine

// MARK: - FloatingPanelManager
//
// Manages four NSPanel windows:
//   • Two small borderless FAB windows (the circular buttons) — fully draggable
//     across any display, remembered between sessions.
//   • Two content panels (chat / voice-gesture) — opened when a FAB is tapped.
//
// FAB windows are their own OS-level windows, so they are not constrained to
// the main HMI window and can be placed on a second monitor, in a corner of the
// desktop, etc.

@MainActor
final class FloatingPanelManager: ObservableObject {

    @Published var chatVisible: Bool = false
    @Published var micVisible:  Bool = false

    // MARK: - Service references

    private var agentService:   AgentService?
    private var sessionManager: SessionManager?
    private var multimodal:     MultimodalInputService?
    private var speechInput:    SpeechInputService?
    private var gestureInput:   GestureInputService?
    private var speechOutput:   SpeechOutputService?

    // MARK: - Windows

    // FAB button windows (borderless, draggable by mouse)
    private var chatFAB: FABPanel?
    private var micFAB:  FABPanel?

    // Content panels (opened on FAB tap)
    private var chatPanel: NSPanel?
    private var micPanel:  NSPanel?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Wiring

    func configure(
        agentService:   AgentService,
        sessionManager: SessionManager,
        multimodal:     MultimodalInputService,
        speechInput:    SpeechInputService,
        gestureInput:   GestureInputService,
        speechOutput:   SpeechOutputService
    ) {
        self.agentService   = agentService
        self.sessionManager = sessionManager
        self.multimodal     = multimodal
        self.speechInput    = speechInput
        self.gestureInput   = gestureInput
        self.speechOutput   = speechOutput

        // Show / hide FABs in sync with the session login state
        sessionManager.$currentOperator
            .receive(on: DispatchQueue.main)
            .sink { [weak self] op in
                if op != nil { self?.showFABs() }
                else         { self?.hideFABs() }
            }
            .store(in: &cancellables)
    }

    // MARK: - FAB window management

    private func showFABs() {
        guard let agentService, let speechInput else { return }

        // Create chat FAB
        if chatFAB == nil {
            let fab = FABPanel(xKey: "fab3.chat.x", yKey: "fab3.chat.y",
                               defaultX: defaultChatFABX, defaultY: defaultFABY)
            fab.tapAction = { [weak self] in self?.toggleChat() }
            fab.contentView = NSHostingView(rootView:
                ChatFABView(panelManager: self, agentService: agentService)
            )
            chatFAB = fab
        }

        // Create mic FAB (stacked above chat FAB by default)
        if micFAB == nil {
            let fab = FABPanel(xKey: "fab3.mic.x", yKey: "fab3.mic.y",
                               defaultX: defaultMicFABX, defaultY: defaultFABY + FABPanel.size + 8)
            fab.tapAction = { [weak self] in self?.toggleMic() }
            fab.contentView = NSHostingView(rootView:
                MicFABView(panelManager: self, speechInput: speechInput)
            )
            micFAB = fab
        }

        chatFAB?.orderFrontRegardless()
        micFAB?.orderFrontRegardless()
    }

    private func hideFABs() {
        chatFAB?.orderOut(nil)
        micFAB?.orderOut(nil)
        // Also hide content panels when logged out
        chatPanel?.orderOut(nil);  chatVisible = false
        micPanel?.orderOut(nil);   micVisible  = false
    }

    // MARK: - Default FAB positions (bottom-right of main screen)

    private var defaultChatFABX: CGFloat {
        (NSScreen.main?.visibleFrame.maxX ?? 1280) - FABPanel.size - 40
    }
    private var defaultMicFABX: CGFloat { defaultChatFABX }
    private var defaultFABY: CGFloat {
        (NSScreen.main?.visibleFrame.minY ?? 0) + 80
    }

    // MARK: - Toggle content panels

    func toggleChat() {
        guard let agentService, let sessionManager else { return }

        if chatPanel == nil {
            chatPanel = makeContentPanel(
                title: "HMI Assistant", width: 420, height: 580,
                xKey: "panel.chat.x", yKey: "panel.chat.y",
                content: AnyView(
                    ChatbotPanel()
                        .environmentObject(agentService)
                        .environmentObject(sessionManager)
                )
            )
            watchClose(chatPanel!) { [weak self] in
                self?.chatVisible = false
            }
        }

        if chatPanel!.isVisible {
            chatPanel!.orderOut(nil); chatVisible = false
        } else {
            chatPanel!.makeKeyAndOrderFront(nil); chatVisible = true
        }
    }

    func toggleMic() {
        guard let multimodal, let speechInput, let gestureInput, let speechOutput else { return }

        if micPanel == nil {
            micPanel = makeContentPanel(
                title: "Voice & Gesture", width: 320, height: 340,
                xKey: "panel.mic.x", yKey: "panel.mic.y",
                content: AnyView(
                    MultimodalControlPanel()
                        .environmentObject(multimodal)
                        .environmentObject(speechInput)
                        .environmentObject(gestureInput)
                        .environmentObject(speechOutput)
                )
            )
            watchClose(micPanel!) { [weak self] in
                self?.micVisible = false
            }
        }

        if micPanel!.isVisible {
            micPanel!.orderOut(nil); micVisible = false
        } else {
            micPanel!.makeKeyAndOrderFront(nil); micVisible = true
        }
    }

    // MARK: - Content panel factory

    private func makeContentPanel(title: String, width: CGFloat, height: CGFloat,
                                  xKey: String, yKey: String,
                                  content: AnyView) -> NSPanel {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let savedX = UserDefaults.standard.double(forKey: xKey)
        let savedY = UserDefaults.standard.double(forKey: yKey)
        let ox = savedX > 0 ? savedX : screen.maxX - width  - 40
        let oy = savedY > 0 ? savedY : screen.maxY - height - 60

        let panel = NSPanel(
            contentRect: CGRect(x: ox, y: oy, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title                       = title
        panel.level                       = .floating
        panel.isFloatingPanel             = true
        panel.becomesKeyOnlyIfNeeded      = true
        panel.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate           = false
        panel.isMovableByWindowBackground = true
        panel.contentView                 = NSHostingView(rootView: content)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let p = panel else { return }
            UserDefaults.standard.set(p.frame.origin.x, forKey: xKey)
            UserDefaults.standard.set(p.frame.origin.y, forKey: yKey)
        }
        return panel
    }

    // MARK: - Close observer helper

    private func watchClose(_ panel: NSPanel, onClose: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            Task { @MainActor in onClose() }
        }
    }
}

// MARK: - FABPanel
//
// A borderless, transparent NSPanel that acts as a draggable FAB button.
// All mouse interaction (tap vs drag) is handled at the AppKit level so the
// window can be moved freely across any screen without any SwiftUI involvement.

private final class FABPanel: NSPanel {

    static let size: CGFloat = 58   // window dimensions (square)

    let xKey: String
    let yKey: String
    var tapAction: () -> Void = {}

    private var mouseDownLoc:    NSPoint = .zero
    private var frameAtMouseDown: NSPoint = .zero
    private var didDrag:          Bool    = false

    init(xKey: String, yKey: String, defaultX: CGFloat, defaultY: CGFloat) {
        self.xKey = xKey
        self.yKey = yKey

        let savedX = UserDefaults.standard.double(forKey: xKey)
        let savedY = UserDefaults.standard.double(forKey: yKey)
        let ox = savedX != 0 ? savedX : defaultX
        let oy = savedY != 0 ? savedY : defaultY

        super.init(
            contentRect: CGRect(x: ox, y: oy, width: Self.size, height: Self.size),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )

        self.level               = .floating
        self.isFloatingPanel     = true
        self.backgroundColor     = .clear
        self.isOpaque            = false
        self.hasShadow           = false   // shadow comes from the SwiftUI Circle
        self.collectionBehavior  = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate   = false
        self.ignoresMouseEvents  = false
    }

    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Mouse handling

    override func mouseDown(with event: NSEvent) {
        mouseDownLoc     = event.locationInWindow
        frameAtMouseDown = frame.origin
        didDrag          = false
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        let dx = event.locationInWindow.x - mouseDownLoc.x
        let dy = event.locationInWindow.y - mouseDownLoc.y
        setFrameOrigin(NSPoint(x: frameAtMouseDown.x + dx,
                               y: frameAtMouseDown.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            // Persist new position
            UserDefaults.standard.set(frame.origin.x, forKey: xKey)
            UserDefaults.standard.set(frame.origin.y, forKey: yKey)
        } else {
            tapAction()
        }
    }
}

// MARK: - FAB SwiftUI content views
// allowsHitTesting(false) so all mouse events fall through to the NSPanel above.

private struct ChatFABView: View {
    @ObservedObject var panelManager: FloatingPanelManager
    @ObservedObject var agentService: AgentService

    private let s: CGFloat = 48

    var body: some View {
        ZStack {
            if panelManager.chatVisible {
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 4)
                    .frame(width: s + 10, height: s + 10)
            }
            Circle()
                .fill(Color.accentColor)
                .frame(width: s, height: s)
                .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            if !agentService.hasAPIKey {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Color.orange)
                    .clipShape(Circle())
                    .offset(x: 13, y: -13)
            }
        }
        .frame(width: FABPanel.size, height: FABPanel.size)
        .allowsHitTesting(false)
    }
}

private struct MicFABView: View {
    @ObservedObject var panelManager: FloatingPanelManager
    @ObservedObject var speechInput:  SpeechInputService

    private let s: CGFloat = 48

    var body: some View {
        ZStack {
            if panelManager.micVisible {
                Circle()
                    .strokeBorder(Color.purple.opacity(0.45), lineWidth: 4)
                    .frame(width: s + 10, height: s + 10)
            }
            Circle()
                .fill(Color.purple)
                .frame(width: s, height: s)
                .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            if speechInput.state == .listening {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Color.red)
                    .clipShape(Circle())
                    .offset(x: 13, y: -13)
            }
        }
        .frame(width: FABPanel.size, height: FABPanel.size)
        .allowsHitTesting(false)
    }
}
