import Harness
import SwiftUI

/// The strip at the bottom of the window: what the Mac is spending and Holdnote's share of it.
/// Each meter shows everything in use in grey, with Holdnote's part in the accent colour at
/// its start, so you see at a glance what the app is adding to the whole.
struct UsageBar: View {
    let monitor: SystemMonitor
    let transcribing: Bool
    var listening = false

    var body: some View {
        HStack(spacing: 18) {
            if let s = monitor.sample {
                Meter(title: "CPU", total: s.systemCPU, app: s.appCPU,
                      label: "\(UsageText.percent(s.systemCPU)) in use", appLabel: "Holdnote \(UsageText.percent(s.appCPU))")
                Meter(title: "Memory", total: s.memoryFraction, app: s.appMemoryFraction,
                      label: "\(UsageText.bytes(s.memoryUsed)) of \(UsageText.bytes(s.memoryTotal))", appLabel: "Holdnote \(UsageText.bytes(s.appMemory))")
                if s.thermal != .nominal {
                    Label(s.thermal.title, systemImage: "thermometer.medium")
                        .foregroundStyle(s.thermal == .fair ? Color.secondary : Color.orange)
                }
                Spacer()
                if listening {
                    Label("Listening", systemImage: "ear").foregroundStyle(.secondary)
                }
                if transcribing {
                    Label("Transcribing", systemImage: "waveform").foregroundStyle(.secondary)
                }
            } else {
                Text("Measuring…").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .help(monitor.sample.map { UsageText.explanation($0, transcribing: transcribing) } ?? "")
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

struct Meter: View {
    let title: String
    /// Fraction in use by everything, 0…1.
    let total: Double
    /// Fraction in use by Holdnote, 0…1 (part of `total`).
    let app: Double
    let label: String
    let appLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.medium)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.secondary.opacity(0.5)).frame(width: geo.size.width * CGFloat(max(0, min(1, total))))
                    Capsule().fill(Color.accentColor).frame(width: max(app > 0 ? 2 : 0, geo.size.width * CGFloat(max(0, min(1, app)))))
                }
            }
            .frame(width: 90, height: 6)
            .animation(.easeOut(duration: 0.6), value: total)
            .animation(.easeOut(duration: 0.6), value: app)
            Text(label).foregroundStyle(.secondary)
            Text(appLabel).foregroundStyle(Color.accentColor)
        }
        .fixedSize()
    }
}
