import SwiftUI

// MARK: - FloatingDraggableButton
//
// A small circular FAB that:
//   • tap  → calls tapAction (opens/closes the corresponding NSPanel floating window)
//   • drag → moves freely within the app window; snaps to the nearest edge on release
//   • position within the overlay persisted via UserDefaults

struct FloatingDraggableButton: View {

    let xKey:      String     // UserDefaults key for X within the app-window overlay
    let yKey:      String     // UserDefaults key for Y within the app-window overlay
    let icon:      String     // SF Symbol name
    let badge:     String?    // optional small overlay badge symbol
    var isActive:  Bool = false   // true = tint ring drawn to show the panel is open
    let tint:      Color
    let tapAction: () -> Void     // called on tap — toggles the NSPanel window

    // MARK: - State

    @State private var position:   CGPoint = .zero
    @State private var startPos:   CGPoint = .zero
    @State private var isDragging: Bool    = false
    @State private var viewSize:   CGSize  = .zero

    private let size: CGFloat = 48
    private let snapThreshold: CGFloat = 80

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)

                buttonContent
                    .position(safePos(in: geo.size))
            }
            .onAppear {
                viewSize = geo.size
                position = loadedPosition(defaultIn: geo.size)
            }
            .onChange(of: geo.size) { _, newSize in
                viewSize = newSize
                let clamped = clamp(position, in: newSize)
                if clamped != position {
                    position = clamped
                    save()
                }
            }
        }
    }

    // MARK: - Button view

    private var buttonContent: some View {
        ZStack {
            // Active ring — shows when the corresponding NSPanel is visible
            if isActive {
                Circle()
                    .strokeBorder(tint.opacity(0.4), lineWidth: 4)
                    .frame(width: size + 10, height: size + 10)
                    .animation(.easeInOut(duration: 0.2), value: isActive)
            }

            Circle()
                .fill(tint)
                .frame(width: size, height: size)
                .shadow(
                    color: .black.opacity(isDragging ? 0.4 : 0.25),
                    radius: isDragging ? 10 : 5,
                    y: isDragging ? 5 : 2
                )
                .scaleEffect(isDragging ? 1.12 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isDragging)

            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)

            if let badge {
                Image(systemName: badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
                    .offset(x: 14, y: -14)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let dist = hypot(value.translation.width, value.translation.height)
                    if dist > 6 && !isDragging {
                        isDragging = true
                        startPos   = position
                    }
                    if isDragging {
                        position = clamp(
                            CGPoint(x: startPos.x + value.translation.width,
                                    y: startPos.y + value.translation.height),
                            in: viewSize
                        )
                    }
                }
                .onEnded { value in
                    let dist = hypot(value.translation.width, value.translation.height)
                    if isDragging {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                            position = snapped(position, in: viewSize)
                        }
                        save()
                    } else if dist < 6 {
                        tapAction()
                    }
                    isDragging = false
                }
        )
    }

    // MARK: - Helpers

    private func safePos(in size: CGSize) -> CGPoint { clamp(position, in: size) }

    private func clamp(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        let half = size / 2
        return CGPoint(
            x: min(max(half, pt.x), size.width  - half),
            y: min(max(half, pt.y), size.height - half)
        )
    }

    private func snapped(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        let half    = size / 2
        let dLeft   = pt.x
        let dRight  = size.width  - pt.x
        let dTop    = pt.y
        let dBottom = size.height - pt.y
        let nearest = min(dLeft, dRight, dTop, dBottom)
        guard nearest < snapThreshold else { return pt }
        var out = pt
        if nearest == dLeft   { out.x = half }
        if nearest == dRight  { out.x = size.width  - half }
        if nearest == dTop    { out.y = half }
        if nearest == dBottom { out.y = size.height - half }
        return clamp(out, in: size)
    }

    private func loadedPosition(defaultIn size: CGSize) -> CGPoint {
        let x = UserDefaults.standard.double(forKey: xKey)
        let y = UserDefaults.standard.double(forKey: yKey)
        guard x > 0, y > 0 else {
            return CGPoint(x: size.width - size / 2 - 20, y: size.height - size / 2 - 20)
        }
        return clamp(CGPoint(x: x, y: y), in: size)
    }

    private func save() {
        UserDefaults.standard.set(position.x, forKey: xKey)
        UserDefaults.standard.set(position.y, forKey: yKey)
    }
}

// MARK: - CGSize / 2 helper

private func / (lhs: CGSize, rhs: CGFloat) -> CGFloat { min(lhs.width, lhs.height) / rhs }
