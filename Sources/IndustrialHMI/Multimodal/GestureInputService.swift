import Foundation
@preconcurrency import AVFoundation
import Vision
import Combine

// MARK: - GestureInputService
//
// Manages real-time hand gesture recognition using the device camera and Apple's
// Vision framework (VNDetectHumanHandPoseRequest).
//
// ── Pipeline (background → main thread) ──────────────────────────────────────
//
//   AVCaptureSession (captureQueue)
//     ↓ AVCaptureVideoDataOutput sample buffer
//   VNImageRequestHandler → VNDetectHumanHandPoseRequest
//     ↓ VNHumanHandPoseObservation (landmark positions, 0-1 normalized)
//   classifyGesture(_:)   ← deterministic rules on fingertip/wrist distances
//     ↓ Gesture? (nil if no clear gesture)
//   updateHistory(gesture:wristX:)  ← ring buffer on @MainActor
//     ↓ consensus: same gesture in 6/8 frames  OR  wave wrist-X variance
//   fireCandidateGesture(_:)
//     ↓ gestureDetected.send(gesture)
//   MultimodalInputService.gestureDetected sink
//     ↓ agentService.sendMessage(text: gesture.rawValue)
//
// ── Gesture catalog ───────────────────────────────────────────────────────────
//   Each case's rawValue is the natural-language command sent to AgentService:
//     .thumbsUp  = "Acknowledge all alarms"
//     .openPalm  = "Pause data collection"
//     .pinch     = "Confirm last action"
//     .pointUp   = "Navigate to monitor tab"
//     .pointDown = "Navigate to alarms tab"
//     .wave      = "Cancel and dismiss"
//     .fist      = "Stop data collection"
//
// ── Classification geometry ───────────────────────────────────────────────────
//   Vision normalizes landmark positions to [0,1] (x: left→right, y: bottom→top).
//   We scale to [0,640] × [0,480] before computing Euclidean distances so thresholds
//   are expressed in pixels rather than fractions.
//
//   Key concepts:
//     • fingerCurled: tip-to-wrist distance < MCP-to-wrist distance × 1.3
//       (fingertip is not much farther from the wrist than the knuckle → curled)
//     • openPalm: all 5 tips > 60 px from wrist
//     • fist: all tips < 40 px from wrist (× 1.5 allowance for thumb)
//     • thumbsUp: thumb tip Y > wrist Y + 60, all other fingers curled
//     • pinch: distance(thumbTip, indexTip) < 30 px
//     • pointUp/Down: only index extended, others curled; Y of index tip vs wrist
//     • wave: wrist X variance across last 8 frames > 60 px, fingers mostly open
//
// ── Debounce / consensus ──────────────────────────────────────────────────────
//   A ring buffer of 8 frames prevents single-frame false positives.
//   A gesture is fired only when it appears in ≥ 6 of the last 8 frames.
//   Wave uses wrist-X variance instead (horizontal hand movement detected by spread).
//   `lastFiredGesture` prevents repeated events for the same sustained gesture.
//
// ── Concurrency ───────────────────────────────────────────────────────────────
//   captureOutput() is `nonisolated` — called on `captureQueue` (background).
//   classifyGesture() is also `nonisolated` (pure computation, no shared state).
//   updateHistory() posts back to @MainActor via Task for ring buffer + Combine.

@MainActor
final class GestureInputService: NSObject, ObservableObject {

    // MARK: - Gesture catalog

    /// Each case maps a physical gesture to the natural-language HMI command it triggers.
    /// The rawValue is passed verbatim to AgentService as the operator's intent.
    enum Gesture: String, CaseIterable {
        case thumbsUp  = "Acknowledge all alarms"
        case openPalm  = "Pause data collection"
        case pinch     = "Confirm last action"
        case pointUp   = "Navigate to monitor tab"
        case pointDown = "Navigate to alarms tab"
        case wave      = "Cancel and dismiss"
        case fist      = "Stop data collection"

        /// Short human-readable name shown in the MultimodalInputView chip.
        var displayName: String {
            switch self {
            case .thumbsUp:  return "Thumbs Up"
            case .openPalm:  return "Open Palm"
            case .pinch:     return "Pinch"
            case .pointUp:   return "Point Up"
            case .pointDown: return "Point Down"
            case .wave:      return "Wave"
            case .fist:      return "Fist"
            }
        }
    }

