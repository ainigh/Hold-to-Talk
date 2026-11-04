import AppKit
import Harness
import SwiftUI

/// The recording pill: a floating panel at the top of the screen with the cursor, above every
/// app and full-screen window, that never takes focus or the mouse. The one piece of chrome
/// the app has.
@MainActor
@Observable
final class HUDController {
    enum Phase: Equatable {
        case hidden
        case recording
        case transcribing
        case done
        case failure(String)
    }

    private(set) var phase: Phase = .hidden
    private(set) var locked = false
    private(set) var appending = false
    private(set) var seconds: TimeInterval = 0
    /// The last 24 levels, oldest first, smoothed.
    private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    private(set) var note: String?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var smoothed: Float = 0

    static let size = NSSize(width: 240, height: 44)

    func show(locked: Bool, appending: Bool) {
        hideTask?.cancel()
        self.locked = locked
        self.appending = appending
        seconds = 0
        levels = Array(repeating: 0, count: 24)
        smoothed = 0
        note = nil
        phase = .recording
        present()
    }

    func update(level: Float, seconds: TimeInterval, silentFor: TimeInterval) {
        // A 90 ms low-pass at 20 Hz ticks: liquid, not jittery.
        smoothed += (level - smoothed) * 0.45
        levels.removeFirst()
        levels.append(smoothed)
        self.seconds = seconds
        note = silentFor > 2 && seconds > 2 ? "No sound from the mic" : nil
    }

    /// The key was released: transcribing, then a checkmark, then gone.
    func finish() {
        phase = .transcribing
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.phase = .done
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func showFailure(_ message: String) {
        hideTask?.cancel()
        phase = .failure(message)
        present()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        phase = .hidden
        hideTask = Task { [weak self] in
            // After the exit animation.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        // On the display with the cursor, 24 pt below the menu bar.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let width: CGFloat = 360, height: CGFloat = 72
        let x = screen.frame.midX - width / 2
        let y = screen.visibleFrame.maxY - 24 - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 72)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RecordingPill(hud: self))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

/// The pill's look: a HUD material, a hairline border, a breathing red dot, 24 bars, a timer.
struct RecordingPill: View {
    let hud: HUDController
    @State private var breathe = false

    var body: some View {
        let visible = hud.phase != .hidden
        let done = hud.phase == .done
        ZStack {
            content
                .frame(width: done ? 44 : HUDController.size.width, height: 44)
                .background(HUDMaterial(material: .hudWindow, blending: .behindWindow).clipShape(Capsule()))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .scaleEffect(visible ? 1 : 0.92)
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: done)
        .onAppear { breathe = true }
    }

    @ViewBuilder
    private var content: some View {
        switch hud.phase {
        case .recording:
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(breathe ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: breathe)
                Waveform(levels: hud.levels)
                    .frame(height: 20)
                if hud.appending {
                    Image(systemName: "text.append").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                if hud.locked {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(hud.note ?? TranscriptText.duration(hud.seconds))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(hud.note == nil ? Color.primary : Color.orange)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.system(size: 13, weight: .medium))
            }
        case .done:
            Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold))
        case let .failure(message):
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text(message).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 14)
        case .hidden:
            Color.clear
        }
    }
}

/// 24 bars, 2 pt wide with a 1 pt gap, from the levels.
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 2, height: max(2, CGFloat(min(1, level)) * 20))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

/// An NSVisualEffectView for SwiftUI.
struct HUDMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
