import Foundation

/// What the Mac is spending and what Holdnote's share of it is, at one moment. The app samples
/// it (Mach host and task info); this is the shape and the words.
public struct UsageSample: Equatable, Sendable {
    public enum Thermal: String, Sendable {
        case nominal, fair, serious, critical

        public var title: String {
            switch self {
            case .nominal: "Cool"
            case .fair: "Warm"
            case .serious: "Hot: slowing down"
            case .critical: "Too hot: throttled"
            }
        }
    }

    /// Fraction of all cores busy, 0…1, everything on the Mac included.
    public var systemCPU: Double
    /// Fraction of all cores Holdnote is using, 0…1 (part of `systemCPU`).
    public var appCPU: Double
    public var cores: Int
    /// Bytes in use on the whole Mac (active, wired and compressed), and bytes installed.
    public var memoryUsed: Int64
    public var memoryTotal: Int64
    /// Holdnote's footprint in bytes (the loaded model is most of it).
    public var appMemory: Int64
    public var thermal: Thermal

    public init(systemCPU: Double, appCPU: Double, cores: Int, memoryUsed: Int64, memoryTotal: Int64, appMemory: Int64, thermal: Thermal) {
        self.systemCPU = systemCPU
        self.appCPU = appCPU
        self.cores = cores
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.appMemory = appMemory
        self.thermal = thermal
    }

    /// Fraction of the Mac's memory in use, 0…1.
    public var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    /// Holdnote's fraction of the Mac's memory, 0…1.
    public var appMemoryFraction: Double { memoryTotal > 0 ? Double(appMemory) / Double(memoryTotal) : 0 }
    /// Holdnote's share of what the CPU is doing right now, 0…1 (nil when the CPU is idle).
    public var appShareOfCPU: Double? { systemCPU > 0.005 ? min(1, appCPU / systemCPU) : nil }
}

public enum UsageText {
    public static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    /// "1.9 GB", "640 MB".
    public static func bytes(_ n: Int64) -> String {
        let gb = Double(n) / 1_000_000_000
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int((Double(n) / 1_000_000).rounded())) MB"
    }

    /// The CPU line: the whole Mac, and Holdnote's part of it.
    public static func cpu(_ s: UsageSample) -> String {
        "CPU \(percent(s.systemCPU)) in use · Holdnote \(percent(s.appCPU))"
    }

    /// The memory line.
    public static func memory(_ s: UsageSample) -> String {
        "Memory \(bytes(s.memoryUsed)) of \(bytes(s.memoryTotal)) · Holdnote \(bytes(s.appMemory))"
    }

    /// One line for the menu.
    public static func line(_ s: UsageSample) -> String {
        var parts = [cpu(s), memory(s)]
        if s.thermal != .nominal { parts.append(s.thermal.title) }
        return parts.joined(separator: " · ")
    }

    /// What the numbers mean for the app, in a sentence (the bar's tooltip).
    public static func explanation(_ s: UsageSample, transcribing: Bool) -> String {
        var text = "Of the \(s.cores) cores, \(percent(s.systemCPU)) are busy across every app; Holdnote accounts for \(percent(s.appCPU))"
        if let share = s.appShareOfCPU { text += " (\(percent(share)) of what's busy)" }
        text += ". Holdnote holds \(bytes(s.appMemory)) of the \(bytes(s.memoryTotal)) installed"
        text += transcribing ? "; the transcriber is running, which is where the CPU goes." : "; most of that is the speech model, kept loaded so the next transcript starts at once."
        if s.thermal != .nominal { text += " The Mac is \(s.thermal.title.lowercased())." }
        return text
    }
}