    // MARK: - Published state

    /// The gesture that currently has consensus (6/8 frames). Nil when no gesture is held.
    /// Shown as a chip inside the camera button in MultimodalInputView.
    @Published var currentGesture: Gesture?

    /// True while the capture session is running.
    @Published var isRunning: Bool = false

    /// Whether the operator has granted camera access.
    @Published var cameraPermission: Bool = false

    // MARK: - Combine subject

    /// Fires when a new gesture reaches consensus AND is different from the last fired gesture.
    /// Subscribed by MultimodalInputService to forward to AgentService.
    let gestureDetected = PassthroughSubject<Gesture, Never>()

    // MARK: - Preview layer

    /// Live camera preview layer. Created in setupCaptureSession() on the captureQueue
    /// and set via DispatchQueue.main.async. Exposed to MultimodalInputView so it can
    /// be wrapped in a CameraPreviewView NSViewRepresentable.
    var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Private — AVCapture

    private let captureSession = AVCaptureSession()
    /// Dedicated serial queue for AVCapture callbacks (required by the framework).
    private let captureQueue = DispatchQueue(label: "com.industrialhmi.gesture.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()

    // MARK: - Private — gesture debounce

    /// Ring buffer of the last 8 per-frame gesture classifications.
    /// nil means no gesture was detected in that frame.
    private var gestureHistory: [Gesture?] = Array(repeating: nil, count: 8)
    private var historyIndex: Int = 0

    /// Ring buffer of wrist X positions (scaled 0–640 px) for wave detection.
    private var wristXHistory: [CGFloat] = Array(repeating: 0, count: 8)
    private var wristXIndex: Int = 0

    /// The last gesture that was emitted via gestureDetected.
    /// Prevents repeated emission for the same sustained gesture.
    private var lastFiredGesture: Gesture?

    // MARK: - Permission

    /// Request camera access permission. Called lazily in start() on first use.
    func requestPermission() async {
        let status = await AVCaptureDevice.requestAccess(for: .video)
        cameraPermission = status
    }

    // MARK: - Start / Stop

    /// Start the capture session and Vision hand-pose detection.
    /// Requests camera permission if not yet granted.
    func start() async {
        guard !isRunning else { return }
        if !cameraPermission { await requestPermission() }
        guard cameraPermission else { return }

        do {
            try setupCaptureSession()
        } catch {
            return   // error is logged by the throw site; UI falls back gracefully
        }

        // Capture session must be started on the captureQueue (AVFoundation requirement).
        // Capture reference before leaving @MainActor so the closure doesn't retain self.
        let session = captureSession
        captureQueue.async {
            session.startRunning()
        }
        isRunning = true
    }

    /// Stop the capture session and reset gesture state.
    func stop() {
        guard isRunning else { return }
        let session = captureSession
        captureQueue.async {
            session.stopRunning()
        }
        isRunning = false
        currentGesture = nil
        lastFiredGesture = nil
    }

    // MARK: - Session setup

    /// Configure the AVCaptureSession with the default video device and a
    /// sample buffer output delegate.  Also creates the preview layer.
    ///
    /// Uses VGA (640×480) preset — sufficient for Vision hand pose and lightweight
    /// compared to HD, which would unnecessarily tax the Vision pipeline.

    private func setupCaptureSession() throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .vga640x480   // matches distance scale in classifyGesture

        // Use the default built-in camera (FaceTime HD on most Macs)
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw NSError(domain: "GestureInputService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot access camera"])
        }
        captureSession.addInput(input)

        // Route sample buffers to this class on the captureQueue
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true   // prevent backlog buildup
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Preview layer — created here but surfaced via @Published after commit
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        DispatchQueue.main.async { self.previewLayer = layer }

        captureSession.commitConfiguration()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
//
// Called on `captureQueue` (background serial queue) for every video frame.
// The method is `nonisolated` because AVFoundation calls it off the main actor.
//
// Per-frame pipeline:
//   1. Extract CVPixelBuffer from the CMSampleBuffer
//   2. Run VNDetectHumanHandPoseRequest (maximumHandCount = 1) via VNImageRequestHandler
//   3. Pass the first observation (or nil) to classifyGesture(_:)
//   4. Update the ring buffer via updateHistory (dispatches to @MainActor)

extension GestureInputService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // VNDetectHumanHandPoseRequest uses Core ML under the hood.
        // maximumHandCount = 1 limits to the dominant hand and reduces CPU.
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])

        guard let observation = request.results?.first else {
            // No hand detected this frame — record a nil in history
            updateHistory(gesture: nil, wristX: nil)
            return
        }

        let detected = classifyGesture(observation)
        // Wrist X used for wave detection (need continuous motion tracking)
        let wristX = (try? observation.recognizedPoint(.wrist))?.location.x

        updateHistory(gesture: detected, wristX: wristX.map { CGFloat($0) })
    }

    // MARK: - Gesture classification (nonisolated — pure computation)
    //
    // Converts a VNHumanHandPoseObservation into a Gesture enum case.
    // All thresholds are in scaled pixel units (640×480 image space) for readability.
    //
    // Returns nil if the observation is low-confidence or doesn't match any gesture.

    private nonisolated func classifyGesture(_ obs: VNHumanHandPoseObservation) -> Gesture? {
        // Gather all required landmark positions. A missing landmark means the hand
        // is partially occluded — return nil to avoid misclassification.
        guard
            let thumbTip   = try? obs.recognizedPoint(.thumbTip),
            let indexTip   = try? obs.recognizedPoint(.indexTip),
            let middleTip  = try? obs.recognizedPoint(.middleTip),
            let ringTip    = try? obs.recognizedPoint(.ringTip),
            let littleTip  = try? obs.recognizedPoint(.littleTip),
            let wrist      = try? obs.recognizedPoint(.wrist),
            let indexMCP   = try? obs.recognizedPoint(.indexMCP),   // index knuckle
            let middleMCP  = try? obs.recognizedPoint(.middleMCP),
            let ringMCP    = try? obs.recognizedPoint(.ringMCP),
            let littleMCP  = try? obs.recognizedPoint(.littleMCP),
            let thumbIP    = try? obs.recognizedPoint(.thumbIP)      // thumb interphalangeal joint
        else { return nil }

        // Confidence gate — discard landmarks the model is uncertain about
        let minConf: Float = 0.5
        guard thumbTip.confidence > minConf,
              indexTip.confidence > minConf,
              wrist.confidence > minConf else { return nil }

        // Scale normalized coords to pixel units for threshold comparisons
        let scaleX: CGFloat = 640
        let scaleY: CGFloat = 480

        /// Euclidean distance between two recognized points in pixel space.
        func dist(_ a: VNRecognizedPoint, _ b: VNRecognizedPoint) -> CGFloat {
            let dx = (CGFloat(a.location.x) - CGFloat(b.location.x)) * scaleX
            let dy = (CGFloat(a.location.y) - CGFloat(b.location.y)) * scaleY
            return sqrt(dx*dx + dy*dy)
        }

        // Distance from each fingertip to the wrist (extended → large, curled → small)
        let dIndex  = dist(indexTip,  wrist)
        let dMiddle = dist(middleTip, wrist)
        let dRing   = dist(ringTip,   wrist)
        let dLittle = dist(littleTip, wrist)
        let dThumb  = dist(thumbTip,  wrist)

        // MCP (knuckle) to wrist distances — used as a reference baseline for curl detection
        let dIndexMCP  = dist(indexMCP,  wrist)
        let dMiddleMCP = dist(middleMCP, wrist)
        let dRingMCP   = dist(ringMCP,   wrist)
        let dLittleMCP = dist(littleMCP, wrist)

        // A finger is "curled" when its tip is only marginally farther from the wrist
        // than its MCP joint.  A 1.3× ratio is generous enough to handle partial curls.
        let curlThreshold: CGFloat = 1.3
        let indexCurled  = dIndex  < dIndexMCP  * curlThreshold
        let middleCurled = dMiddle < dMiddleMCP * curlThreshold
        let ringCurled   = dRing   < dRingMCP   * curlThreshold
        let littleCurled = dLittle < dLittleMCP * curlThreshold

        // Vision Y axis: 0 = bottom, 1 = top — so "above" means higher Y value
        let thumbY    = CGFloat(thumbTip.location.y)  * scaleY
        let wristY    = CGFloat(wrist.location.y)     * scaleY
        let indexTipY = CGFloat(indexTip.location.y)  * scaleY
        let thumbIPY  = CGFloat(thumbIP.location.y)   * scaleY

        // ── Pinch: thumb tip & index tip within 30 px ────────────────────
        // Both index and middle must be partially curled (otherwise it's an open palm pointing)
        let pinchDist = dist(thumbTip, indexTip)
        if pinchDist < 30, indexCurled, middleCurled { return .pinch }

        // ── Fist: all fingertips within 40 px of wrist ───────────────────
        // Thumb allowed 1.5× threshold because the thumb rests differently when fisting
        let fistThreshold: CGFloat = 40
        if dIndex < fistThreshold && dMiddle < fistThreshold &&
           dRing  < fistThreshold && dLittle < fistThreshold &&
           dThumb < fistThreshold * 1.5 { return .fist }

        // ── Thumbs Up: thumb tip well above wrist, all other fingers curled ─
        // thumbIPY > wristY ensures the whole thumb is raised, not just the tip
        if thumbY > wristY + 60,
           thumbIPY > wristY,
           indexCurled, middleCurled, ringCurled, littleCurled { return .thumbsUp }

        // ── Open Palm: all 5 tips > 60 px from wrist ─────────────────────
        let openThreshold: CGFloat = 60
        if dThumb  > openThreshold && dIndex  > openThreshold &&
           dMiddle > openThreshold && dRing   > openThreshold &&
           dLittle > openThreshold { return .openPalm }

        // ── Point Up / Down: only index extended, others curled ──────────
        // Distinguish up vs down by whether the index tip is above or below the wrist.
        if !indexCurled && middleCurled && ringCurled && littleCurled {
            if indexTipY > wristY { return .pointUp }
            return .pointDown
        }

        return nil   // no recognizable gesture
    }

    // MARK: - Debounce / history (dispatches to @MainActor)
    //
    // Updates two ring buffers:
    //   gestureHistory — last 8 per-frame gestures (nil = no detection)
    //   wristXHistory  — last 8 wrist X positions (for wave variance)
    //
    // Consensus rules:
    //   • Wave: wrist X variance > 60 px AND ≥ 5/8 frames are openPalm or nil
    //   • Other gestures: ≥ 6/8 frames agree on the same gesture
    //
    // Called nonisolated because it originates from captureOutput (background);
    // all @Published mutations happen inside Task @MainActor.

    private nonisolated func updateHistory(gesture: Gesture?, wristX: CGFloat?) {
        Task { @MainActor in
            // Record this frame's gesture in the ring buffer
            gestureHistory[historyIndex] = gesture
            historyIndex = (historyIndex + 1) % gestureHistory.count

            // Update wrist X ring buffer (scaled to pixel space for threshold comparison)
            if let x = wristX {
                wristXHistory[wristXIndex] = x * 640
                wristXIndex = (wristXIndex + 1) % wristXHistory.count
            }

            // ── Wave detection (horizontal motion + open hand) ────────────
            // Variance = max(wristX) - min(wristX) across 8 frames.
            // A variance > 60 px means the hand moved significantly left-right.
            let wristVar = wristXHistory.max()! - wristXHistory.min()!
            if wristVar > 60, gesture == .openPalm || gesture == nil {
                let waveCount = gestureHistory.filter { $0 == .openPalm || $0 == nil }.count
                if waveCount >= 5 { fireCandidateGesture(.wave); return }
            }

            // ── Standard consensus (6/8 frames) ──────────────────────────
            for candidate in Gesture.allCases where candidate != .wave {
                let count = gestureHistory.filter { $0 == candidate }.count
                if count >= 6 { fireCandidateGesture(candidate); return }
            }

            // No consensus — clear current gesture display
            currentGesture = nil
            lastFiredGesture = nil
        }
    }

    /// Emit a confirmed gesture, updating currentGesture and firing gestureDetected.
    /// Guards against repeated emissions for the same sustained gesture (lastFiredGesture).
    private func fireCandidateGesture(_ gesture: Gesture) {
        currentGesture = gesture
        if gesture != lastFiredGesture {
            lastFiredGesture = gesture
            gestureDetected.send(gesture)
        }
    }
}
